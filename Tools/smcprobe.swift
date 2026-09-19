// Read-only SMC key probe. Performs kSMCGetKeyInfo + kSMCReadKey only.
// It never issues kSMCWriteKey, so it cannot change how this Mac charges.
import Foundation
import IOKit

let kSMCHandleYPCEvent: UInt32 = 2
let kSMCUserClientOpen: UInt32 = 0
let kSMCUserClientClose: UInt32 = 1
let kSMCGetKeyInfo: UInt8 = 9
let kSMCReadKey: UInt8 = 5
let kSMCSuccess: UInt8 = 0

struct SMCVers { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }

// 80-byte SMCParamStruct, matching AppleSMC's user client ABI.
struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8) =
        (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

func fourCC(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for ch in s.unicodeScalars { v = (v << 8) | (UInt32(ch.value) & 0xFF) }
    return v
}
func fourCCString(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: b.map { $0 >= 32 && $0 < 127 ? $0 : 0x2E }, encoding: .ascii) ?? "????"
}

var connect: io_connect_t = 0
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard svc != IO_OBJECT_NULL else { print("AppleSMC service not found"); exit(1) }
guard IOServiceOpen(svc, mach_task_self_, 1, &connect) == kIOReturnSuccess else {
    print("IOServiceOpen failed"); exit(1)
}
_ = IOConnectCallMethod(connect, kSMCUserClientOpen, nil, 0, nil, 0, nil, nil, nil, nil)

assert(MemoryLayout<SMCParamStruct>.stride == 80, "SMCParamStruct must be 80 bytes")

func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
    var output = SMCParamStruct()
    var size = MemoryLayout<SMCParamStruct>.stride
    let rc = IOConnectCallStructMethod(connect, kSMCHandleYPCEvent,
                                       &input, MemoryLayout<SMCParamStruct>.stride,
                                       &output, &size)
    guard rc == kIOReturnSuccess, output.result == kSMCSuccess else { return nil }
    return output
}

func keyInfo(_ key: String) -> SMCKeyInfoData? {
    var p = SMCParamStruct(); p.key = fourCC(key); p.data8 = kSMCGetKeyInfo
    return call(&p)?.keyInfo
}

func readKey(_ key: String, size: Int) -> [UInt8]? {
    var p = SMCParamStruct(); p.key = fourCC(key)
    p.keyInfo.dataSize = UInt32(size); p.data8 = kSMCReadKey
    guard let out = call(&p) else { return nil }
    return Mirror(reflecting: out.bytes).children.prefix(size).map { $0.value as! UInt8 }
}

print("SMC charge-control probe (read-only)\n")

let keys = [
    ("bfD0", "firmware upper limit %"),
    ("bfE0", "firmware lower limit %"),
    ("bfF0", "firmware limit active (0x00 off / 0x02 on)"),
    ("CHTE", "macOS 26 charge inhibit"),
    ("CH0B", "legacy charge inhibit"),
    ("CH0C", "legacy charge inhibit"),
    ("CHIE", "adapter inhibit (Tahoe)"),
    ("CH0I", "adapter inhibit"),
    ("CH0J", "adapter inhibit"),
    ("ACLC", "MagSafe LED"),
    ("BUIC", "battery charge %"),
]

var present = Set<String>()
for (key, desc) in keys {
    guard let info = keyInfo(key) else {
        print(String(format: "  %-5s  absent", (key as NSString).utf8String!))
        continue
    }
    present.insert(key)
    let size = Int(info.dataSize)
    let type = fourCCString(info.dataType)
    let valueBytes = readKey(key, size: size)
    let value = valueBytes.map { $0.map { b in String(format: "%02X", b) }.joined(separator: " ") } ?? "<read failed>"
    var extra = ""
    if let v = valueBytes, v.count == 4 {
        let le = UInt32(v[0]) | UInt32(v[1]) << 8 | UInt32(v[2]) << 16 | UInt32(v[3]) << 24
        let be = UInt32(v[3]) | UInt32(v[2]) << 8 | UInt32(v[1]) << 16 | UInt32(v[0]) << 24
        extra = "  (LE=\(le) BE=\(be))"
    } else if let v = valueBytes, v.count == 1 {
        extra = "  (\(v[0]))"
    }
    print(String(format: "  %-5s  size=%d type=%@ attr=0x%02X  value=[%@]%@  — %@",
                 (key as NSString).utf8String!, size, type, info.dataAttributes, value, extra, desc))
}

print("")
let firmware = present.contains("bfD0") && present.contains("bfE0") && present.contains("bfF0")
let legacy = present.contains("CHTE") || (present.contains("CH0B") && present.contains("CH0C")) || present.contains("CH0C")
if firmware {
    print("VERDICT: FIRMWARE (bfD0/bfE0/bfF0) — the macOS 27 firmware band interface is available.")
    if legacy { print("         Legacy keys are ALSO present; firmware interface takes precedence.") }
} else if legacy {
    print("VERDICT: LEGACY — CHTE/CH0B/CH0C present. Stock Battery Toolkit should already work.")
} else {
    print("VERDICT: NONE FOUND — no charge-inhibit key of any kind.")
}

_ = IOConnectCallMethod(connect, kSMCUserClientClose, nil, 0, nil, 0, nil, nil, nil, nil)
IOServiceClose(connect)
