#!/bin/sh
#
# Points the project at your own signing certificate and bundle identifiers.
#
# Battery Toolkit ships a privileged daemon, so the app and the daemon each
# verify the other's code signature. That requirement is built from the
# certificate's common name, and the Mach service name is built from the team
# identifier - both of which appear in the project file and, literally, in the
# entitlements and the daemon plists. Miss one and the app sits at "connecting"
# forever while the daemon refuses it.
#
# Renaming the bundle identifiers is required rather than cosmetic: Background
# Task Management keys its records on the bundle identifier, so reusing someone
# else's identifiers inherits their record, including a "disallowed" one.
#
# Everything this writes is local configuration. Do not commit it.
#
# Copyright (C) 2026 Battery Toolkit macOS 27 fork contributors.
# SPDX-License-Identifier: BSD-3-Clause
#

set -eu

BUNDLE_PREFIX="local.batterytoolkit"
IDENTITY_INDEX=""
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: Tools/setup-signing.sh [options]

  --bundle-prefix <prefix>  Reverse-DNS prefix for the bundle identifiers.
                            Default: local.batterytoolkit
  --identity <n>            Use the nth codesigning identity, as numbered by
                            `security find-identity -v -p codesigning`.
  --dry-run                 Report what would change and write nothing.
  -h, --help                This message.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bundle-prefix) BUNDLE_PREFIX="${2:?--bundle-prefix needs a value}"; shift 2 ;;
        --identity)      IDENTITY_INDEX="${2:?--identity needs a value}"; shift 2 ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")/.."

PROJECT="Battery Toolkit.xcodeproj/project.pbxproj"
[ -f "$PROJECT" ] || { echo "run this from a Battery Toolkit checkout" >&2; exit 1; }

#
# 1. Pick a signing identity.
#
IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null | grep '"' || true)
if [ -z "$IDENTITIES" ]; then
    cat >&2 <<'NOIDENT'
No codesigning identity found.

Create a free one in Xcode: Settings -> Accounts -> (your Apple ID) ->
Manage Certificates -> + -> Apple Development. It expires after a week, after
which you re-run this script and rebuild.
NOIDENT
    exit 1
fi

COUNT=$(printf '%s\n' "$IDENTITIES" | wc -l | tr -d ' ')
if [ -z "$IDENTITY_INDEX" ]; then
    if [ "$COUNT" -gt 1 ]; then
        echo "Several signing identities are available:"
        printf '%s\n' "$IDENTITIES"
        echo
        echo "Re-run with --identity <n> to choose one."
        exit 1
    fi
    IDENTITY_INDEX=1
fi

LINE=$(printf '%s\n' "$IDENTITIES" | sed -n "${IDENTITY_INDEX}p")
[ -n "$LINE" ] || { echo "no identity numbered $IDENTITY_INDEX" >&2; exit 1; }

CODESIGN_CN=$(printf '%s\n' "$LINE" | sed -n 's/.*"\(.*\)".*/\1/p')
[ -n "$CODESIGN_CN" ] || { echo "could not read the certificate's common name" >&2; exit 1; }

#
# 2. The team identifier is the certificate's OU, not the identifier inside its
#    common name. Confusing the two is the most common way to end up with an app
#    that builds, installs, and then never connects to its daemon.
#
TEAM_ID=$(security find-certificate -c "$CODESIGN_CN" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | tr ',/' '\n\n' | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p' | head -1)
if [ -z "$TEAM_ID" ]; then
    echo "could not read the team identifier (OU) from the certificate" >&2
    exit 1
fi

#
# 3. Work out what the project currently uses, so this is re-runnable.
#
OLD_PREFIX=$(sed -n 's/.*BT_APP_ID = \(.*\)\.BatteryToolkit;.*/\1/p' "$PROJECT" | head -1)
[ -n "$OLD_PREFIX" ] || { echo "could not read the current bundle prefix" >&2; exit 1; }
OLD_TEAM=$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);.*/\1/p' "$PROJECT" | head -1)
OLD_DAEMON_DIR="${OLD_PREFIX}.batterytoolkitd"
NEW_DAEMON_DIR="${BUNDLE_PREFIX}.batterytoolkitd"

