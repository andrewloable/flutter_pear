#!/usr/bin/env bash
# flutter_pear-ovt.5.12: the ONE by-hand release command (plan 6.6). This
# repo deliberately has no CI (see COMPATIBILITY.md's header) -- every
# quality gate a release depends on runs here, in order, so nothing is
# forgotten the way an ad-hoc checklist can be. Modeled on
# packages/flutter_pear/tool/fresh_machine_check.sh's "no CI, run by hand"
# pattern.
#
# Usage (from the repo root):
#   tool/release_gate.sh                # run every gate in order
#   tool/release_gate.sh --list         # print gate names, do nothing else
#   tool/release_gate.sh --only <gate>  # run exactly one gate
#
# RELEASE_GATE_ADB_SERIAL=<serial> tool/release_gate.sh   # fresh-machine
#   gate targets exactly this adb serial. Required whenever more than one
#   device is attached -- the gate fails rather than guess (flutter_pear-9ho:
#   this repo's own dev machine has a permanently attached, unrelated-project
#   BYD head unit).
#
# Contract: any gate failure = nonzero exit + the summary names exactly
# which gate(s) failed. Gates never stop the run early -- every gate always
# executes so one failure doesn't hide a second, unrelated one. A SKIP of
# the pack-regression test is itself reported as a FAILURE (Eng2 #7): a
# skipped critical test must never read as green.
#
# This script is idempotent and re-runnable, and never runs `git commit` or
# `git push` -- every gate only reads or builds into gitignored build/
# output, except where a gate explicitly says otherwise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_PEAR="$REPO_ROOT/packages/flutter_pear"
FLUTTER_PEAR_BARE="$REPO_ROOT/packages/flutter_pear_bare"
FLUTTER_PEAR_TEST="$REPO_ROOT/packages/flutter_pear_test"
FLUTTER_PEAR_EXAMPLE="$REPO_ROOT/packages/flutter_pear_example"

GATE_ORDER=(
  bootstrap analyze dart-tests pear-end compatibility pins pana licenses
  fresh-machine pack-regression ios-smoke apk ipa-inspect macos-build macos-smoke
  linux-build linux-smoke windows-build windows-smoke
)

# macOS ships bash 3.2 (no associative arrays) -- results are recorded as
# "gate|RESULT|cause" lines in a plain indexed array instead.
RESULTS=()

record() {
  # record <gate> <PASS|FAIL> [cause]
  RESULTS+=("$1|$2|${3:-}")
}

result_for() {
  # result_for <gate> -> prints RESULT (PASS/FAIL) or empty if not run
  local g="$1" entry
  for entry in "${RESULTS[@]}"; do
    if [ "${entry%%|*}" = "$g" ]; then
      entry="${entry#*|}"
      echo "${entry%%|*}"
      return
    fi
  done
}

cause_for() {
  # cause_for <gate> -> prints cause, or empty
  local g="$1" entry
  for entry in "${RESULTS[@]}"; do
    if [ "${entry%%|*}" = "$g" ]; then
      echo "${entry#*|*|}"
      return
    fi
  done
}

# ---------------------------------------------------------------------------
# Gates
# ---------------------------------------------------------------------------

gate_bootstrap() {
  if (cd "$REPO_ROOT" && melos bootstrap); then
    record bootstrap PASS
  else
    record bootstrap FAIL "melos bootstrap failed"
  fi
}

gate_analyze() {
  if (cd "$REPO_ROOT" && melos run analyze); then
    record analyze PASS
  else
    record analyze FAIL "melos run analyze reported issues"
  fi
}

gate_dart-tests() {
  if (cd "$REPO_ROOT" && melos run test --no-select); then
    record dart-tests PASS
  else
    record dart-tests FAIL "melos run test --no-select had failing/erroring tests"
  fi
}

gate_pear-end() {
  if (cd "$FLUTTER_PEAR/pear-end" && npm test); then
    record pear-end PASS
  else
    record pear-end FAIL "npm test failed in packages/flutter_pear/pear-end"
  fi
}

