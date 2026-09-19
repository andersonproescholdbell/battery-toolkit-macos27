// Read-only: enumerates the SMC key index by ordinal and prints charge-related keys.
// Uses kSMCGetKeyFromIndex + kSMCGetKeyInfo only. Never writes.
import Foundation
import IOKit

let kSMCHandleYPCEvent: UInt32 = 2
let kSMCUserClientOpen: UInt32 = 0
let kSMCUserClientClose: UInt32 = 1
let kSMCGetKeyFromIndex: UInt8 = 8
let kSMCGetKeyInfo: UInt8 = 9
let kSMCReadKey: UInt8 = 5
let kSMCSuccess: UInt8 = 0

struct SMCVers { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0 }
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

func fourCCString(_ v: UInt32) -> String {
    let b = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    return String(bytes: b.map { $0 >= 32 && $0 < 127 ? $0 : 0x2E }, encoding: .ascii) ?? "????"
}

var connect: io_connect_t = 0
let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
guard svc != IO_OBJECT_NULL else { print("AppleSMC not found"); exit(1) }
guard IOServiceOpen(svc, mach_task_self_, 1, &connect) == kIOReturnSuccess else { print("open failed"); exit(1) }
_ = IOConnectCallMethod(connect, kSMCUserClientOpen, nil, 0, nil, 0, nil, nil, nil, nil)

func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
    var output = SMCParamStruct()
    var size = MemoryLayout<SMCParamStruct>.stride
    let rc = IOConnectCallStructMethod(connect, kSMCHandleYPCEvent, &input,
                                       MemoryLayout<SMCParamStruct>.stride, &output, &size)
    guard rc == kIOReturnSuccess, output.result == kSMCSuccess else { return nil }
    return output
}

// "#KEY" holds the number of keys in the index.
var p = SMCParamStruct()
p.key = 0x234B4559  // '#KEY'
p.keyInfo.dataSize = 4
p.data8 = kSMCReadKey
guard let out = call(&p) else { print("cannot read #KEY"); exit(1) }
let b = Mirror(reflecting: out.bytes).children.prefix(4).map { $0.value as! UInt8 }
let count = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
print("SMC reports \(count) keys total\n")

var all: [String] = []
for i in 0..<count {
    var q = SMCParamStruct()
    q.data8 = kSMCGetKeyFromIndex
    q.data32 = i
    guard let r = call(&q) else { continue }
    all.append(fourCCString(r.key))
}
print("enumerated \(all.count) key names\n")

// Anything plausibly related to charge control.
let interesting = all.filter { k in
    k.hasPrefix("CH") || k.hasPrefix("bf") || k.hasPrefix("BF") ||
    k.hasPrefix("B0") || k == "ACLC" || k == "BUIC" || k == "AC-W" ||
    k.hasPrefix("BC") || k.hasPrefix("BS")
}.sorted()

print("charge/battery-related keys present:")
for k in interesting {
    var s = SMCParamStruct()
    s.key = k.unicodeScalars.reduce(UInt32(0)) { ($0 << 8) | (UInt32($1.value) & 0xFF) }
    s.data8 = kSMCGetKeyInfo
    if let info = call(&s)?.keyInfo {
        print(String(format: "  %-5s size=%d type=%@ attr=0x%02X", (k as NSString).utf8String!,
                     Int(info.dataSize), fourCCString(info.dataType), info.dataAttributes))
    } else {
        print("  \(k)  <info failed>")
    }
}

for target in ["bfD0", "bfE0", "bfF0", "CHTE", "CH0B", "CH0C"] {
    print("\(target): \(all.contains(target) ? "IN INDEX" : "not in index")")
}

_ = IOConnectCallMethod(connect, kSMCUserClientClose, nil, 0, nil, 0, nil, nil, nil, nil)
IOServiceClose(connect)
