// Read-only: does PowerUI expose manual charge limit (MCL) on this Mac?
import Foundation
@objc protocol PowerUIClient {
    @objc(initWithClientName:) func initWithClientName(_ name: String) -> AnyObject
    @objc(isMCLSupported) func isMCLSupported() -> Bool
    @objc(isMCLCurrentlyEnabled:) func isMCLCurrentlyEnabled(_ error: NSErrorPointer) -> UInt64
    @objc(getMCLLimitWithError:) func getMCLLimit(_ error: NSErrorPointer) -> UInt8
}
func main() {
    let path = "/System/Library/PrivateFrameworks/PowerUI.framework/Versions/A/PowerUI"
    guard dlopen(path, RTLD_NOW) != nil else {
        print("dlopen failed: \(String(cString: dlerror()))"); exit(1)
    }
    print("dlopen OK (resolved from dyld shared cache)")
    guard let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type else {
        print("PowerUISmartChargeClient NOT found"); exit(1)
    }
    print("PowerUISmartChargeClient found")
    guard let allocated = cls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else {
        print("alloc failed"); exit(1)
    }
    let object = unsafeBitCast(allocated, to: PowerUIClient.self).initWithClientName("probe")
    let client = unsafeBitCast(object, to: PowerUIClient.self)
    print("isMCLSupported:        \(client.isMCLSupported())")
    var e1: NSError?
    let enabled = client.isMCLCurrentlyEnabled(&e1)
    print("isMCLCurrentlyEnabled: \(enabled)   error=\(e1?.localizedDescription ?? "none")")
    var e2: NSError?
    let limit = client.getMCLLimit(&e2)
    print("getMCLLimit:           \(limit)   error=\(e2?.localizedDescription ?? "none")")
}
main()