gate_compatibility() {
  if (cd "$FLUTTER_PEAR" && dart run flutter_pear:check_compatibility); then
    record compatibility PASS
  else
    record compatibility FAIL "dart run flutter_pear:check_compatibility failed"
  fi
}

gate_pins() {
  if (cd "$FLUTTER_PEAR" && dart run flutter_pear:check_pins --strict); then
    record pins PASS
  else
    record pins FAIL "dart run flutter_pear:check_pins --strict reported pins out of sync (or required-but-missing)"
  fi
}

# pub_dev_status <package> <version> -> prints "published", else the latest
# published version; prints nothing if pub.dev can't be read.
pub_dev_status() {
  curl -fsS "https://pub.dev/api/packages/$1" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('published' if '$2' in [v['version'] for v in d['versions']] else d['latest']['version'])
" 2>/dev/null
}

gate_pana() {
  if ! dart pub global list 2>/dev/null | grep -q "^pana "; then
    echo "pana not found -- activating (dart pub global activate pana)"
    dart pub global activate pana || true
  fi

  local ok=1
  local causes=""
  for pkg in flutter_pear flutter_pear_bare flutter_pear_test; do
    echo "== pana: $pkg =="
    local pkg_dir="$REPO_ROOT/packages/$pkg" scratch=""
    if [ "$pkg" = flutter_pear ]; then
      # flutter_pear-mib: flutter_pear pins flutter_pear_bare to its own
      # release, and pana resolves against pub.dev -- before that release is
      # published it can't solve and loses most of its points. Score a
      # scratch copy relaxed to the latest published caret instead. The real
      # pubspec is never touched; its pin is what keeps desktop users off
      # bundleVersionMismatch.
      local bare_ver latest
      bare_ver="$(awk '/^version:/{print $2; exit}' "$FLUTTER_PEAR_BARE/pubspec.yaml")"
      latest="$(pub_dev_status flutter_pear_bare "$bare_ver")"
      if [ -z "$latest" ]; then
        ok=0
        causes="$causes $pkg(could not read flutter_pear_bare's versions from pub.dev)"
        continue
      fi
      if [ "$latest" != published ]; then
        echo "flutter_pear_bare $bare_ver is not on pub.dev yet -- scoring a scratch copy with flutter_pear_bare: ^$latest (real pubspec unchanged)"
        scratch="$(mktemp -d)"
        pkg_dir="$scratch/flutter_pear"
        rsync -a --exclude build --exclude node_modules --exclude .dart_tool "$FLUTTER_PEAR/" "$pkg_dir/"
        sed -i.bak "s/^  flutter_pear_bare: .*/  flutter_pear_bare: ^$latest/" "$pkg_dir/pubspec.yaml"
        rm -f "$pkg_dir/pubspec.yaml.bak"
      fi
    fi
    if [ "$pkg" = flutter_pear_test ]; then
      # flutter_pear-601: the fake tracks flutter_pear's newest API, so its
      # flutter_pear lower bound is often the release being cut. pana can't
      # resolve that before it's published, and relaxing it the way the
      # flutter_pear branch above does would only score real compile errors.
      local need status
      need="$(awk '/^  flutter_pear: \^/{print substr($2, 2); exit}' "$FLUTTER_PEAR_TEST/pubspec.yaml")"
      if [ -n "$need" ]; then
        status="$(pub_dev_status flutter_pear "$need")"
        if [ -z "$status" ]; then
          ok=0
          causes="$causes $pkg(could not read flutter_pear's versions from pub.dev)"
          continue
        elif [ "$status" != published ]; then
          ok=0
          causes="$causes $pkg(needs flutter_pear $need, not on pub.dev yet -- re-run --only pana after it publishes)"
          continue
        fi
      fi
    fi
    local json_out
    json_out="$(cd "$pkg_dir" && dart pub global run pana --no-warning --json 2>/dev/null)"
    [ -n "$scratch" ] && rm -rf "$scratch"
    if [ -z "$json_out" ]; then
      ok=0
      causes="$causes $pkg(pana produced no output)"
      continue
    fi
    local points
    points="$(echo "$json_out" | python3 -c "import json,sys; print(json.load(sys.stdin).get('scores',{}).get('grantedPoints', json.load(open('/dev/null')) if False else 'NA'))" 2>/dev/null)"
    if [ -z "$points" ] || [ "$points" = "NA" ]; then
      # pana's JSON schema has varied across versions -- fall back to a
      # top-level grantedPoints key if scores.grantedPoints isn't there.
      points="$(echo "$json_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('grantedPoints', d.get('scores',{}).get('grantedPoints','NA')))" 2>/dev/null)"
    fi
    echo "$pkg grantedPoints: $points"
    if [ -z "$points" ] || [ "$points" = "NA" ] || ! [ "$points" -ge 130 ] 2>/dev/null; then
      ok=0
      causes="$causes $pkg(grantedPoints=$points, need >=130)"
    fi
  done

  if [ "$ok" = "1" ]; then
    record pana PASS
  else
    record pana FAIL "${causes# }"
  fi
}

