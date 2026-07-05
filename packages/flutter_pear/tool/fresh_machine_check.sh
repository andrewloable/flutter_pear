#!/usr/bin/env bash
# E9.3 (flutter_pear-df9.3) manual TTHW runbook -- this repo has no CI (see
# COMPATIBILITY.md), so the champion-tier "create -> add flutter_pear ->
# build -> install+launch -> worklet attached" commitment (locked decision
# D12/X9 in project_plan.md) is proven by running this script by hand, not
# by a GitHub Actions job. Ported from the deleted .github/workflows/
# fresh-machine.yml -- same probe app, same readiness marker, same budget
# reasoning -- just targeting an already-attached device/emulator instead of
# booting one itself, matching the ORIGINAL human TTHW definition ("measured
# on a developer's machine that already has Flutter, Android tooling, and an
# emulator/device ready").
#
# Run before every release, from this directory (packages/flutter_pear):
#   ./tool/fresh_machine_check.sh
#
# Prereqs: a device/emulator already visible to `adb devices`; PATH has
# flutter+adb.
set -euo pipefail

BUDGET_SECONDS="${FRESH_MACHINE_BUDGET_SECONDS:-300}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

if ! adb get-state >/dev/null 2>&1; then
  echo "::error:: no device/emulator attached (adb get-state failed) -- boot one first, matching the human TTHW precondition of an already-running emulator." >&2
  exit 1
fi

echo "== Create app + add flutter_pear =="
cd "$WORKDIR"
flutter create fresh_machine_probe >/dev/null
cd fresh_machine_probe

# Timer starts here, AFTER app creation but BEFORE adding the dependency --
# matches fresh-machine.yml's own timer placement (post-emulator-boot,
# pre-build) and the human TTHW definition (device already ready).
START=$(date +%s)

flutter pub add flutter_pear --path "${REPO_ROOT}/packages/flutter_pear" >/dev/null

cat > lib/main.dart <<'DARTEOF'
import 'package:flutter/material.dart';
import 'package:flutter_pear/flutter_pear.dart';

void main() {
  runApp(const FreshMachineProbeApp());
}

class FreshMachineProbeApp extends StatefulWidget {
  const FreshMachineProbeApp({super.key});

  @override
  State<FreshMachineProbeApp> createState() => _FreshMachineProbeAppState();
}

class _FreshMachineProbeAppState extends State<FreshMachineProbeApp> {
  String _status = 'starting...';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final pear = await Pear.start();
      // fresh_machine_check.sh polls logcat for this exact string as the
      // "worklet attached" readiness signal -- keep both sides in sync if
      // either changes.
      // ignore: avoid_print
      print('FRESH_MACHINE_WORKLET_ATTACHED');
      setState(() => _status = 'worklet attached');
      await pear.dispose();
    } catch (e) {
      // ignore: avoid_print
      print('FRESH_MACHINE_WORKLET_FAILED: $e');
      setState(() => _status = 'failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(body: Center(child: Text(_status))),
      );
}
DARTEOF

echo "== Build (debug apk, arm64) =="
flutter build apk --debug --target-platform android-arm64 >/dev/null

echo "== Install + launch =="
adb install -r build/app/outputs/flutter-apk/app-debug.apk >/dev/null
adb logcat -c
adb shell am start -n com.example.fresh_machine_probe/.MainActivity >/dev/null

echo "== Poll for worklet-attach readiness =="
FOUND=0
CRASHED=0
for _ in $(seq 1 90); do
  if adb logcat -d | grep -q "FRESH_MACHINE_WORKLET_ATTACHED"; then
    FOUND=1
    break
  fi
  if adb logcat -d | grep -q "FRESH_MACHINE_WORKLET_FAILED"; then
    CRASHED=1
    echo "::error:: worklet reported a failure -- see logcat below" >&2
    adb logcat -d | grep "FRESH_MACHINE_WORKLET_FAILED" >&2
    break
  fi
  sleep 2
done

END=$(date +%s)
ELAPSED=$((END - START))

if [ "$CRASHED" = "1" ]; then
  echo "TTHW: worklet threw during Pear.start() -- a real regression, not a timing issue (elapsed ${ELAPSED}s)"
  exit 1
fi
if [ "$FOUND" != "1" ]; then
  echo "TTHW: worklet never attached within the polling window (elapsed ${ELAPSED}s)"
  exit 1
fi
echo "TTHW: worklet attached in ${ELAPSED}s (budget ${BUDGET_SECONDS}s)"
if [ "$ELAPSED" -gt "$BUDGET_SECONDS" ]; then
  echo "TTHW budget exceeded: ${ELAPSED}s > ${BUDGET_SECONDS}s"
  exit 1
fi
echo "TTHW OK"
