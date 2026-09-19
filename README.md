# Battery Toolkit (macOS 27 fork)

A fork of [mhaeuser/Battery-Toolkit](https://github.com/mhaeuser/Battery-Toolkit)
that restores battery charge limiting on macOS 27 (Golden Gate), including
limits **below 80 %**.

> **Personal project, not maintained.**
> Built for one machine: MacBook Pro `Mac15,7` (M3 Pro), macOS 27.0 (26A428).
> Upstream was archived before macOS 27 shipped, so this is published only in
> case it helps someone with the same problem. No releases, no support, no
> guarantee it works on your Mac. You build and sign it yourself.
> For the original app and its documentation, see
> [upstream](https://github.com/mhaeuser/Battery-Toolkit).

## What broke

macOS 27 removed the SMC keys Battery Toolkit used to inhibit charging. On this
machine:

| Key | State |
| --- | --- |
| `CHTE`, `CH0B`, `CH0C`, `CH0I`, `CH0J` | absent from the SMC key index entirely |
| `bfD0`, `bfE0`, `bfF0` | in the index (slots 1624-1626) but **hollow** |
| `CHIE`, `ACLC` | present and readable |

`bfD0`/`bfE0`/`bfF0` are the firmware charge-band interface that *some* macOS 27
Macs expose. Here they have a name in the index but no backing entry:
`GetKeyInfo` and `ReadKey` both answer `kIOReturnNotFound` (`0xE00002C1`), with
size 0 and no type, as root as well. So `SMCComm.Power.supported()` found no
usable key and reported the machine unsupported, while the app and daemon kept
running and nothing limited charging.

Porting to `bfD0`/`bfE0`/`bfF0` — the obvious fix, and what other projects did —
does nothing on hardware where those keys are hollow.

## What this fork does instead

It drives the limit macOS itself uses: the `manualChargeLimit` policy in
`powerd`, the one behind System Settings → Battery → Charge Limit.

`PowerUIAgent` (running as root) takes the value from `mclLimitValue` in the
`com.apple.smartcharging.topoffprotection` preference domain. The 80-100 range
check lives **only** in the XPC handler `setMCLLimit:`. On the
`com.apple.smartcharging.defaultschanged` Darwin notification the agent reloads
its preferences and forwards the value to powerd unvalidated — which is how a
limit below 80 % is reached.

Technique discovered by [BatLimit](https://github.com/DmitriyODS/BatLimit).

## How it behaves

The ceiling is armed at `maxCharge` when the daemon starts and stays armed;
powerd enforces it.

- The limit **holds through sleep** and while the daemon is stopped.
- The Mac **no longer stays awake** while charging.
- At the ceiling the battery **rests** at roughly zero current (bit 24 of
  `NotChargingReason`). It is not a charge/discharge sawtooth — the Mac runs
  from the adapter.
- **`minCharge` has no effect** on this backend. The firmware decides when to
  top up beneath the ceiling; the setting only drives the legacy SMC path.
- **Force discharge is gone.** It needed `CH0I`/`CH0J`, which no longer exist.
  Inhibiting the adapter instead would run the Mac off its battery and cause
  micro-cycling — an approach upstream `battery`
  [rejected](https://github.com/actuallymentor/battery/pull/478) on exactly
  those grounds.

## Safety

**The drain guard.** The policy carries `drain: true`: a ceiling set *below* the
current charge makes the Mac actively discharge from wall power to reach it
(bit 12 of `NotChargingReason`). This fork never places the ceiling below the
current charge — it holds at the current level and follows the charge down.
`Tools/drainguard_test.swift` checks the invariant across every charge/limit
combination.

**The preflight.** `Libraries/MCLPreflight.swift` is read-only and runs at
daemon start *and* immediately before every write. It checks that each private
selector still exists (via `instancesRespond(to:)`), that MCL is supported and
returns a sane limit, that `MCLTempDisabledUntilDate` is unset, that
`PowerUIAgent` runs as uid 0, and that battery telemetry is readable. If a macOS
update changes the interface, the daemon reports the machine unsupported instead
of writing into it.

Writes are also **read back and verified** against the agent. A limit that is
silently ignored is reported as an error, not as success — the failure mode that
matters is believing a limit is held while the battery charges to 100 %.

## Risks

This uses a **private, undocumented Apple API** and writes a **root-owned Apple
preference domain**. Any macOS update can break it, and the sub-80 % path
depends on an unvalidated code path Apple could close at any time.

Nothing here is destructive, and the escape hatch needs none of this code:

```sh
sudo defaults write com.apple.smartcharging.topoffprotection mclLimitValue -int 80
sudo killall -HUP PowerUIAgent   # or just reboot
```

System Settings → Battery remains authoritative: moving its slider overrides
whatever the daemon set. Uninstalling restores the limit that was set
beforehand.

## Building

Requires Xcode and an Apple Development certificate. To build under your own
identity, change these (each appears twice, once per configuration):

| Setting | Note |
| --- | --- |
| `DEVELOPMENT_TEAM` | your certificate's **OU**, *not* the ID in its common name |
| `BT_CODESIGN_CN` | the exact common name, including the parenthesised ID |
| `BT_DAEMON_CONN` | `<team id>.<daemon bundle id>` |
| `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` | already `NO` — leave it |

Two things that are easy to miss:

- The team ID also appears **literally**, not through a build setting, in
  `BatteryToolkit/BatteryToolkit.entitlements` and both daemon plists. Miss one
  and the app hangs at "connecting" while the daemon refuses it.
- `xcodebuild build` injects `com.apple.security.get-task-allow` in *every*
  configuration, Release included; only archive/export strips it. `SMAppService`
  refuses to register a privileged daemon carrying it, failing with
  `"Operation not permitted"`. Hence `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`,
  at the cost of not being able to attach a debugger.

Bundle identifiers were renamed to `io.github.andersonproescholdbell.*` because
Background Task Management keys its records on the bundle identifier, and a
stale record from the upstream build — marked `disallowed` and signed by a
different team — blocked registration. `sfltool` has no per-item delete, and
`sfltool resetbtm` would clear every application's approvals, so renaming was
the targeted fix.

```sh
xcodebuild -project "Battery Toolkit.xcodeproj" -scheme "Battery Toolkit" \
  -configuration Release -derivedDataPath build build
```

A free Apple Development certificate expires after a week. When it does, the
daemon stops validating and the app needs rebuilding.

## Tools

Upstream has no `Tools/` directory; these were written while working out what
had changed.

| Tool | Purpose |
| --- | --- |
| `smcprobe.swift` | read-only dump of every charge-related SMC key, with type, size, attributes and value |
| `smcenum.swift` | enumerates the whole SMC key index — this is what proved the `bf*` keys are hollow rather than absent |
| `mcltest.swift` | reports `isMCLSupported`, `isMCLCurrentlyEnabled` and the current limit |
| `preflight.swift` | the standalone form of the daemon's preflight checks |
| `drainguard_test.swift` | self-check for the drain guard invariant |
| `sleepbalance_test.swift` | self-check that sleep disable/restore calls balance on both backends |

None of them write anything except `preflight`, which is also read-only.

## Changes from upstream

| Commit | Change |
| --- | --- |
| `cece958` | MCL backend, preflight, drain guard; adapter key made optional |
| `00ac383` | sign under a private team |
| `90be8b3` | stop injecting debug entitlements into the daemon |
| `e580fbd` | own bundle identifiers |
| `d9767b6` | balance the sleep counter (it underflowed and crash-looped the daemon) |
| `74d46af` | time out waiting for the daemon to identify itself |
| `4b99ba1` | keep the charge limit armed instead of toggling it |

## Credits

- [Marvin Häuser](https://github.com/mhaeuser) — Battery Toolkit itself. This
  fork changes one backend; everything else is his work.
- [BatLimit](https://github.com/DmitriyODS/BatLimit) — the PowerUI/MCL technique
  for limits below 80 %.
- [charlie0129/batt](https://github.com/charlie0129/batt) and
  [actuallymentor/battery](https://github.com/actuallymentor/battery) —
  reference implementations of the `bfD0`/`bfE0`/`bfF0` firmware interface.

## Licence

BSD-3-Clause, unchanged from upstream. See `LICENSE.txt`.
