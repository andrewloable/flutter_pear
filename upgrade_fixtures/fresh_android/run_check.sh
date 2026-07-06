#!/usr/bin/env bash
# D15 upgrade-reliability fixture (flutter_pear-ovt.5.10): a fresh Android
# consumer that adds flutter_pear from HOSTED pub.dev (never a path: dep)
# and proves create -> add -> build -> install -> launch -> worklet-attached
# end to end, exactly like a real app dev would experience it.
#
# Run from this directory (upgrade_fixtures/fresh_android):
#   FLUTTER_PEAR_VERSION=0.2.0-dev.1 ADB_SERIAL=192.168.0.251:5555 ./run_check.sh
#
# Env:
#   FLUTTER_PEAR_VERSION  version constraint to add, without the caret
#                         (default: 0.2.0-dev.1)
#   ADB_SERIAL            adb -s target; if unset, uses whichever single
#                         device/emulator adb already sees
#
# A T4 PASS means: this script exits 0 and printed
# "FIXTURE RESULT: ATTACHED" -- the hosted archive resolved, and a real
# device/emulator ran Pear.start() to a successful handshake.
set -uo pipefail

FLUTTER_PEAR_VERSION="${FLUTTER_PEAR_VERSION:-0.2.0-dev.1}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADB_ARGS=()
if [ -n "${ADB_SERIAL:-}" ]; then
  ADB_ARGS=(-s "$ADB_SERIAL")
fi

cd "$DIR"

echo "== fresh_android: adding flutter_pear:^${FLUTTER_PEAR_VERSION} from hosted pub =="
ADD_LOG="$(mktemp)"
trap 'rm -f "$ADD_LOG"' EXIT
if ! flutter pub add "flutter_pear:^${FLUTTER_PEAR_VERSION}" >"$ADD_LOG" 2>&1; then
  if grep -qiE "version solving failed|no versions of flutter_pear|could not find package" "$ADD_LOG"; then
    echo "WAITING-FOR-HOSTED-ARCHIVE: flutter_pear ^${FLUTTER_PEAR_VERSION} is not resolvable on hosted pub.dev yet."
    cat "$ADD_LOG"
    exit 2
  fi
  echo "FIXTURE RESULT: pub add failed for a reason other than an unhosted version -- see log below" >&2
  cat "$ADD_LOG" >&2
  exit 1
fi
cat "$ADD_LOG"

if grep -qE "^\s*path:\s" pubspec.yaml; then
  echo "FIXTURE RESULT: pubspec.yaml contains a path: dependency -- this fixture must be hosted-pub-only" >&2
  exit 1
fi

if ! adb "${ADB_ARGS[@]}" get-state >/dev/null 2>&1; then
  echo "FIXTURE RESULT: no device/emulator attached (adb get-state failed)" >&2
  exit 1
fi

echo "== building debug apk =="
if ! flutter build apk --debug; then
  echo "FIXTURE RESULT: flutter build apk --debug failed" >&2
  exit 1
fi

APK="build/app/outputs/flutter-apk/app-debug.apk"
echo "== install + launch =="
adb "${ADB_ARGS[@]}" install -r "$APK" >/dev/null
adb "${ADB_ARGS[@]}" logcat -c
adb "${ADB_ARGS[@]}" shell am start -n com.example.fresh_android/.MainActivity >/dev/null

echo "== polling logcat for the readiness marker =="
FOUND=0
CRASHED=0
for _ in $(seq 1 90); do
  if adb "${ADB_ARGS[@]}" logcat -d | grep -q "FLUTTER_PEAR_FIXTURE_ATTACHED"; then
    FOUND=1
    break
  fi
  if adb "${ADB_ARGS[@]}" logcat -d | grep -q "FLUTTER_PEAR_FIXTURE_FAILED"; then
    CRASHED=1
    break
  fi
  sleep 2
done

if [ "$CRASHED" = "1" ]; then
  echo "FIXTURE RESULT: FAILED -- worklet reported a failure, see logcat below" >&2
  adb "${ADB_ARGS[@]}" logcat -d | grep "FLUTTER_PEAR_FIXTURE_FAILED" >&2
  exit 1
fi
if [ "$FOUND" != "1" ]; then
  echo "FIXTURE RESULT: FAILED -- marker never appeared within the polling window" >&2
  exit 1
fi
echo "FIXTURE RESULT: ATTACHED"
