// Self-check for the drain guard in SMCComm.Power.setChargingLimit.
//
// The manualChargeLimit policy carries drain: true, so a ceiling below the
// current charge makes the Mac discharge from wall power to reach it. The
// guard must never emit a ceiling below the current charge.
//
// Mirrors the production expression: max(limit, currentPercent).

func effectiveCeiling(limit: UInt8, currentPercent: UInt8) -> Int {
    return Int(max(limit, currentPercent))
}

var failures = 0
func expect(_ actual: Int, _ expected: Int, _ what: String) {
    let ok = actual == expected
    if !ok { failures += 1 }
    print("  [\(ok ? "PASS" : "FAIL")] \(what): got \(actual), want \(expected)")
}

print("drain guard self-check")

// The case that motivated the guard: battery full, user asks for 70.
// A naive implementation writes 70 and the Mac drains from the wall.
expect(effectiveCeiling(limit: 70, currentPercent: 100), 100,
       "full battery, limit 70 -> hold at 100")

// Ceiling follows the charge down as the battery is used.
expect(effectiveCeiling(limit: 70, currentPercent: 85), 85, "85% -> hold at 85")
expect(effectiveCeiling(limit: 70, currentPercent: 71), 71, "71% -> hold at 71")

// Once at or below the target, the real limit applies.
expect(effectiveCeiling(limit: 70, currentPercent: 70), 70, "at target -> 70")
expect(effectiveCeiling(limit: 70, currentPercent: 65), 70, "below target -> 70")
expect(effectiveCeiling(limit: 70, currentPercent: 0), 70, "empty -> 70")

// Charge-to-full raises the ceiling unconditionally.
expect(effectiveCeiling(limit: 100, currentPercent: 80), 100, "charge to full")

// Invariant: the ceiling is never below the current charge.
for current in UInt8(0) ... 100 {
    for limit in stride(from: UInt8(20), through: UInt8(100), by: 5) {
        let ceiling = effectiveCeiling(limit: limit, currentPercent: current)
        if ceiling < Int(current) {
            print("  [FAIL] ceiling \(ceiling) < charge \(current) (limit \(limit))")
            failures += 1
        }
    }
}
print("  [\(failures == 0 ? "PASS" : "FAIL")] invariant: ceiling >= current charge, all combinations")

print(failures == 0 ? "\nOK" : "\n\(failures) FAILURE(S)")
