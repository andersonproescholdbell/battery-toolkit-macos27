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

Everything below is a local build. There are no releases: a free Apple
Development certificate cannot distribute software, and the signature expires
after about a week.

**Requirements:** macOS 27, Xcode, and an Apple Development certificate. If you
have no certificate, make one in Xcode: *Settings → Accounts → (your Apple ID) →
Manage Certificates → + → Apple Development*.

### 1. Clone

```sh
git clone https://github.com/andersonproescholdbell/battery-toolkit-macos27.git
cd battery-toolkit-macos27
```

### 2. Point it at your certificate

```sh
Tools/setup-signing.sh
```

This reads your signing certificate and rewrites the project to match: the
common name, the team identifier, and the bundle identifiers. It prints what it
changed. Use `--dry-run` first if you want to see the plan, `--bundle-prefix
com.example` to choose your own identifiers, and `--identity <n>` if you hold
more than one certificate.

**Do not commit what it writes** — it is your local signing configuration. To
keep it out of `git status`:

```sh
git update-index --skip-worktree "Battery Toolkit.xcodeproj/project.pbxproj"
```

Re-run the script whenever your certificate is renewed; it is idempotent.

### 3. Build

```sh
xcodebuild -project "Battery Toolkit.xcodeproj" -scheme "Battery Toolkit" \
  -configuration Release -derivedDataPath build build
```

### 4. Check the daemon before installing

```sh
codesign -d --entitlements - \
  "build/Build/Products/Release/Battery Toolkit.app/Contents/Library/LaunchServices/"*batterytoolkitd
```

The output must **not** contain `get-task-allow`. If it does, registration will
fail later with `"Operation not permitted"` and no useful error in the app.

### 5. Install

```sh
cp -R "build/Build/Products/Release/Battery Toolkit.app" /Applications/
open "/Applications/Battery Toolkit.app"
```

Approve the daemon when macOS asks, or enable it under *System Settings →
General → Login Items & Extensions*.

### 6. Confirm it works

A **menu bar icon** is the success signal — there is no main window, and the
settings live behind that icon. To check the daemon itself:

```sh
log show --predicate 'process CONTAINS "batterytoolkitd"' --last 5m \
  --info --debug --style compact | grep -E "preflight|armed"
```

Expect `MCL preflight passed` and `System charge limit armed at <your maximum>`.
Then confirm the limit reached the system:

```sh
sudo defaults read com.apple.smartcharging.topoffprotection mclLimitValue
```

### Troubleshooting

Every row here is a failure hit and diagnosed while building this fork.

| Symptom | Cause |
| --- | --- |
| No menu bar icon, nothing in the log | daemon is not running — `pgrep -lf batterytoolkitd` |
| `"Operation not permitted"` when registering | the daemon carries `get-task-allow`; see step 4 |
| App sits at "connecting" | team identifier mismatch between the project file and the plists or entitlements — re-run `Tools/setup-signing.sh` |
| Daemon respawns every ~10 s | it is crash-looping; read `/Library/Logs/DiagnosticReports/*batterytoolkitd-*.ips` |
| Login Items toggle is on, but "Not running in background" | stale Background Task Management record — `sudo sfltool dumpbtm \| grep -A6 batterytoolkitd` and look for `disallowed`. Renaming the bundle prefix is the targeted fix; `sfltool resetbtm` clears every app's approvals |
| Worked, then stopped after about a week | the development certificate expired — re-run step 2 and rebuild |

### Why the setup script exists

Battery Toolkit ships a privileged daemon, and the app and daemon each verify
the other's code signature. That requirement is built from the certificate's
common name, and the Mach service name from the team identifier. Both appear in
the project file *and* literally in `BatteryToolkit/BatteryToolkit.entitlements`,
`BatteryToolkit/Info.plist`, `uninstall.sh` and both daemon plists — 34 project
settings and five files in total. The daemon's directory name is also
load-bearing: its `Info.plist` and embedded `launchd.plist` resolve through
`PRODUCT_NAME`, so the directory has to match the target.

The team identifier is the certificate's **OU**, not the identifier inside its
common name. Getting that wrong produces an app that builds and installs and
then never connects.

Bundle identifiers must be changed rather than reused: Background Task
Management keys its records on the bundle identifier, so inheriting another
build's identifiers inherits its record — including a `disallowed` one, which
silently prevents the daemon from ever starting.

`xcodebuild build` also injects `com.apple.security.get-task-allow` in every
configuration, Release included; only archive/export strips it. `SMAppService`
refuses to register a privileged daemon carrying it. Hence
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` in the project, at the cost of not
being able to attach a debugger.

## Tools

Upstream has no `Tools/` directory; these were written while working out what
had changed.

| Tool | Purpose |
| --- | --- |
| `setup-signing.sh` | points a clone at your certificate and bundle identifiers (see [Building](#building)) |
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
| `bc759e6` | MCL backend, preflight, drain guard; adapter key made optional |
| `d59c9c9` | sign under a private team |
| `2195e06` | stop injecting debug entitlements into the daemon |
| `ec03fca` | own bundle identifiers |
| `db0dd82` | balance the sleep counter (it underflowed and crash-looped the daemon) |
| `0dff203` | time out waiting for the daemon to identify itself |
| `58a4bc0` | keep the charge limit armed instead of toggling it |

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
