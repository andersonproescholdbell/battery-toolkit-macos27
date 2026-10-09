# Maintenance log

Findings from checking this fork after macOS updates. Newest first. Facts are
marked as verified or not; hypotheses are labelled as such.

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