gate_licenses() {
  local ok=1
  local causes=""

  local tpl="$FLUTTER_PEAR/THIRD_PARTY_LICENSES"
  if [ ! -s "$tpl" ]; then
    ok=0
    causes="$causes THIRD_PARTY_LICENSES(missing or empty)"
  elif ! grep -q "Apache License" "$tpl"; then
    ok=0
    causes="$causes THIRD_PARTY_LICENSES(no 'Apache License' text found)"
  fi

  for pkg in flutter_pear flutter_pear_bare flutter_pear_test; do
    if [ ! -s "$REPO_ROOT/packages/$pkg/LICENSE" ]; then
      ok=0
      causes="$causes $pkg/LICENSE(missing or empty)"
    fi
  done

  if [ "$ok" = "1" ]; then
    record licenses PASS
  else
    record licenses FAIL "${causes# }"
  fi
}

gate_fresh-machine() {
  local emulator_udid=""
  local booted_by_us=""
  local sdk="$HOME/Library/Android/sdk"

  if ! adb devices | grep -qE "\bdevice$"; then
    if [ -x "$sdk/emulator/emulator" ]; then
      emulator_udid="$("$sdk/emulator/emulator" -list-avds 2>/dev/null | head -1)"
    fi
    if [ -z "$emulator_udid" ]; then
      record fresh-machine FAIL "no Android device/emulator attached, and no AVD available to boot one"
      return
    fi
    echo "no device attached -- booting AVD $emulator_udid as a substitute (accepted per the flutter_pear-doi precedent)"
    nohup "$sdk/emulator/emulator" -avd "$emulator_udid" -no-snapshot -no-boot-anim >/dev/null 2>&1 &
    booted_by_us=1
    for _ in $(seq 1 60); do
      adb devices | grep -qE "\bdevice$" && break
      sleep 2
    done
  fi

  # Disambiguate which attached device/emulator fresh_machine_check.sh's
  # plain (unflagged) `adb` calls should target when more than one is
  # present (e.g. this repo's historical physical BYD device, which is a
  # different project's hardware and known incompatible with
  # flutter_pear_bare -- see flutter_pear-ovt.1.8). RELEASE_GATE_ADB_SERIAL
  # (flutter_pear-1wx), if set, is used directly rather than picking
  # whichever "device"-state entry `adb devices` happens to list first --
  # on THIS machine the BYD is permanently attached and, being connected
  # long before any emulator this gate boots, reliably wins that race,
  # deterministically failing the gate on a device it was never meant to
  # exercise. When unset, exactly one attached device is used as-is; with
  # several, the gate refuses to guess (flutter_pear-9ho: an unpinned run
  # once installed the probe app on the car head unit).
  local target
  if [ -n "${RELEASE_GATE_ADB_SERIAL:-}" ]; then
    if adb devices | awk '$2=="device"{print $1}' | grep -qx "$RELEASE_GATE_ADB_SERIAL"; then
      target="$RELEASE_GATE_ADB_SERIAL"
    else
      record fresh-machine FAIL "RELEASE_GATE_ADB_SERIAL=$RELEASE_GATE_ADB_SERIAL is not in the 'device' state (check adb devices)"
      return
    fi
  else
    local attached
    attached="$(adb devices | awk '$2=="device"{print $1}')"
    if [ "$(echo "$attached" | grep -c .)" -gt 1 ]; then
      record fresh-machine FAIL "several devices attached ($(echo $attached)) and RELEASE_GATE_ADB_SERIAL is unset -- set it to the one to target"
      return
    fi
    target="$attached"
  fi
  if [ -z "$target" ]; then
    record fresh-machine FAIL "no device/emulator reached the 'device' state in time"
  else
    echo "targeting $target (ANDROID_SERIAL) for fresh_machine_check.sh"
    if ANDROID_SERIAL="$target" bash "$FLUTTER_PEAR/tool/fresh_machine_check.sh"; then
      record fresh-machine PASS
    else
      record fresh-machine FAIL "fresh_machine_check.sh failed against $target -- see its own TTHW error above"
    fi
  fi

  if [ -n "$booted_by_us" ] && [ -n "$emulator_udid" ]; then
    local booted_serial
    booted_serial="$(adb devices | awk '/emulator-/{print $1; exit}')"
    [ -n "$booted_serial" ] && adb -s "$booted_serial" emu kill >/dev/null 2>&1 || true
  fi
}

