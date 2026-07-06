#!/usr/bin/env bash
# D15 upgrade-reliability fixture (flutter_pear-ovt.5.10): a LOCKED v0.1
# consumer -- pubspec.yaml pins flutter_pear: 0.0.1 exactly and
# pubspec.lock is committed -- that then bumps to the v0.2 line via the
# real DX2 decision 46 upgrade command (dart pub add
# flutter_pear:^0.2.0-dev.1; a bare `pub upgrade` cannot cross the ^0.0.1
# caret already published). android/ carries realistic customization
# (custom applicationId, non-default minSdk, a custom BuildConfig field)
# so the upgrade is proven against something closer to a real project than
# a stock template.
#
# Two legs:
#   leg 1 (--locked-only): build + install + launch at the LOCKED 0.0.1
#     state, no dependency changes -- proves the fixture itself is sound
#     before ever touching the upgrade.
#   leg 2: runs the upgrade command, rebuilds WITHOUT `flutter clean`
#     (an upgrade must not require nuking build state), reinstalls, and
#     waits for the same readiness marker.
#
# Run from this directory (upgrade_fixtures/upgrade_android):
#   ADB_SERIAL=192.168.0.251:5555 ./run_check.sh --locked-only
#   FLUTTER_PEAR_VERSION=0.2.0-dev.1 ADB_SERIAL=192.168.0.251:5555 ./run_check.sh
#
# Env:
#   FLUTTER_PEAR_VERSION  version constraint for leg 2's upgrade
#                         (default: 0.2.0-dev.1)
#   ADB_SERIAL            adb -s target; if unset, uses whichever single
#                         device/emulator adb already sees
set -uo pipefail

LOCKED_ONLY=0
if [ "${1:-}" = "--locked-only" ]; then
  LOCKED_ONLY=1
fi

FLUTTER_PEAR_VERSION="${FLUTTER_PEAR_VERSION:-0.2.0-dev.1}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ID="com.fpfixture.upgrade_android"
ADB_ARGS=()
if [ -n "${ADB_SERIAL:-}" ]; then
  ADB_ARGS=(-s "$ADB_SERIAL")
fi

cd "$DIR"

wait_for_marker() {
  local FOUND=0
  local CRASHED=0
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
    return 1
  fi
  if [ "$FOUND" != "1" ]; then
    echo "FIXTURE RESULT: FAILED -- marker never appeared within the polling window" >&2
    return 1
  fi
  return 0
}

build_install_launch() {
  local LABEL="$1"
  echo "== $LABEL: build (debug apk) =="
  if ! flutter build apk --debug; then
    echo "FIXTURE RESULT: flutter build apk --debug failed ($LABEL)" >&2
    return 1
  fi
  echo "== $LABEL: install + launch =="
  adb "${ADB_ARGS[@]}" install -r "build/app/outputs/flutter-apk/app-debug.apk" >/dev/null
  adb "${ADB_ARGS[@]}" logcat -c
  adb "${ADB_ARGS[@]}" shell am start -n "$APP_ID/.MainActivity" >/dev/null
  echo "== $LABEL: polling logcat for the readiness marker =="
  wait_for_marker
}

if ! adb "${ADB_ARGS[@]}" get-state >/dev/null 2>&1; then
  echo "FIXTURE RESULT: no device/emulator attached (adb get-state failed)" >&2
  exit 1
fi

if ! grep -qE "^\s*flutter_pear:\s*0\.0\.1\s*$" pubspec.yaml; then
  echo "FIXTURE RESULT: pubspec.yaml is not locked to flutter_pear: 0.0.1 -- fixture integrity broken" >&2
  exit 1
fi

echo "== leg 1: locked 0.0.1 build + launch (fixture integrity) =="
if ! build_install_launch "leg1-locked-0.0.1"; then
  exit 1
fi
echo "leg 1 PASSED"

if [ "$LOCKED_ONLY" = "1" ]; then
  echo "FIXTURE RESULT: ATTACHED (--locked-only, leg 1 alone)"
  exit 0
fi

echo
echo "== leg 2: upgrading to flutter_pear:^${FLUTTER_PEAR_VERSION} (DX2 decision 46) =="
ADD_LOG="$(mktemp)"
trap 'rm -f "$ADD_LOG"' EXIT
if ! dart pub add "flutter_pear:^${FLUTTER_PEAR_VERSION}" >"$ADD_LOG" 2>&1; then
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
  echo "FIXTURE RESULT: pubspec.yaml contains a path: dependency after upgrade -- must stay hosted-pub-only" >&2
  exit 1
fi

# Deliberately no `flutter clean` here -- an upgrade must work against
# existing build state, matching what a real app dev does.
if ! build_install_launch "leg2-upgraded-${FLUTTER_PEAR_VERSION}"; then
  exit 1
fi
echo "FIXTURE RESULT: ATTACHED (upgraded to ${FLUTTER_PEAR_VERSION})"
