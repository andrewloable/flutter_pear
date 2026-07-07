#!/usr/bin/env bash
# iOS hot-restart reattach-or-kill gate (flutter_pear-ovt.3.2): the Dart side
# already implements reattach-or-kill (E6.3 + flutter_pear-3vh) and the Swift
# host (flutter_pear-ovt.3.1) mirrors the Kotlin generation machinery, but
# neither had any automated iOS coverage before this script. Drives a REAL
# `flutter run` against a REAL simulator, triggers a REAL hot restart via
# SIGUSR2 (the documented `flutter run --pid-file` signal contract), and
# greps the app's own `reattached=` print (added to lib/main.dart's _join(),
# gated behind --dart-define=FLUTTER_PEAR_GATE_AUTO_JOIN_TOPIC so this is the
# ONLY thing that ever triggers it -- a real run never sets that define).
#
# Never requires a reinstall: this is exactly what "hot restart reattaches"
# means -- the native worklet process survives, only the Dart VM restarts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXAMPLE_DIR="$REPO_ROOT/packages/flutter_pear_example"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"
GATE_TOPIC="flutter_pear-ovt.3.2-gate-topic"
SCRATCH="$(mktemp -d -t fp_ios_hot_restart_gate)"
LOG="$SCRATCH/flutter_run.log"
PID_FILE="$SCRATCH/flutter_run.pid"
WAIT_SECS="${WAIT_SECS:-120}"

cleanup() {
  if [ -f "$PID_FILE" ]; then
    kill "$(cat "$PID_FILE")" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "== flutter_pear-ovt.3.2: iOS hot-restart reattach-or-kill gate =="
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "scratch: $SCRATCH"

# --- pick a simulator: reuse one already booted, else boot the first available iPhone ---
SIMID="$(xcrun simctl list devices booted | grep -Eo '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1 || true)"
if [ -z "$SIMID" ]; then
  SIMID="$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -Eo '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}')"
  echo "booting simulator $SIMID (none was already booted)..."
  xcrun simctl boot "$SIMID"
fi
echo "using simulator: $SIMID"

# --- wait for a line matching $1 to appear in $LOG, polling every 2s ---
wait_for_log_line() {
  local pattern="$1"
  local deadline=$((SECONDS + WAIT_SECS))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if grep -qE "$pattern" "$LOG" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

echo
echo "-- launching flutter run (auto-join topic: $GATE_TOPIC) --"
(cd "$EXAMPLE_DIR" && "$FLUTTER_BIN" run -d "$SIMID" --pid-file "$PID_FILE" \
  --dart-define="FLUTTER_PEAR_GATE_AUTO_JOIN_TOPIC=$GATE_TOPIC" >"$LOG" 2>&1 &)

echo "waiting up to ${WAIT_SECS}s for the first reattached= line (fresh boot)..."
if ! wait_for_log_line 'flutter_pear example: reattached='; then
  echo "FAIL: no reattached= line appeared within ${WAIT_SECS}s -- full log:"
  cat "$LOG"
  exit 1
fi
FIRST_LINE="$(grep -E 'flutter_pear example: reattached=' "$LOG" | head -1)"
echo "first boot: $FIRST_LINE"
if [[ "$FIRST_LINE" != *"reattached=false"* ]]; then
  echo "FAIL: expected the FIRST boot to report reattached=false, got: $FIRST_LINE"
  exit 1
fi

if [ ! -f "$PID_FILE" ]; then
  echo "FAIL: $PID_FILE was never written by flutter run"
  cat "$LOG"
  exit 1
fi
FLUTTER_PID="$(cat "$PID_FILE")"
LINES_BEFORE_RESTART="$(wc -l <"$LOG")"

echo
echo "-- sending SIGUSR2 (hot restart) to pid $FLUTTER_PID --"
kill -SIGUSR2 "$FLUTTER_PID"

echo "waiting up to ${WAIT_SECS}s for a SECOND reattached= line (post-restart)..."
deadline=$((SECONDS + WAIT_SECS))
SECOND_LINE=""
while [ "$SECONDS" -lt "$deadline" ]; do
  SECOND_LINE="$(tail -n +"$((LINES_BEFORE_RESTART + 1))" "$LOG" | grep -E 'flutter_pear example: reattached=' | head -1 || true)"
  [ -n "$SECOND_LINE" ] && break
  sleep 2
done
if [ -z "$SECOND_LINE" ]; then
  echo "FAIL: no reattached= line appeared after the hot restart within ${WAIT_SECS}s -- full log:"
  cat "$LOG"
  exit 1
fi
echo "after hot restart: $SECOND_LINE"
if [[ "$SECOND_LINE" != *"reattached=true"* ]]; then
  echo "FAIL: expected reattached=true after a clean hot restart (no version mismatch is expected in this gate), got: $SECOND_LINE -- full log:"
  cat "$LOG"
  exit 1
fi

if grep -qE 'worklet_start_failed|BUNDLE_VERSION_MISMATCH' "$LOG"; then
  echo "FAIL: log contains a worklet_start_failed or BUNDLE_VERSION_MISMATCH failure:"
  grep -E 'worklet_start_failed|BUNDLE_VERSION_MISMATCH' "$LOG"
  exit 1
fi
echo "no worklet_start_failed / BUNDLE_VERSION_MISMATCH in the log -- good."

# --- background then relaunch the app, confirm the debug connection still responds ---
BUNDLE_ID="$(grep -m1 'PRODUCT_BUNDLE_IDENTIFIER = ' "$EXAMPLE_DIR/ios/Runner.xcodeproj/project.pbxproj" \
  | sed -E 's/.*PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);.*/\1/')"
echo
echo "-- backgrounding the app (bundle id: $BUNDLE_ID) --"
xcrun simctl openurl "$SIMID" https://example.com
sleep 5
echo "-- relaunching the app --"
xcrun simctl launch "$SIMID" "$BUNDLE_ID"
sleep 2

LINES_BEFORE_RELOAD="$(wc -l <"$LOG")"
echo "-- sending SIGUSR1 (hot reload) to confirm the app process still responds --"
kill -SIGUSR1 "$FLUTTER_PID"
deadline=$((SECONDS + WAIT_SECS))
RELOAD_EVIDENCE=""
while [ "$SECONDS" -lt "$deadline" ]; do
  RELOAD_EVIDENCE="$(tail -n +"$((LINES_BEFORE_RELOAD + 1))" "$LOG" | grep -iE 'reloaded|hot reload' || true)"
  [ -n "$RELOAD_EVIDENCE" ] && break
  sleep 2
done
if [ -z "$RELOAD_EVIDENCE" ]; then
  echo "FAIL: no hot-reload confirmation after the background/relaunch cycle within ${WAIT_SECS}s -- full log:"
  cat "$LOG"
  exit 1
fi
echo "app still responds after background/relaunch: $RELOAD_EVIDENCE"

echo
echo "-- quitting flutter run --"
kill "$FLUTTER_PID" >/dev/null 2>&1 || true

echo
echo "== PASS: hot restart reattached with no reinstall, no worklet_start_failed, =="
echo "== handshake passed before and after, app responded after background/relaunch =="
