// Read-only preflight: validate every API and value the MCL backend depends on.
// Performs NO writes. Exit 0 = safe to proceed, 1 = do not write limits.
import Foundation
import IOKit

var failures: [String] = []
var warnings: [String] = []

func check(_ name: String, _ ok: Bool, _ detail: String, fatal: Bool = true) {
    print("  [\(ok ? "PASS" : (fatal ? "FAIL" : "WARN"))] \(name): \(detail)")
    if !ok { fatal ? failures.append(name) : warnings.append(name) }
}

print("=== 1. PowerUI private framework ===")
let fw = "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"
let handle = dlopen(fw, RTLD_NOW)
check("dlopen PowerUI", handle != nil, handle != nil ? "loaded from dyld cache" : String(cString: dlerror()))

@objc protocol PowerUIClient {
    @objc(initWithClientName:) func initWithClientName(_ n: String) -> AnyObject
    @objc(isMCLSupported) func isMCLSupported() -> Bool
    @objc(isMCLCurrentlyEnabled:) func isMCLCurrentlyEnabled(_ e: NSErrorPointer) -> UInt64
    @objc(getMCLLimitWithError:) func getMCLLimit(_ e: NSErrorPointer) -> UInt8
}

let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type
check("PowerUISmartChargeClient class", cls != nil, cls != nil ? "found" : "MISSING")

// Every selector we intend to call must exist before we rely on it.
let selectors = ["initWithClientName:", "isMCLSupported", "isMCLCurrentlyEnabled:",
                 "enableMCL:", "getMCLLimitWithError:"]
if let cls {
    for sel in selectors {
        let ok = cls.instancesRespond(to: NSSelectorFromString(sel))
        check("selector \(sel)", ok, ok ? "present" : "MISSING")
    }
}

print("\n=== 2. MCL state (read-only) ===")
var client: PowerUIClient?
if let cls, let alloc = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() {
    let obj = unsafeBitCast(alloc, to: PowerUIClient.self).initWithClientName("preflight")
    client = unsafeBitCast(obj, to: PowerUIClient.self)
}
if let c = client {
    let sup = c.isMCLSupported()
    check("isMCLSupported", sup, "\(sup)")
    var e1: NSError?
    let en = c.isMCLCurrentlyEnabled(&e1)
    check("isMCLCurrentlyEnabled", e1 == nil, "value=\(en) error=\(e1?.localizedDescription ?? "none")", fatal: false)
    var e2: NSError?
    let lim = c.getMCLLimit(&e2)
    let sane = e2 == nil && lim >= 1 && lim <= 100
    check("getMCLLimit returns sane value", sane, "\(lim)% error=\(e2?.localizedDescription ?? "none")")
} else {
    check("instantiate client", false, "could not alloc/init")
}

print("\n=== 3. Preference domain (read-only) ===")
let domain = "com.apple.smartcharging.topoffprotection" as CFString
let mcl = CFPreferencesCopyAppValue("mclLimitValue" as CFString, domain)
// Readable only as root; absence here is informational, not fatal.
check("mclLimitValue readable", mcl != nil,
      mcl != nil ? "\(mcl!)" : "not readable as uid \(getuid()) (expected unless root)", fatal: false)
let temp = CFPreferencesCopyAppValue("MCLTempDisabledUntilDate" as CFString, domain)
check("MCLTempDisabledUntilDate", true, temp == nil ? "not set (good)" : "SET - system would ignore our limit", fatal: false)

print("\n=== 4. PowerUIAgent ===")
// Read the process table directly via sysctl - no subprocess, no run loop.
func findProcess(_ name: String) -> (pid: Int32, uid: uid_t)? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return nil }
    let count = size / MemoryLayout<kinfo_proc>.stride
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return nil }
    let actual = size / MemoryLayout<kinfo_proc>.stride
    for i in 0..<actual {
        var p = procs[i]
        let comm = withUnsafePointer(to: &p.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        if comm.contains(name) { return (p.kp_proc.p_pid, p.kp_eproc.e_ucred.cr_uid) }
    }
    return nil
}
if let agent = findProcess("PowerUIAgent") {
    check("PowerUIAgent running as root", agent.uid == 0, "pid \(agent.pid), uid \(agent.uid)")
} else {
    check("PowerUIAgent running as root", false, "NOT RUNNING")
}

print("\n=== 5. Battery telemetry ===")
let bat = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
if bat != IO_OBJECT_NULL {
    var props: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(bat, &props, kCFAllocatorDefault, 0)
    let d = props?.takeRetainedValue() as? [String: Any] ?? [:]
    let cur = d["CurrentCapacity"] as? Int
    check("CurrentCapacity readable", cur != nil, cur.map { "\($0)%" } ?? "missing")
    let ext = d["ExternalConnected"] as? Bool
    check("ExternalConnected readable", ext != nil, ext.map { $0 ? "on AC" : "on battery" } ?? "missing", fatal: false)
    if let cd = d["ChargerData"] as? [String: Any], let ncr = cd["NotChargingReason"] as? Int {
        let bit24 = (ncr & (1 << 24)) != 0   // manual charge limit hold
        let bit12 = (ncr & (1 << 12)) != 0   // active drain toward ceiling
        check("NotChargingReason readable", true, "\(ncr) (0x\(String(ncr, radix: 16)))")
        check("  bit24 manual-charge-limit hold", true, "\(bit24)", fatal: false)
        check("  bit12 draining to ceiling", !bit12, bit12 ? "SET - battery is draining from wall" : "clear (good)", fatal: false)
    }
    IOObjectRelease(bat)
} else {
    check("AppleSmartBattery", false, "service not found")
}

print("\n=== 6. powerd policy file ===")
let pf = "/Library/Preferences/com.apple.powerd.charging.plist"
check("policy file exists", FileManager.default.fileExists(atPath: pf), pf, fatal: false)

print("\n=== 7. SMC legacy keys (expected absent on this Mac) ===")
// Informational: if these ever come back, the legacy backend is preferable.
print("  (run Tools/smcprobe for detail)")

print("\n" + String(repeating: "=", count: 52))
if failures.isEmpty {
    print("PREFLIGHT PASSED\(warnings.isEmpty ? "" : " with \(warnings.count) warning(s): \(warnings.joined(separator: ", "))")")
    print("Safe to apply charge limits.")
    exit(0)
} else {
    print("PREFLIGHT FAILED: \(failures.joined(separator: ", "))")
    print("DO NOT write charge limits - the MCL backend is not safe on this system.")
    exit(1)
}