gate_pack-regression() {
  local out
  out="$(cd "$FLUTTER_PEAR" && flutter test test/pack_android_regression_test.dart 2>&1)"
  echo "$out"
  if echo "$out" | grep -q "PACK_REGRESSION_SKIPPED"; then
    record pack-regression FAIL "the pack regression test was SKIPPED (PACK_REGRESSION_SKIPPED) -- a skip of this critical test is a gate failure, never a false green (Eng2 #7)"
  elif echo "$out" | grep -qE '\+[0-9]+ ~[0-9]+'; then
    record pack-regression FAIL "flutter test reported skipped test(s) (~N in the summary line)"
  elif echo "$out" | grep -q "All tests passed"; then
    record pack-regression PASS
  else
    record pack-regression FAIL "flutter test did not report a clean pass -- see output above"
  fi
}

# Shared by ios-smoke and ipa-inspect: locate an already-booted iPhone
# simulator, else boot the first available one. Prints the UDID on stdout;
# sets SIM_BOOTED_BY_US (global) if this call booted it.
SIM_BOOTED_BY_US=""
locate_or_boot_iphone_sim() {
  local udid
  udid="$(xcrun simctl list devices available -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
booted, shutdown = [], []
for runtime, devices in data.get('devices', {}).items():
    if 'iOS' not in runtime:
        continue
    for d in devices:
        if 'iPhone' not in d.get('name', ''):
            continue
        (booted if d.get('state') == 'Booted' else shutdown).append(d['udid'])
for u in booted + shutdown:
    print(u)
    break
")"
  if [ -z "$udid" ]; then
    return 1
  fi
  local state
  state="$(xcrun simctl list devices -j 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for devices in data.get('devices', {}).values():
    for d in devices:
        if d['udid'] == '$udid':
            print(d['state'])
")"
  if [ "$state" != "Booted" ]; then
    xcrun simctl boot "$udid" >/dev/null 2>&1
    SIM_BOOTED_BY_US="$udid"
    sleep 5
  fi
  echo "$udid"
}

