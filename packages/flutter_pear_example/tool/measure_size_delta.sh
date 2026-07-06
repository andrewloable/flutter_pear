#!/usr/bin/env bash
# Eng-review 6A consumer-impact disclosure (flutter_pear-ovt.5.13): measures
# the example app's real APK/IPA size cost of the v0.2 iOS extension versus
# the v0.1 (git tag v0.0.1) Android-only baseline. THIS script only produces
# the numbers -- the docs epic writes the README/FAQ/CHANGELOG disclosure
# text and the D20 changelog size line from them.
#
# D20 (accept-and-disclose): pub downloads all of a package's dependencies
# regardless of the CONSUMING app's target platform (flutter/flutter#130210)
# -- so the committed iOS artifacts (BareKit + addon xcframeworks) grow even
# an Android-only consumer's download size. This script's APK delta is
# exactly that cost, measured for real rather than estimated.
#
# Builds the CURRENT (v0.2) example app in place, then checks out the v0.1
# baseline into a throwaway `git worktree` (never touches the main working
# tree) to build its own APK for comparison. The worktree is always removed,
# even on failure (trap).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
EXAMPLE_DIR="$REPO_ROOT/packages/flutter_pear_example"
BASELINE_TAG="v0.0.1"
WORKTREE_DIR="$(mktemp -d -t fp_size_baseline)"
FLUTTER_BIN="${FLUTTER_BIN:-flutter}"

cleanup() {
  if git -C "$REPO_ROOT" worktree list --porcelain | grep -qF "$WORKTREE_DIR"; then
    git -C "$REPO_ROOT" worktree remove --force "$WORKTREE_DIR" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORKTREE_DIR"
}
trap cleanup EXIT

human() {
  # Bytes -> a human-readable MB string with 2 decimals, no external deps.
  awk -v b="$1" 'BEGIN { printf "%.2f MB", b / 1048576 }'
}

echo "== flutter_pear-ovt.5.13: example-app size delta measurement =="
echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
"$FLUTTER_BIN" --version | head -1
echo

# --- v0.2 (current working tree) ---
echo "-- building CURRENT (v0.2) example app --"
(cd "$EXAMPLE_DIR" && "$FLUTTER_BIN" build apk --release)
APK_V02="$EXAMPLE_DIR/build/app/outputs/flutter-apk/app-release.apk"
APK_V02_BYTES=$(stat -f%z "$APK_V02" 2>/dev/null || stat -c%s "$APK_V02")

IOS_APP_V02_BYTES=""
IOS_NOTE=""
if (cd "$EXAMPLE_DIR" && "$FLUTTER_BIN" build ipa --no-codesign) 2>&1 | tee /tmp/fp_size_ios_build.log; then
  RUNNER_APP=$(find "$EXAMPLE_DIR/build/ios/archive" -maxdepth 5 -iname "Runner.app" 2>/dev/null | head -1)
  if [ -n "$RUNNER_APP" ]; then
    IOS_APP_V02_BYTES=$(du -sk "$RUNNER_APP" | awk '{print $1 * 1024}')
  else
    IOS_NOTE="flutter build ipa reported success but no Runner.app was found under build/ios/archive"
  fi
else
  IOS_NOTE="flutter build ipa --no-codesign failed -- see /tmp/fp_size_ios_build.log"
fi

# --- v0.1 baseline (git worktree at the release tag, main tree untouched) ---
echo
echo "-- building BASELINE ($BASELINE_TAG) example app in a throwaway worktree --"
git -C "$REPO_ROOT" worktree add --detach "$WORKTREE_DIR" "$BASELINE_TAG" >/dev/null

BASELINE_EXAMPLE_DIR="$WORKTREE_DIR/packages/flutter_pear_example"
if command -v melos >/dev/null 2>&1; then
  (cd "$WORKTREE_DIR" && melos bootstrap) >/dev/null
else
  (cd "$BASELINE_EXAMPLE_DIR" && "$FLUTTER_BIN" pub get) >/dev/null
fi
# v0.1 was Android-only -- no committed android/ or ios/ runner is assumed
# present without checking; hydrate whichever is actually missing.
if [ ! -d "$BASELINE_EXAMPLE_DIR/android" ]; then
  (cd "$BASELINE_EXAMPLE_DIR" && "$FLUTTER_BIN" create --platforms=android .)
fi
(cd "$BASELINE_EXAMPLE_DIR" && "$FLUTTER_BIN" build apk --release)
APK_V01="$BASELINE_EXAMPLE_DIR/build/app/outputs/flutter-apk/app-release.apk"
APK_V01_BYTES=$(stat -f%z "$APK_V01" 2>/dev/null || stat -c%s "$APK_V01")

APK_DELTA_BYTES=$((APK_V02_BYTES - APK_V01_BYTES))

echo
echo "== RESULTS (release build mode for every number below) =="
echo "flutter_pear v0.1 (tag $BASELINE_TAG) Android APK: $APK_V01_BYTES bytes ($(human "$APK_V01_BYTES"))"
echo "flutter_pear v0.2 (working tree)      Android APK: $APK_V02_BYTES bytes ($(human "$APK_V02_BYTES"))"
echo "APK delta (v0.2 minus v0.1):                       $APK_DELTA_BYTES bytes ($(human "$APK_DELTA_BYTES"))"
if [ -n "$IOS_APP_V02_BYTES" ]; then
  echo "flutter_pear v0.2 iOS Runner.app (absolute, NO v0.1 iOS baseline exists -- v0.1 was Android-only): $IOS_APP_V02_BYTES bytes ($(human "$IOS_APP_V02_BYTES"))"
else
  echo "flutter_pear v0.2 iOS Runner.app: UNAVAILABLE -- $IOS_NOTE"
fi
