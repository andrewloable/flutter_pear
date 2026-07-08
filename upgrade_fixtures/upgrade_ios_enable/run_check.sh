#!/usr/bin/env bash
# D15 upgrade-reliability fixture (flutter_pear-ovt.5.11): a LOCKED
# Android-only v0.1 consumer (hosted flutter_pear: 0.0.1, pubspec.lock
# committed, no committed ios/) that then runs the documented
# upgrade-and-enable-iOS recipe VERBATIM, step by step, so a wording change
# in that recipe breaks this script instead of silently drifting out of
# sync.
#
# REMAINING GAP (see this fixture's README and flutter_pear-ovt.5.11's bd
# notes): steps 3-4 below paste the same NSLocalNetworkUsageDescription
# string shipped in packages/flutter_pear_example/ios/Runner/Info.plist
# (flutter_pear-ovt.4.1), confirmed technically sufficient by
# flutter_pear-ovt.1.12's closed FEAS-TCC spike -- but no polished
# flutter_pear-ovt.6 consumer doc page exists yet to formally prescribe
# this exact copy. Re-point at that doc once it ships; if its wording
# differs, update both to match.
#
# The documented recipe (plan F1/D18, DX2 decision 46), each step
# source-annotated:
#   1. `flutter create --platforms=ios .`            -- Flutter-standard,
#      not flutter_pear-specific.
#   2. `dart pub add flutter_pear:^$FLUTTER_PEAR_VERSION` -- DX2 decision 46
#      (a bare `pub upgrade` cannot cross the already-published ^0.0.1
#      caret).
#   3-4. Paste the NSLocalNetworkUsageDescription Info.plist block -- iOS
#      14+ requires a usage string for LAN access; sourced from the shipped
#      example app's Info.plist (see REMAINING GAP above re: the doc page).
#   5. `flutter run` -- Flutter-standard.
#
# Two legs:
#   leg 1 (--locked-only): build the Android-only base at locked 0.0.1 --
#     proves the fixture itself is sound before ever touching the recipe.
#   leg 2: runs the recipe verbatim, then the same simulator
#     run-and-wait-for-marker leg as fresh_ios.
#
# Run from this directory (upgrade_fixtures/upgrade_ios_enable):
#   ./run_check.sh --locked-only
#   FLUTTER_PEAR_VERSION=0.2.0-dev.1 ./run_check.sh
set -uo pipefail

LOCKED_ONLY=0
if [ "${1:-}" = "--locked-only" ]; then
  LOCKED_ONLY=1
fi

FLUTTER_PEAR_VERSION="${FLUTTER_PEAR_VERSION:-0.2.0-dev.1}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

if ! grep -qE "^\s*flutter_pear:\s*0\.0\.1\s*$" pubspec.yaml; then
  echo "FIXTURE RESULT: pubspec.yaml is not locked to flutter_pear: 0.0.1 -- fixture integrity broken" >&2
  exit 1
fi

echo "== leg 1: locked 0.0.1 Android-only base build (fixture integrity) =="
if ! flutter build apk --debug; then
  echo "FIXTURE RESULT: flutter build apk --debug failed on the locked 0.0.1 Android-only base" >&2
  exit 1
fi
echo "leg 1 PASSED"

if [ "$LOCKED_ONLY" = "1" ]; then
  echo "FIXTURE RESULT: ATTACHED (--locked-only, leg 1 alone)"
  exit 0
fi

echo
echo "== leg 2: recipe step 1/5 -- flutter create --platforms=ios . =="
if ! flutter create --platforms=ios .; then
  echo "FIXTURE RESULT: flutter create --platforms=ios . failed" >&2
  exit 1
fi

echo "== leg 2: recipe step 2/5 -- dart pub add flutter_pear:^${FLUTTER_PEAR_VERSION} =="
ADD_LOG="$(mktemp)"
if ! dart pub add "flutter_pear:^${FLUTTER_PEAR_VERSION}" >"$ADD_LOG" 2>&1; then
  if grep -qiE "version solving failed|no versions of flutter_pear|could not find package" "$ADD_LOG"; then
    echo "WAITING-FOR-HOSTED-ARCHIVE: flutter_pear ^${FLUTTER_PEAR_VERSION} is not resolvable on hosted pub.dev yet."
    cat "$ADD_LOG"
    rm -f "$ADD_LOG"
    exit 2
  fi
  echo "FIXTURE RESULT: pub add failed for a reason other than an unhosted version -- see log below" >&2
  cat "$ADD_LOG" >&2
  rm -f "$ADD_LOG"
  exit 1
fi
cat "$ADD_LOG"
rm -f "$ADD_LOG"

