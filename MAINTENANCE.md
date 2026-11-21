# Maintenance log

Findings from checking this fork after macOS updates. Newest first. Facts are
marked as verified or not; hypotheses are labelled as such.

## 2026-11-21 - charged to 100% overnight on macOS 27.2.1 (26B131)

Report: plugged in at 34% on 2026-11-20 20:21, reached 99% by 21:51 with the
limit at 60%.

### Verified

- The daemon applied the limit. PowerUIAgent logged `Limiting charging to 60%
  SoC` and `MCL target: 60%` on plug-in.
- macOS suspended it for battery gauge calibration. At 19:32 powerd logged
  `periodicChargeToFullCheck run gauging mitigation policy` ("Last Qmax change
  was 12.3 days ago"), then PowerUIAgent `Gauging mitigation state changed,
  new state: 1`. While on AC: PowerUIAgent `ChargingUpForGauging (mode: 7)`
  and `Battery mitigations are in place, MCL will be ignored`, powerd `SOC
  limit policy suspend due to mitigation active:1`. No supported lever
  overrides this, and blocking it would let the battery percentage drift, so
  the app now reports it instead.
- Unplugging at 99% left the mitigation active overnight. It cleared without a
  full charge at the next plug-in (2026-11-21 13:21:56, at 89%): PowerUIAgent
  `Current mitigation state changed to: 0`. What clears it is not known.
- `PowerUISmartChargeClient smartChargingUIState:chargeLimit:chargingOverrideAllowed:withError:`
  (encoding `B48@0:8^Q16^Q24^B32^@40`) returned state 18 while the agent
  logged `ChargingUpForGauging`. `SystemChargeLimit.gaugingUIState` holds
  that value. It is a single observation, so recheck it after OS updates.
  Also observed: 16 `DischargingToMCL`, 14 `PausedForMCL`.
- The drain happened as predicted. After the 13:21 plug-in at 89% with the
  limit still 60, PowerUIAgent reported `DischargingToMCL`: on AC, not
  charging, discharging toward 60.
- The menu showed "Charging On Hold" throughout: it reflected a cached flag,
  not the system.
- The daemon logged nothing about any of this.
- The development certificate expired on 2026-11-09 (`security find-identity
  -v -p codesigning` lists 0 identities). The installed build keeps running,
  but a rebuild needs the certificate renewed in Xcode first.
- Xcode 27.1 rejects deployment target 11.0, and its Swift no longer finds a
  module whose directory name differs from the module name
  (`NSXPCConnection+AuditToken` vs `NSXPCConnectionAuditToken`).

### Changes made

- The daemon logs when calibration starts and ends overriding the limit
  (`macOS battery calibration is overriding the charge limit`), and the menu
  shows "Charging to 100 % (macOS Battery Calibration)" instead of "Charging
  On Hold" while it does. Preflight reports the selector as a non-fatal check.
- On MCL, `BTPowerState.disableCharging(percent:)` no longer returns early on
  the cached flag. It reconciles the ceiling to max(maximum, charge) whenever
  the agent's limit differs, and the hysteresis calls it below the maximum
  too. Before: the limit stayed at 60 with the battery at 92%, so after
  calibration powerd would drain from wall power to 60. A ceiling raised while
  above the maximum also survived a plug-in at a lower charge.
- Deployment target 12.0, module directory renamed, `kIOMainPortDefault`.

- Installed after renewing the certificate (same team, same CN, so the
  daemon requirement still matches). On start, the new daemon moved the
  limit from 60 to 88 at 88% on AC. PowerUI went from `DischargingToMCL` to
  `PausedForMCL`, and preflight shows bit24 hold set and bit12 drain clear.
  The daemon now logs the applied value: `armed at 88 (maximum 60)`.

### Not verified

- The menu's calibration line on a real calibration. None was active after
  the install.

## 2026-10-09 - health check on macOS 27.0.1 (26A434)

Context: macOS moved from 27.0 (26A428) to 27.0.1 (26A434) after the original
build. The app was also reported not to always start at login.

### Verified

- Preflight passes on 27.0.1: all five private selectors present,
  `isMCLSupported` true, `getMCLLimit` readable, PowerUIAgent running as uid 0.
- `Tools/drainguard_test.swift` and `Tools/sleepbalance_test.swift` pass.
- The daemon logs `MCL preflight passed` and `System charge limit armed at 60`.
- The development certificate was valid until 2026-11-09.
- With the battery at 79 % and the ceiling at 60 %, the limit reads back 79:
  the drain guard holds at the current charge and follows it down. This is
  intended, not a fault.
- The autostart login item worked at the 2026-10-04 boot (app launched 38 s
  after the daemon).

### Not verified

- `mclLimitValue` itself (needs sudo); only PowerUI's readback was checked.
- The charge hold while plugged in above the ceiling (bit 24 of
  `NotChargingReason`). The Mac was on battery during the check.
- That the startup race below is the cause of the reported login problem.
  It was never observed failing.
- The retry paths in the daemon and the app. They compile and are installed,
  but PowerUIAgent could not be delayed without root or a reboot.

### Startup race (hypothesis, hardened)

The daemon decided "supported" once at launch and cached it. A fatal preflight
check can fail early in boot (PowerUIAgent not up, battery telemetry not yet
readable). The app then reached `promptMachineUnsupported`, which force-removes
the daemon, disables the login item and wipes the app defaults, so later logins
would start nothing.

Changes made:

- `SystemChargeLimit.prepare()` re-asks PowerUI on every call instead of
  caching the first answer.
- The daemon keeps serving XPC after an unsupported start and retries every
  5 s, 12 times, then activates normally if a retry succeeds.
- The app retries `isSupported` for about 70 s before showing the unsupported
  prompt.
- The Autostart switch reads `SMAppService.mainApp.status` instead of the
  stored preference, so it cannot show "on" while the login item is off. It
  does not re-register the login item on its own.

If login start still fails, run this right after login, before touching
anything:

```sh
pgrep -fl "Battery Toolkit"; pgrep -fl batterytoolkitd
```

No app process means the login item did not fire. App without a menu bar icon
means the daemon check failed; read `/usr/bin/log show` for the app and daemon.

### Installing a rebuild - do not skip setup-signing

A build made without `Tools/setup-signing.sh` ships a daemon that requires the
placeholder certificate name `YOUR NAME (XXXXXXXXXX)` and rejects your real
app (`The code signature requirement failed`, status -67050). The daemon runs,
the app cannot reach it, and the limit falls back to the system value.

Correct sequence, keeping the existing identifiers and approval records:

```sh
Tools/setup-signing.sh --bundle-prefix io.github.andersonproescholdbell
xcodebuild -project "Battery Toolkit.xcodeproj" -scheme "Battery Toolkit" \
  -configuration Release -derivedDataPath build build
```

Without `--bundle-prefix` the script renames every identifier to
`local.batterytoolkit.*`, which orphans the installed daemon. Use `--dry-run`
first. Then check the daemon has no `get-task-allow`, quit the app, replace
`/Applications/Battery Toolkit.app` and reopen it. The daemon is upgraded on
first launch, and the old one restores the system limit while it exits.

Keep the signing config out of commits:

```sh
git update-index --skip-worktree "Battery Toolkit.xcodeproj/project.pbxproj"
```

### Tooling gotchas

- In zsh, `log` is a builtin. Use `/usr/bin/log show ...`.
- `sfltool dumpbtm` can hang when redirected to a file or run repeatedly; pipe
  it through `grep` with a line cap, or avoid it.
- A bare Swift tool cannot read the app's `SMAppService` status; it reports
  `notFound` because it is outside the bundle.