gate_ios-smoke() {
  local udid
  if ! udid="$(locate_or_boot_iphone_sim)"; then
    record ios-smoke FAIL "no iPhone simulator available (xcrun simctl list devices available)"
    return
  fi
  echo "using simulator $udid"

  local log_file pid_file run_pid bg_pid
  log_file="$(mktemp -t ios_smoke_run.XXXXXX.log)"
  pid_file="$(mktemp -t ios_smoke_run.XXXXXX.pid)"

  # flutter_pear_example's home screen (epic 4's Send/Receive redesign)
  # requires tapping into a demo route before Pear.start() ever runs -- a
  # plain launch never reaches the handshake. Reuses the same debug-only
  # auto-join dart-define flutter_pear_example's ios_hot_restart_gate.sh
  # already established (flutter_pear-ovt.3.2) to skip straight to
  # ChatScreen and auto-join on launch (flutter_pear-beq).
  (cd "$FLUTTER_PEAR_EXAMPLE" && flutter run -d "$udid" --pid-file "$pid_file" \
    --dart-define="FLUTTER_PEAR_GATE_AUTO_JOIN_TOPIC=flutter_pear-beq-ios-smoke-gate") >"$log_file" 2>&1 &
  bg_pid=$!

  for _ in $(seq 1 30); do
    [ -s "$pid_file" ] && break
    sleep 1
  done
  run_pid="$([ -s "$pid_file" ] && cat "$pid_file" || echo "$bg_pid")"

  local found=0 crashed=0
  for _ in $(seq 1 60); do
    if grep -qE "FLUTTER_PEAR_FIXTURE_ATTACHED|worklet attached|FRESH_MACHINE_WORKLET_ATTACHED" "$log_file" 2>/dev/null; then
      found=1
      break
    fi
    if grep -qE "FLUTTER_PEAR_FIXTURE_FAILED|MissingPluginException" "$log_file" 2>/dev/null; then
      crashed=1
      break
    fi
    sleep 2
  done

  if kill -0 "$run_pid" >/dev/null 2>&1; then
    kill "$run_pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
      kill -0 "$run_pid" >/dev/null 2>&1 || break
      sleep 1
    done
    kill -9 "$run_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$SIM_BOOTED_BY_US" ]; then
    xcrun simctl shutdown "$SIM_BOOTED_BY_US" >/dev/null 2>&1 || true
  fi

  if [ "$crashed" = "1" ]; then
    record ios-smoke FAIL "worklet reported a failure -- see $log_file"
  elif [ "$found" = "1" ]; then
    record ios-smoke PASS
  else
    record ios-smoke FAIL "no worklet-handshake marker appeared within the timeout -- the demo app's home screen requires tapping into 'Chat demo'/'File drop demo' before Pear.start() ever runs (flutter_pear_example has no auto-launch demo route yet; tracked under epic 4, not yet landed), so a plain launch alone cannot reach the handshake. Log: $log_file"
  fi
  rm -f "$pid_file"
}

gate_apk() {
  if (cd "$FLUTTER_PEAR_EXAMPLE" && flutter build apk --debug); then
    record apk PASS
  else
    record apk FAIL "flutter build apk --debug failed in packages/flutter_pear_example"
  fi
}

gate_ipa-inspect() {
  if ! (cd "$FLUTTER_PEAR_EXAMPLE" && flutter build ipa --no-codesign); then
    record ipa-inspect FAIL "flutter build ipa --no-codesign failed in packages/flutter_pear_example"
    return
  fi

  local archive
  archive="$(find "$FLUTTER_PEAR_EXAMPLE/build/ios/archive" -maxdepth 1 -iname "*.xcarchive" | head -1)"
  if [ -z "$archive" ]; then
    record ipa-inspect FAIL "flutter build ipa reported success but no .xcarchive was found"
    return
  fi
  local app
  app="$(find "$archive" -maxdepth 4 -iname "Runner.app" | head -1)"
  if [ -z "$app" ]; then
    record ipa-inspect FAIL "no Runner.app found inside $archive"
    return
  fi

  local causes=""
  local ok=1

  if [ ! -d "$app/Frameworks/BareKit.framework" ]; then
    ok=0
    causes="$causes BareKit.framework(not embedded)"
  fi

  local addons_dir="$FLUTTER_PEAR_BARE/ios/addons"
  if [ ! -d "$addons_dir" ]; then
    ok=0
    causes="$causes addons-dir($addons_dir does not exist -- epic 2 BareKit-repack not landed yet, cannot derive the expected addon framework list)"
  else
    while IFS= read -r -d '' xcfw; do
      local base
      base="$(basename "$xcfw" .xcframework)"
      # Embedded frameworks keep their FULL versioned name (e.g.
      # bare-fs.4.7.3.framework, matching the source xcframework's own
      # name exactly) -- an earlier version of this check stripped the
      # trailing version suffix before comparing, which meant it was
      # always looking for an unversioned bare-fs.framework that never
      # existed, a permanent false positive confirmed against a real
      # archive build (flutter_pear-ovt.6.7).
      if [ ! -d "$app/Frameworks/${base}.framework" ]; then
        ok=0
        causes="$causes ${base}.framework(not embedded)"
      fi
    done < <(find "$addons_dir" -maxdepth 1 -iname "*.xcframework" -print0)
  fi

  local plist="$app/Info.plist"
  if ! plutil -p "$plist" 2>/dev/null | grep -q "NSLocalNetworkUsageDescription"; then
    ok=0
    causes="$causes NSLocalNetworkUsageDescription(missing from $plist -- epic 4.1 Info.plist hydration not landed yet)"
  fi

  if [ "$ok" = "1" ]; then
    record ipa-inspect PASS
  else
    record ipa-inspect FAIL "${causes# }"
  fi
}