if grep -qE "^\s*path:\s" pubspec.yaml; then
  echo "FIXTURE RESULT: pubspec.yaml contains a path: dependency after the recipe -- must stay hosted-pub-only" >&2
  exit 1
fi

echo "== leg 2: recipe steps 3-4/5 -- Info.plist NSLocalNetworkUsageDescription (sourced from the shipped example app, see REMAINING GAP) =="
/usr/libexec/PlistBuddy -c \
  "Add :NSLocalNetworkUsageDescription string 'flutter_pear demos connect directly to your other devices over the local network to exchange chat messages and files.'" \
  ios/Runner/Info.plist || {
  echo "FIXTURE RESULT: PlistBuddy failed to insert NSLocalNetworkUsageDescription" >&2
  exit 1
}

echo "== leg 2: recipe step 5/5 -- flutter run on a simulator =="
LOG_FILE="$(mktemp -t upgrade_ios_enable_run.XXXXXX.log)"
PID_FILE="$(mktemp -t upgrade_ios_enable_run.XXXXXX.pid)"
BOOTED_SIM_BY_US=""
FLUTTER_RUN_PID=""

cleanup() {
  if [ -n "$FLUTTER_RUN_PID" ] && kill -0 "$FLUTTER_RUN_PID" >/dev/null 2>&1; then
    kill "$FLUTTER_RUN_PID" >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
      kill -0 "$FLUTTER_RUN_PID" >/dev/null 2>&1 || break
      sleep 1
    done
    kill -9 "$FLUTTER_RUN_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$BOOTED_SIM_BY_US" ]; then
    xcrun simctl shutdown "$BOOTED_SIM_BY_US" >/dev/null 2>&1 || true
  fi
  rm -f "$LOG_FILE" "$PID_FILE"
}
trap cleanup EXIT

UDID="$(xcrun simctl list devices available -j 2>/dev/null | \
  python3 -c "
import json, sys
data = json.load(sys.stdin)
booted = []
shutdown = []
for runtime, devices in data.get('devices', {}).items():
    if 'iOS' not in runtime:
        continue
    for d in devices:
        if 'iPhone' not in d.get('name', ''):
            continue
        (booted if d.get('state') == 'Booted' else shutdown).append(d['udid'])
for udid in booted + shutdown:
    print(udid)
    break
")"

if [ -z "$UDID" ]; then
  echo "FIXTURE RESULT: no iPhone simulator available (xcrun simctl list devices available)" >&2
  exit 1
fi

STATE="$(xcrun simctl list devices -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for devices in data.get('devices', {}).values():
    for d in devices:
        if d['udid'] == '$UDID':
            print(d['state'])
")"
if [ "$STATE" != "Booted" ]; then
  echo "== booting simulator $UDID =="
  xcrun simctl boot "$UDID"
  BOOTED_SIM_BY_US="$UDID"
  sleep 5
fi
echo "using simulator $UDID"

flutter run -d "$UDID" --pid-file "$PID_FILE" >"$LOG_FILE" 2>&1 &
BG_SHELL_PID=$!

for _ in $(seq 1 30); do
  [ -s "$PID_FILE" ] && break
  sleep 1
done
if [ -s "$PID_FILE" ]; then
  FLUTTER_RUN_PID="$(cat "$PID_FILE")"
else
  FLUTTER_RUN_PID="$BG_SHELL_PID"
fi

echo "== polling captured log for the readiness marker (no flutter clean was run) =="
FOUND=0
CRASHED=0
for _ in $(seq 1 90); do
  if grep -q "FLUTTER_PEAR_FIXTURE_ATTACHED" "$LOG_FILE" 2>/dev/null; then
    FOUND=1
    break
  fi
  if grep -qE "FLUTTER_PEAR_FIXTURE_FAILED|MissingPluginException" "$LOG_FILE" 2>/dev/null; then
    CRASHED=1
    break
  fi
  sleep 2
done

if [ "$CRASHED" = "1" ]; then
  echo "FIXTURE RESULT: FAILED -- worklet reported a failure, see captured log below" >&2
  grep -E "FLUTTER_PEAR_FIXTURE_FAILED|MissingPluginException" "$LOG_FILE" >&2
  exit 1
fi
if [ "$FOUND" != "1" ]; then
  echo "FIXTURE RESULT: FAILED -- marker never appeared within the polling window; tail of captured log:" >&2
  tail -40 "$LOG_FILE" >&2
  exit 1
fi
echo "FIXTURE RESULT: ATTACHED (upgraded-and-enabled-iOS to ${FLUTTER_PEAR_VERSION})"
