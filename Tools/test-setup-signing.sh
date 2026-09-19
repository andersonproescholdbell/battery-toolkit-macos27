#!/bin/sh
#
# Self-check for setup-signing.sh.
#
# The README tells downloaders to run that script, so its failure modes land on
# people who cannot debug them. These cases cover the paths a downloader hits
# that a normal `git clone` here does not, in particular an archive unpacked
# inside an unrelated checkout.
#
# Operates entirely on throwaway copies. Never touches the checkout it lives in.
#
# Copyright (C) 2026 Battery Toolkit macOS 27 fork contributors.
# SPDX-License-Identifier: BSD-3-Clause
#

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL + 1)); echo "  [FAIL] $1: $2"; }

check() {
    # check <description> <condition-result> <detail>
    if [ "$2" -eq 0 ]; then ok "$1"; else no "$1" "$3"; fi
}

# A pristine copy of the committed tree, which is what a downloader receives.
git -C "$REPO" archive --format=tar HEAD | (mkdir -p "$WORK/pristine" && tar -x -C "$WORK/pristine")
# Test the script as it stands in the working tree, not the committed copy -
# otherwise a fix cannot be verified before it is committed.
cp "$REPO/Tools/setup-signing.sh" "$WORK/pristine/Tools/setup-signing.sh"

fresh() {
    # fresh <name> [git] - a copy to mutate, optionally a real checkout.
    dir="$WORK/$1"
    rm -rf "$dir"
    cp -R "$WORK/pristine" "$dir"
    if [ "${2:-}" = "git" ]; then
        git -C "$dir" init -q .
        git -C "$dir" add -A >/dev/null 2>&1
        git -C "$dir" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
    fi
    echo "$dir"
}

daemon_dir() {
    # The daemon directory currently present in <dir>.
    find "$1" -maxdepth 1 -type d -name "*.batterytoolkitd" -exec basename {} \; 2>/dev/null | head -1
}

echo "setup-signing.sh self-check"
echo

# 1. A normal checkout: the path already exercised by hand.
d=$(fresh clone git)
(cd "$d" && Tools/setup-signing.sh >/dev/null 2>&1)
check "git checkout: exits 0" $? "script failed"
[ -n "$(daemon_dir "$d")" ] && [ "$(daemon_dir "$d")" != "io.github.andersonproescholdbell.batterytoolkitd" ]
check "git checkout: daemon directory renamed" $? "still $(daemon_dir "$d")"
plutil -lint "$d/Battery Toolkit.xcodeproj/project.pbxproj" >/dev/null 2>&1
check "git checkout: project file well-formed" $? "plutil rejected it"

# 2. An archive unpacked inside an unrelated repository. This is the case the
#    original `git rev-parse` check got wrong.
outer="$WORK/outer"
mkdir -p "$outer"
git -C "$outer" init -q .
d="$outer/unpacked"
cp -R "$WORK/pristine" "$d"
(cd "$d" && Tools/setup-signing.sh >/dev/null 2>&1)
check "unpacked archive inside a repo: exits 0" $? "script failed - the git check is wrong"
[ -n "$(daemon_dir "$d")" ] && [ "$(daemon_dir "$d")" != "io.github.andersonproescholdbell.batterytoolkitd" ]
check "unpacked archive: daemon directory renamed" $? "rename did not happen"
grep -q "local.batterytoolkit" "$d/Battery Toolkit.xcodeproj/project.pbxproj" 2>/dev/null
check "unpacked archive: identifiers rewritten" $? "project file not rewritten"

# 3. An identity index that does not exist.
d=$(fresh badident git)
(cd "$d" && Tools/setup-signing.sh --identity 99 >/dev/null 2>&1)
[ $? -ne 0 ]
check "nonexistent --identity: exits non-zero" $? "accepted a bad index"
grep -q "YOUR NAME" "$d/Battery Toolkit.xcodeproj/project.pbxproj" 2>/dev/null
check "nonexistent --identity: wrote nothing" $? "modified the tree before failing"

# 4. A caller-chosen bundle prefix.
d=$(fresh prefix git)
(cd "$d" && Tools/setup-signing.sh --bundle-prefix com.example.test >/dev/null 2>&1)
check "custom --bundle-prefix: exits 0" $? "script failed"
[ "$(daemon_dir "$d")" = "com.example.test.batterytoolkitd" ]
check "custom --bundle-prefix: daemon directory uses it" $? "got $(daemon_dir "$d")"
grep -q "BT_APP_ID = com.example.test.BatteryToolkit;" "$d/Battery Toolkit.xcodeproj/project.pbxproj" 2>/dev/null
check "custom --bundle-prefix: identifiers use it" $? "BT_APP_ID not rewritten"

# 5. Run from somewhere that is not a checkout.
mkdir -p "$WORK/elsewhere/Tools"
cp "$REPO/Tools/setup-signing.sh" "$WORK/elsewhere/Tools/"
(cd "$WORK/elsewhere" && Tools/setup-signing.sh >/dev/null 2>&1)
[ $? -ne 0 ]
check "wrong directory: exits non-zero" $? "ran outside a checkout"

# 6. --dry-run writes nothing.
d=$(fresh dryrun git)
(cd "$d" && Tools/setup-signing.sh --dry-run >/dev/null 2>&1)
check "--dry-run: exits 0" $? "script failed"
[ -z "$(git -C "$d" status --porcelain)" ]
check "--dry-run: tree unchanged" $? "wrote something"

# 7. Re-running changes nothing further.
d=$(fresh idem git)
(cd "$d" && Tools/setup-signing.sh >/dev/null 2>&1)
git -C "$d" add -A >/dev/null 2>&1
before=$(git -C "$d" status --porcelain | sort)
(cd "$d" && Tools/setup-signing.sh >/dev/null 2>&1)
git -C "$d" add -A >/dev/null 2>&1
[ "$before" = "$(git -C "$d" status --porcelain | sort)" ]
check "re-run: idempotent" $? "second run changed the tree"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "OK - $PASS checks passed"
    exit 0
fi
echo "$FAIL of $((PASS + FAIL)) checks FAILED"
exit 1
