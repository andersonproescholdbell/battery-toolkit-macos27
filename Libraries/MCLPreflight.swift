//
// Copyright (C) 2026 Battery Toolkit macOS 27 fork contributors.
// SPDX-License-Identifier: BSD-3-Clause
//
// Read-only validation of everything the MCL backend depends on. Nothing
// writes a charge limit until this passes.
//
// The private PowerUI interface is undocumented and can change in any macOS
// update. Checking each selector before it is called means a renamed or
// removed API is reported as unsupported rather than silently leaving the
// battery charging to 100 while the app claims a limit is held.
//

import Foundation
import IOKit
import os.log

public struct MCLPreflightResult: Sendable {
    public struct Check: Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String
        public let fatal: Bool
    }

    public let checks: [Check]

    public var passed: Bool {
        return self.firstFatalFailure == nil
    }

    public var firstFatalFailure: String? {
        let failure = self.checks.first { !$0.passed && $0.fatal }
        guard let failure = failure else {
            return nil
        }

        return "\(failure.name): \(failure.detail)"
    }

    public var warnings: [Check] {
        return self.checks.filter { !$0.passed && !$0.fatal }
    }
}

public enum MCLPreflight {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"
    private static let domain = "com.apple.smartcharging.topoffprotection"
    private static let policyPath =
        "/Library/Preferences/com.apple.powerd.charging.plist"

    //
    // Every selector the backend calls. A missing one means the interface
    // changed underneath us.
    //
    private static let requiredSelectors = [
        "initWithClientName:",
        "isMCLSupported",
        "isMCLCurrentlyEnabled:",
        "enableMCL:",
        "getMCLLimitWithError:",
    ]

    public static func run() -> MCLPreflightResult {
        var checks: [MCLPreflightResult.Check] = []

        func check(
            _ name: String,
            _ passed: Bool,
            _ detail: String,
            fatal: Bool = true
        ) {
            checks.append(
                MCLPreflightResult.Check(
                    name: name,
                    passed: passed,
                    detail: detail,
                    fatal: fatal
                )
            )
        }

        //
        // 1. The private framework has to load, and the class has to exist.
        //
        let loaded = dlopen(self.frameworkPath, RTLD_NOW) != nil
        check("dlopen PowerUI", loaded, loaded ? "loaded" : "not loadable")

        let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type
        check("PowerUISmartChargeClient", cls != nil, cls != nil ? "found" : "missing")

        //
        // 2. Each selector we intend to call.
        //
        if let cls = cls {
            for selector in self.requiredSelectors {
                let responds = cls.instancesRespond(to: NSSelectorFromString(selector))
                check("selector \(selector)", responds, responds ? "present" : "missing")
            }
        }

        //
        // 3. MCL has to be supported and report a sane current limit.
        //
        let limit = SystemChargeLimitProbe.currentLimit()
        check(
            "isMCLSupported",
            SystemChargeLimitProbe.supported(),
            "\(SystemChargeLimitProbe.supported())"
        )
        let sane = limit.map { $0 >= 1 && $0 <= 100 } ?? false
        check("getMCLLimit", sane, limit.map { "\($0)%" } ?? "unreadable")

        //
        // 4. "Charge to Full Now" suppresses the limit entirely while set.
        //
        let tempDisabled = CFPreferencesCopyAppValue(
            "MCLTempDisabledUntilDate" as CFString,
            self.domain as CFString
        )
        check(
            "MCLTempDisabledUntilDate",
            tempDisabled == nil,
            tempDisabled == nil ? "not set" : "set - system ignores the limit",
            fatal: false
        )

        //
        // 5. PowerUIAgent has to be running as root to apply anything.
        //
        let agent = self.findProcess("PowerUIAgent")
        check(
            "PowerUIAgent",
            agent?.uid == 0,
            agent.map { "pid \($0.pid), uid \($0.uid)" } ?? "not running"
        )

        //
        // 6. Battery telemetry, including the bits the drain guard relies on.
        //
        let battery = self.batteryProperties()
        let capacity = battery?["CurrentCapacity"] as? Int
        check("CurrentCapacity", capacity != nil, capacity.map { "\($0)%" } ?? "unreadable")

        if let charger = battery?["ChargerData"] as? [String: Any],
           let reason = charger["NotChargingReason"] as? Int {
            let draining = (reason & (1 << 12)) != 0
            check(
                "NotChargingReason",
                true,
                "0x\(String(reason, radix: 16)) hold=\((reason & (1 << 24)) != 0)"
            )
            check(
                "not draining from wall",
                !draining,
                draining ? "bit 12 set" : "clear",
                fatal: false
            )
        } else {
            check("NotChargingReason", false, "unreadable", fatal: false)
        }

        //
        // 7. The policy file powerd keeps the limit in.
        //
        let policyExists = FileManager.default.fileExists(atPath: self.policyPath)
        check("powerd policy file", policyExists, policyExists ? "present" : "missing", fatal: false)

        return MCLPreflightResult(checks: checks)
    }

    public static func logResult(_ result: MCLPreflightResult) {
        if let failure = result.firstFatalFailure {
            os_log("MCL preflight FAILED - \(failure)")
        } else {
            os_log("MCL preflight passed (\(result.warnings.count) warnings)")
        }
    }

    //
    // Read the process table directly. Spawning ps here would need a run loop
    // to reap, which deadlocks inside the daemon's main actor.
    //
    private static func findProcess(_ name: String) -> (pid: Int32, uid: uid_t)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else {
            return nil
        }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else {
            return nil
        }

        for index in 0 ..< (size / MemoryLayout<kinfo_proc>.stride) {
            var proc = procs[index]
            let comm = withUnsafePointer(to: &proc.kp_proc.p_comm) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXCOMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if comm.contains(name) {
                return (proc.kp_proc.p_pid, proc.kp_eproc.e_ucred.cr_uid)
            }
        }

        return nil
    }

    private static func batteryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(
            kIOMasterPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else {
            return nil
        }
        defer {
            IOObjectRelease(service)
        }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service,
            &properties,
            kCFAllocatorDefault,
            0
        ) == kIOReturnSuccess else {
            return nil
        }

        return properties?.takeRetainedValue() as? [String: Any]
    }
}

//
// Minimal, non-actor-isolated view of the PowerUI client, so the preflight can
// run before (and independently of) the main-actor backend.
//
@objc private protocol PowerUIProbeClient {
    @objc(initWithClientName:) func initWithClientName(_ name: String) -> AnyObject
    @objc(isMCLSupported) func isMCLSupported() -> Bool
    @objc(getMCLLimitWithError:) func getMCLLimit(_ error: NSErrorPointer) -> UInt8
}

private enum SystemChargeLimitProbe {
    private static func client() -> PowerUIProbeClient? {
        guard dlopen(
            "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI",
            RTLD_NOW
        ) != nil,
            let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
            let allocated = cls.perform(NSSelectorFromString("alloc"))?
                .takeUnretainedValue()
        else {
            return nil
        }

        let object = unsafeBitCast(allocated, to: PowerUIProbeClient.self)
            .initWithClientName("preflight")
        return unsafeBitCast(object, to: PowerUIProbeClient.self)
    }

    static func supported() -> Bool {
        return self.client()?.isMCLSupported() ?? false
    }

    static func currentLimit() -> Int? {
        guard let client = self.client() else {
            return nil
        }

        var error: NSError?
        let value = client.getMCLLimit(&error)
        return error == nil ? Int(value) : nil
    }
}
