#!/usr/bin/env bash
# D15 upgrade-reliability fixture (flutter_pear-ovt.5.11): a fresh iOS
# consumer that adds flutter_pear from HOSTED pub.dev (never a path: dep)
# and proves create -> add -> run -> worklet-attached end to end on an
# iOS simulator.
#
# REMAINING GAP (see the fixture's README and flutter_pear-ovt.5.11's bd
# notes): ios/Runner/Info.plist's NSLocalNetworkUsageDescription string is
# sourced from the real, shipped packages/flutter_pear_example Info.plist
# and confirmed technically sufficient by flutter_pear-ovt.1.12's closed
# FEAS-TCC spike (only this one key is needed -- no NSBonjourServices, no
# multicast entitlement) -- but no polished flutter_pear-ovt.6 consumer doc
# page exists yet to formally prescribe this exact copy. Re-point at that
# doc once it ships; if its wording differs, update both to match.
#
# Run from this directory (upgrade_fixtures/fresh_ios):
#   FLUTTER_PEAR_VERSION=0.2.0-dev.1 ./run_check.sh
#
# Env:
#   FLUTTER_PEAR_VERSION  version constraint to add, without the caret
#                         (default: 0.2.0-dev.1)
#
# A T4 PASS means: this script exits 0 and printed
# "FIXTURE RESULT: ATTACHED" -- the hosted archive resolved, and the
# simulator ran Pear.start() to a successful handshake.
#
# Note: hosted flutter_pear 0.0.1 ships NO iOS support at all (0.0.1's
# flutter_pear_bare has no ios/), so FLUTTER_PEAR_VERSION=0.0.1 is EXPECTED
# to fail at the marker step -- that failure, captured and reported clearly
# instead of hanging, IS this fixture's proof that the harness's
# failure-detection works, not a bug in the fixture.
set -uo pipefail

FLUTTER_PEAR_VERSION="${FLUTTER_PEAR_VERSION:-0.2.0-dev.1}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

LOG_FILE="$(mktemp -t fresh_ios_run.XXXXXX.log)"
PID_FILE="$(mktemp -t fresh_ios_run.XXXXXX.pid)"
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

echo "== fresh_ios: adding flutter_pear:^${FLUTTER_PEAR_VERSION} from hosted pub =="
ADD_LOG="$(mktemp)"
if ! flutter pub add "flutter_pear:^${FLUTTER_PEAR_VERSION}" >"$ADD_LOG" 2>&1; then
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
  echo "FIXTURE RESULT: pubspec.yaml contains a path: dependency -- this fixture must be hosted-pub-only" >&2
  exit 1
fi

echo "== locating an iPhone simulator =="
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
  for _ in $(seq 1 30); do
    xcrun simctl list devices -j 2>/dev/null | grep -qF "\"$UDID\"" && \
      [ "$(xcrun simctl list devices -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for devices in data.get('devices', {}).values():
    for d in devices:
        if d['udid'] == '$UDID':
            print(d['state'])
")" = "Booted" ] && break
    sleep 2
  done
fi
echo "using simulator $UDID"

echo "== flutter run -d $UDID (log: $LOG_FILE) =="
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

echo "== polling captured log for the readiness marker =="
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
echo "FIXTURE RESULT: ATTACHED"