gate_macos-build() {
  if (cd "$FLUTTER_PEAR_EXAMPLE" && flutter build macos --debug); then
    record macos-build PASS
  else
    record macos-build FAIL "flutter build macos --debug failed in packages/flutter_pear_example"
  fi
}

gate_macos-smoke() {
  local log_file pid_file run_pid bg_pid
  log_file="$(mktemp -t macos_smoke_run.XXXXXX.log)"
  pid_file="$(mktemp -t macos_smoke_run.XXXXXX.pid)"

  # Same auto-join dart-define mechanism ios-smoke uses (flutter_pear-beq) --
  # flutter_pear_example's home screen requires tapping into a demo route
  # before Pear.start() ever runs. Unlike ios-smoke, no simulator to
  # locate/boot -- a macOS build runs directly on this machine.
  (cd "$FLUTTER_PEAR_EXAMPLE" && flutter run -d macos --pid-file "$pid_file" \
    --dart-define="FLUTTER_PEAR_GATE_AUTO_JOIN_TOPIC=flutter_pear-b6g-macos-smoke-gate") >"$log_file" 2>&1 &
  bg_pid=$!

  for _ in $(seq 1 30); do
    [ -s "$pid_file" ] && break
    sleep 1
  done
  run_pid="$([ -s "$pid_file" ] && cat "$pid_file" || echo "$bg_pid")"

  # Only the worklet-attach marker (matches ios-smoke's own scope: a boot
  # smoke test, not a full peer round trip -- see doc/macos.md's "What's not
  # yet covered" for why a real round trip isn't gated here yet).
  local found=0 crashed=0
  for _ in $(seq 1 60); do
    if grep -qE "worklet attached" "$log_file" 2>/dev/null; then
      found=1
      break
    fi
    if grep -qE "FLUTTER_PEAR_FIXTURE_FAILED|MissingPluginException" "$log_file" 2>/dev/null; then
      crashed=1
      break
    fi
    sleep 2
  done

  if kill -0 "$run_pid" >/dev/null 2>&1; then
    kill "$run_pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
      kill -0 "$run_pid" >/dev/null 2>&1 || break
      sleep 1
    done
    kill -9 "$run_pid" >/dev/null 2>&1 || true
  fi
  # A SIGKILL of `flutter run` never reaches the bare subprocess -- it
  # bypasses NSApplication's own normal-termination cleanup (see
  # doc/macos.md's "Orphaned subprocess on quit"), so clean it up
  # explicitly rather than leaking a process every gate run.
  pkill -9 -f "bare .*/pear-end.bundle" >/dev/null 2>&1 || true

  if [ "$crashed" = "1" ]; then
    record macos-smoke FAIL "worklet reported a failure -- see $log_file"
  elif [ "$found" = "1" ]; then
    record macos-smoke PASS
  else
    record macos-smoke FAIL "no worklet-handshake marker appeared within the timeout. Log: $log_file"
  fi
  rm -f "$pid_file"
}

gate_linux-build() {
  if (cd "$FLUTTER_PEAR_EXAMPLE" && flutter build linux --debug); then
    record linux-build PASS
  else
    record linux-build FAIL "flutter build linux --debug failed in packages/flutter_pear_example"
  fi
}