echo "Certificate : $CODESIGN_CN"
echo "Team ID     : $TEAM_ID${OLD_TEAM:+  (was $OLD_TEAM)}"
echo "Bundle IDs  : ${BUNDLE_PREFIX}.*${OLD_PREFIX:+  (was ${OLD_PREFIX}.*)}"
echo

if [ "$DRY_RUN" -eq 1 ]; then
    echo "Would change:"
    echo "  $PROJECT           $(grep -c -e "$OLD_PREFIX\." -e 'BT_CODESIGN_CN' -e 'DEVELOPMENT_TEAM' "$PROJECT") lines"
    for f in BatteryToolkit/BatteryToolkit.entitlements BatteryToolkit/Info.plist uninstall.sh; do
        [ -f "$f" ] && echo "  $f"
    done
    [ -d "$OLD_DAEMON_DIR" ] && echo "  $OLD_DAEMON_DIR/ -> $NEW_DAEMON_DIR/"
    echo
    echo "Nothing written (--dry-run)."
    exit 0
fi

#
# 4. Rewrite. sed -i '' is the BSD form; this is macOS-only software anyway.
#
rewrite() {
    # rewrite <file> — prefix, team and certificate in one pass.
    [ -f "$1" ] || return 0
    sed -i '' \
        -e "s/${OLD_PREFIX}\./${BUNDLE_PREFIX}./g" \
        ${OLD_TEAM:+-e "s/${OLD_TEAM}/${TEAM_ID}/g"} \
        "$1"
}

rewrite "$PROJECT"
# The common name contains characters special to sed, so replace it separately
# using a delimiter it cannot contain.
python3 - "$PROJECT" "$CODESIGN_CN" <<'PY'
import re, sys
path, cn = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
s = re.sub(r'BT_CODESIGN_CN = "[^"]*";', 'BT_CODESIGN_CN = "%s";' % cn, s)
open(path, "w", encoding="utf-8").write(s)
PY

rewrite BatteryToolkit/BatteryToolkit.entitlements
rewrite BatteryToolkit/Info.plist
rewrite uninstall.sh
rewrite "$OLD_DAEMON_DIR/launchd.plist"
rewrite "$OLD_DAEMON_DIR/${OLD_DAEMON_DIR}.plist"

#
# 5. The daemon target's Info.plist and embedded launchd.plist resolve through
#    PRODUCT_NAME, so the directory has to match the target name.
#
move() {
    # move <from> <to> - keep git's index in step when the path is tracked.
    #
    # Ask whether git has this path in its index rather than whether some
    # enclosing directory is a repository: an archive unpacked inside an
    # unrelated checkout answers yes to the latter, and `git mv` then fails on
    # a path it does not know, aborting midway through the rewrite.
    if [ -n "$(git ls-files -- "$1" 2>/dev/null)" ]; then
        git mv "$1" "$2"
    else
        mv "$1" "$2"
    fi
}

if [ "$OLD_DAEMON_DIR" != "$NEW_DAEMON_DIR" ] && [ -d "$OLD_DAEMON_DIR" ]; then
    move "$OLD_DAEMON_DIR" "$NEW_DAEMON_DIR"
    move "$NEW_DAEMON_DIR/${OLD_DAEMON_DIR}.plist" "$NEW_DAEMON_DIR/${NEW_DAEMON_DIR}.plist"
fi

#
# 6. Refuse to leave a broken tree behind.
#
for f in "$PROJECT" \
         BatteryToolkit/BatteryToolkit.entitlements \
         BatteryToolkit/Info.plist \
         "$NEW_DAEMON_DIR/launchd.plist" \
         "$NEW_DAEMON_DIR/${NEW_DAEMON_DIR}.plist"; do
    [ -f "$f" ] || continue
    plutil -lint "$f" >/dev/null || { echo "malformed after rewrite: $f" >&2; exit 1; }
done

cat <<DONE
Done. This is local configuration - do not commit it.

Build:
  xcodebuild -project "Battery Toolkit.xcodeproj" -scheme "Battery Toolkit" \\
    -configuration Release -derivedDataPath build build
DONE
