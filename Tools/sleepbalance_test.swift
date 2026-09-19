// Self-check for GlobalSleep's counter: the daemon's disable/restore calls must
// balance on both backends, and restore() must never underflow.
//
// Mirrors GlobalSleep.disabledCounter (UInt8) and the guard added after an
// unbalanced restore() trapped the daemon with "arithmetic overflow".

enum Backend { case legacy, mcl }

final class Sleep {
    private(set) var counter: UInt8 = 0
    private(set) var refused = 0

    func disable() { counter += 1 }

    func restore() {
        guard counter > 0 else { refused += 1; return }
        counter -= 1
    }
}

// The daemon's startup path. initState() disables sleep on the legacy backend
// when charging is enabled, so that disable() is the one disableCharging()
// later restores. handleLimitedPower adds its own balanced pair around the
// work, and disableCharging() only restores when it actually transitions
// (it returns early via `guard !self.chargingDisabled`).
func runStartup(backend: Backend, chargingAlreadyDisabled: Bool) -> Sleep {
    let s = Sleep()

    if case .legacy = backend, !chargingAlreadyDisabled {
        s.disable()                               // initState
    }

    s.disable()                                   // handleLimitedPower enter
    if case .legacy = backend, !chargingAlreadyDisabled {
        s.restore()                               // disableCharging transition
    }
    s.restore()                                   // handleLimitedPower exit
    return s
}

func runChargeCycle(backend: Backend) -> Sleep {
    let s = Sleep()
    if case .legacy = backend { s.disable() }     // enableCharging
    if case .legacy = backend { s.restore() }     // disableCharging
    return s
}

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String) {
    if !ok { failures += 1 }
    print("  [\(ok ? "PASS" : "FAIL")] \(name): \(detail)")
}

print("GlobalSleep balance self-check")

for backend in [Backend.legacy, .mcl] {
    let label = backend == .legacy ? "legacy" : "mcl"

    for alreadyDisabled in [false, true] {
        let startup = runStartup(backend: backend, chargingAlreadyDisabled: alreadyDisabled)
        let suffix = alreadyDisabled ? "charging already held" : "charging active"
        check("\(label) startup (\(suffix)) ends at 0",
              startup.counter == 0, "counter=\(startup.counter)")
        check("\(label) startup (\(suffix)) never underflows",
              startup.refused == 0, "refused=\(startup.refused)")
    }

    let cycle = runChargeCycle(backend: backend)
    check("\(label) charge cycle balances", cycle.counter == 0, "counter=\(cycle.counter)")
    check("\(label) charge cycle no underflow", cycle.refused == 0, "refused=\(cycle.refused)")
}

// The regression itself: an ungated restore on the MCL backend.
let broken = Sleep()
broken.disable()
broken.restore()
broken.restore()   // the bug - would have trapped without the guard
check("guard absorbs unbalanced restore", broken.counter == 0 && broken.refused == 1,
      "counter=\(broken.counter) refused=\(broken.refused)")

print(failures == 0 ? "\nOK" : "\n\(failures) FAILURE(S)")