gate_linux-smoke() {
  local log_file pid_file run_pid bg_pid
  log_file="$(mktemp -t linux_smoke_run.XXXXXX.log)"
  pid_file="$(mktemp -t linux_smoke_run.XXXXXX.pid)"

  # Same auto-join dart-define mechanism macos-smoke/ios-smoke use
  # (flutter_pear-beq) -- flutter_pear_example's home screen requires
  # tapping into a demo route before Pear.start() ever runs. `xvfb-run -a`
  # if present (real-world Linux release/CI machines are commonly headless,
  # confirmed on this project's own Linux test box, flutter_pear-ymz) --
  # falls back to a direct run if a real display is already attached and
  # Xvfb isn't installed.
  local runner=(flutter run -d linux --pid-file "$pid_file" \
    --dart-define="FLUTTER_PEAR_GATE_AUTO_JOIN_TOPIC=flutter_pear-ymz-linux-smoke-gate")
  if command -v xvfb-run >/dev/null 2>&1; then
    runner=(xvfb-run -a "${runner[@]}")
  fi
  (cd "$FLUTTER_PEAR_EXAMPLE" && "${runner[@]}") >"$log_file" 2>&1 &
  bg_pid=$!

  for _ in $(seq 1 30); do
    [ -s "$pid_file" ] && break
    sleep 1
  done
  run_pid="$([ -s "$pid_file" ] && cat "$pid_file" || echo "$bg_pid")"

  # Only the worklet-attach marker (same scope as macos-smoke: a boot smoke
  # test, not a full peer round trip -- see doc/linux.md's "What's covered"
  # section for the separate, already-confirmed real join/connected result).
  local found=0 crashed=0
  for _ in $(seq 1 60); do
    if grep -qE "worklet attached" "$log_file" 2>/dev/null; then
      found=1
      break
    fi
    if grep -qE "FLUTTER_PEAR_FIXTURE_FAILED|MissingPluginException" "$log_file" 2>/dev/null; then
      crashed=1
      break
    fi
    sleep 2
  done

  if kill -0 "$run_pid" >/dev/null 2>&1; then
    kill "$run_pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
      kill -0 "$run_pid" >/dev/null 2>&1 || break
      sleep 1
    done
    kill -9 "$run_pid" >/dev/null 2>&1 || true
  fi
  # A plain kill/SIGKILL of `flutter run` does NOT reach the bare
  # subprocess -- it bypasses the app's own GApplication "shutdown" signal
  # (see doc/linux.md's "Orphaned subprocess on quit"), confirmed live on
  # this project's own Linux test box (flutter_pear-ymz): the same gap
  # macos-smoke already works around for macOS's NSApplication equivalent.
  pkill -9 -f "bare .*/pear-end.bundle" >/dev/null 2>&1 || true

  if [ "$crashed" = "1" ]; then
    record linux-smoke FAIL "worklet reported a failure -- see $log_file"
  elif [ "$found" = "1" ]; then
    record linux-smoke PASS
  else
    record linux-smoke FAIL "no worklet-handshake marker appeared within the timeout. Log: $log_file"
  fi
  rm -f "$pid_file"
}

gate_windows-build() {
  if (cd "$FLUTTER_PEAR_EXAMPLE" && flutter build windows --debug); then
    record windows-build PASS
  else
    record windows-build FAIL "flutter build windows --debug failed in packages/flutter_pear_example"
  fi
}

