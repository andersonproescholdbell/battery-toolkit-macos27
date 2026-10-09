//
// Copyright (C) 2026 Battery Toolkit macOS 27 fork contributors.
// SPDX-License-Identifier: BSD-3-Clause
//
// macOS 27 (Golden Gate) removed the SMC charge-inhibit keys: CHTE, CH0B,
// CH0C and CH0I/CH0J are gone, and the bfD0/bfE0/bfF0 firmware keys that some
// machines expose are absent here (present in the key index but hollow - both
// GetKeyInfo and ReadKey answer kIOReturnNotFound, as root too).
//
// What remains is the lever the system itself uses: the manualChargeLimit
// policy in powerd. PowerUIAgent (root) drives it from mclLimitValue in its
// own preference domain. The 80-100 range check lives only in the XPC handler
// setMCLLimit:, while the com.apple.smartcharging.defaultschanged notification
// makes the agent reload its preferences and forward the value unvalidated -
// which is how limits below 80% are reached.
//
// Technique discovered by BatLimit (https://github.com/DmitriyODS/BatLimit).
//

import Foundation
import os.log

//
// The subset of PowerUISmartChargeClient that we call. The class is loaded at
// runtime, so the object is cast to this protocol rather than a header type.
//
@objc private protocol PowerUIClient {
    @objc(initWithClientName:) func initWithClientName(_ name: String) -> AnyObject
    @objc(isMCLSupported) func isMCLSupported() -> Bool
    @objc(isMCLCurrentlyEnabled:) func isMCLCurrentlyEnabled(_ error: NSErrorPointer) -> UInt64
    @objc(enableMCL:) func enableMCL(_ error: NSErrorPointer) -> Bool
    @objc(getMCLLimitWithError:) func getMCLLimit(_ error: NSErrorPointer) -> UInt8
}

public enum SystemChargeLimitError: Error, CustomStringConvertible {
    case preflightFailed(String)
    case writeFailed
    case notApplied(requested: Int, actual: Int)

    public var description: String {
        switch self {
        case let .preflightFailed(check):
            return "MCL preflight failed: \(check)"
        case .writeFailed:
            return "failed to write PowerUIAgent preferences (root required)"
        case let .notApplied(requested, actual):
            return "limit \(requested)% was not applied (agent reports \(actual)%)"
        }
    }
}

@MainActor
public enum SystemChargeLimit {
    public static let domain = "com.apple.smartcharging.topoffprotection"
    public static let changedNotification = "com.apple.smartcharging.defaultschanged"

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"
    private static let limitKey = "mclLimitValue"
    private static let featureStateKey = "MCLFeatureState"
    //
    // Set by "Charge to Full Now" in the battery menu. While it is present the
    // agent does not apply the limit at all.
    //
    private static let tempDisabledKey = "MCLTempDisabledUntilDate"

    //
    // The system itself only ever sets 80...100. Anything lower would leave the
    // user with a value they cannot see or change in System Settings, so the
    // saved original is clamped before being restored.
    //
    private static let systemMinimum = 80
    //
    // Below this the machine is not meaningfully charging at all.
    //
    private static let absoluteMinimum = 20

    private static var client: PowerUIClient?

    private(set) static var supported = false

    //
    // The limit that was configured before we took control, restored when the
    // daemon stops or standard charging is requested.
    //
    private(set) static var originalLimit: Int?

    static func prepare() {
        //
        // Re-ask PowerUI on every call: right after boot it can answer
        // "unsupported" before the agent is up, and that must not stick.
        //
        if self.client == nil {
            self.client = self.makeClient()
        }

        guard let client = self.client else {
            self.supported = false
            return
        }

        self.supported = client.isMCLSupported()

        guard self.supported else {
            os_log("MCL reported unsupported by PowerUI")
            return
        }

        if self.originalLimit == nil {
            self.originalLimit = self.agentLimit()
        }
    }

    private static func makeClient() -> PowerUIClient? {
        guard dlopen(self.frameworkPath, RTLD_NOW) != nil else {
            os_log("Failed to load PowerUI framework")
            return nil
        }
        guard let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type,
              let allocated = cls.perform(NSSelectorFromString("alloc"))?
                  .takeUnretainedValue()
        else {
            os_log("PowerUISmartChargeClient unavailable")
            return nil
        }

        let object = unsafeBitCast(allocated, to: PowerUIClient.self)
            .initWithClientName("io.github.andersonproescholdbell.batterytoolkitd")
        return unsafeBitCast(object, to: PowerUIClient.self)
    }

    //
    // The limit the agent is actually applying. The value in the preference
    // file does not mean the agent has reloaded it yet, so ask over XPC.
    //
    static func agentLimit() -> Int? {
        guard let client = self.client else {
            return nil
        }

        var error: NSError?
        let value = client.getMCLLimit(&error)
        return error == nil ? Int(value) : nil
    }

    static var isEnabled: Bool {
        guard let client = self.client else {
            return false
        }

        var error: NSError?
        return client.isMCLCurrentlyEnabled(&error) != 0 && error == nil
    }

    //
    // Applies a ceiling. Requires root: the preference domain belongs to root.
    //
    // The caller is responsible for never requesting a ceiling below the
    // current charge - the policy carries drain: true, so a lower ceiling makes
    // the Mac discharge from wall power to reach it. See BTPowerState.
    //
    static func setLimit(_ percent: Int) throws {
        if let failure = MCLPreflight.run().firstFatalFailure {
            throw SystemChargeLimitError.preflightFailed(failure)
        }

        let value = min(max(percent, self.absoluteMinimum), 100)
        let domain = self.domain as CFString

        if self.originalLimit == nil {
            self.originalLimit = self.agentLimit()
        }

        //
        // A value on its own does nothing while the feature is switched off.
        // Prefer the supported path, and fall back to the flag in the same
        // preferences if the agent refuses.
        //
        if !self.isEnabled {
            var error: NSError?
            _ = self.client?.enableMCL(&error)
            if !self.isEnabled {
                CFPreferencesSetAppValue(
                    self.featureStateKey as CFString,
                    1 as CFNumber,
                    domain
                )
            }
        }

        CFPreferencesSetAppValue(self.tempDisabledKey as CFString, nil, domain)
        CFPreferencesSetAppValue(
            self.limitKey as CFString,
            value as CFNumber,
            domain
        )
        guard CFPreferencesAppSynchronize(domain) else {
            throw SystemChargeLimitError.writeFailed
        }

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(self.changedNotification as CFString),
            nil,
            nil,
            true
        )

        try self.verifyApplied(value)
    }

    //
    // The agent reloads asynchronously, so poll briefly rather than trusting
    // the write. A silently ignored limit would mean charging to 100 while the
    // app claims otherwise, which is the failure worth being loud about.
    //
    private static func verifyApplied(_ expected: Int) throws {
        var observed = -1
        for _ in 0 ..< 20 {
            if let limit = self.agentLimit() {
                observed = limit
                if limit == expected {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        os_log("MCL limit \(expected) not applied, agent reports \(observed)")
        throw SystemChargeLimitError.notApplied(
            requested: expected,
            actual: observed
        )
    }

    //
    // Hands control back to the system, restoring whatever limit was set
    // before. Clamped so the value stays reachable from System Settings.
    //
    static func restoreOriginalLimit() {
        guard let original = self.originalLimit else {
            return
        }

        let value = min(max(original, self.systemMinimum), 100)
        do {
            try self.setLimit(value)
            self.originalLimit = nil
        } catch {
            os_log("Failed to restore original charge limit: \(error.localizedDescription)")
        }
    }
}