gate_windows-smoke() {
  local log_file pid_file run_pid bg_pid
  log_file="$(mktemp -t windows_smoke_run.XXXXXX.log)"
  pid_file="$(mktemp -t windows_smoke_run.XXXXXX.pid)"

  # Same auto-join dart-define mechanism macos-smoke/linux-smoke use
  # (flutter_pear-beq) -- flutter_pear_example's home screen requires
  # tapping into a demo route before Pear.start() ever runs. This gate
  # assumes a bash environment on Windows (Git Bash, matching this
  # project's own toolchain table) -- `flutter run -d windows` needs a
  # real, attached display the same way macOS/Linux do; there is no
  # Windows equivalent of xvfb-run for a fully headless run.
  (cd "$FLUTTER_PEAR_EXAMPLE" && flutter run -d windows --pid-file "$pid_file" \
    --dart-define="FLUTTER_PEAR_GATE_AUTO_JOIN_TOPIC=flutter_pear-m6s-windows-smoke-gate") \
    >"$log_file" 2>&1 &
  bg_pid=$!

  for _ in $(seq 1 30); do
    [ -s "$pid_file" ] && break
    sleep 1
  done
  run_pid="$([ -s "$pid_file" ] && cat "$pid_file" || echo "$bg_pid")"

  # Only the worklet-attach marker (same scope as macos-smoke/linux-smoke).
  local found=0 crashed=0
  for _ in $(seq 1 60); do
    if grep -qE "worklet attached" "$log_file" 2>/dev/null; then
      found=1
      break
    fi
    if grep -qE "FLUTTER_PEAR_FIXTURE_FAILED|MissingPluginException" "$log_file" 2>/dev/null; then
      crashed=1
      break
    fi
    sleep 2
  done

  # Unlike macos-smoke/linux-smoke, no separate orphan-cleanup step is
  # needed here: the Windows host's Job Object has
  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE set, so killing the top-level app
  # process tears down the whole `cmd.exe`/`bare`/`node.exe` chain
  # automatically -- confirmed live, not assumed (see doc/windows.md's
  # "Orphaned subprocess on quit" section, flutter_pear-pfp).
  if kill -0 "$run_pid" >/dev/null 2>&1; then
    kill "$run_pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do
      kill -0 "$run_pid" >/dev/null 2>&1 || break
      sleep 1
    done
    kill -9 "$run_pid" >/dev/null 2>&1 || true
  fi

  if [ "$crashed" = "1" ]; then
    record windows-smoke FAIL "worklet reported a failure -- see $log_file"
  elif [ "$found" = "1" ]; then
    record windows-smoke PASS
  else
    record windows-smoke FAIL "no worklet-handshake marker appeared within the timeout. Log: $log_file"
  fi
  rm -f "$pid_file"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

run_gate() {
  local gate="$1"
  echo
  echo "=============================================================="
  echo "GATE: $gate"
  echo "=============================================================="
  "gate_${gate}"
}

print_manual_checklist() {
  echo
  echo "=============================================================="
  echo "MANUAL checklist (this script cannot automate these):"
  echo "=============================================================="
  echo "  [ ] T3 demo recording verified (launch-video storyboard, both-direction cross-platform file drop)"
  echo "  [ ] Physical-Android side of T2 (simulator-iOS <-> physical-Android chat, both directions) -- known blocked today on the only reachable physical device (flutter_pear-ovt.1.8)"
}

print_summary() {
  echo
  echo "=============================================================="
  echo "SUMMARY"
  echo "=============================================================="
  local any_fail=0
  local failed_names=""
  local g r c
  for g in "${GATE_ORDER[@]}"; do
    r="$(result_for "$g")"
    [ -z "$r" ] && continue
    printf "%-16s %s\n" "$g" "$r"
    if [ "$r" = "FAIL" ]; then
      any_fail=1
      failed_names="$failed_names $g"
      c="$(cause_for "$g")"
      echo "                 cause: $c"
    fi
  done
  echo
  if [ "$any_fail" = "1" ]; then
    echo "RESULT: FAIL --${failed_names}"
  else
    echo "RESULT: ALL GATES PASSED"
  fi
  return "$any_fail"
}

if [ "${1:-}" = "--list" ]; then
  for g in "${GATE_ORDER[@]}"; do echo "$g"; done
  exit 0
fi

if [ "${1:-}" = "--only" ]; then
  gate="${2:-}"
  found=0
  for g in "${GATE_ORDER[@]}"; do [ "$g" = "$gate" ] && found=1; done
  if [ "$found" != "1" ]; then
    echo "unknown gate: $gate (see --list)" >&2
    exit 1
  fi
  run_gate "$gate"
  print_summary
  summary_exit=$?
  print_manual_checklist
  exit "$summary_exit"
fi

for g in "${GATE_ORDER[@]}"; do
  run_gate "$g"
done
print_summary
summary_exit=$?
print_manual_checklist
exit "$summary_exit"
