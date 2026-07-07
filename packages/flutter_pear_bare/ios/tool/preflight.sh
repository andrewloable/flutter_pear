#!/usr/bin/env bash
# flutter_pear_bare/ios preflight (flutter_pear-ovt.3.7) -- run from the
# CocoaPods compat podspec's script_phase AFTER the BareKit fetch step,
# BEFORE compile/link ever touch the addon/BareKit xcframeworks. Catches a
# broken chain (a missing/incomplete committed addon, or a BareKit cache
# that's been corrupted/tampered with since its original fetch) as ONE
# flutter_pear-branded, actionable message -- naming what's wrong and the
# exact fix -- instead of a raw Xcode linker error for whichever piece
# happened to be missing (D18, house style per
# FlutterPearBarePlugin.kt's ABI-mismatch message).
#
# Can also be run standalone/manually: only FLUTTER_PEAR_BAREKIT_CACHE_DIR
# needs setting (the version-scoped directory a fetch would populate);
# addons/ and barekit-pin.json are found relative to this script's own
# committed location, which never varies.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BARE_ROOT="$(cd "$IOS_ROOT/.." && pwd)"
ADDONS_DIR="$IOS_ROOT/addons"
PIN_PATH="$BARE_ROOT/barekit-pin.json"
TROUBLESHOOTING="packages/flutter_pear/doc/troubleshooting.md"

if [ -z "${FLUTTER_PEAR_BAREKIT_CACHE_DIR:-}" ]; then
  echo "error: flutter_pear preflight: FLUTTER_PEAR_BAREKIT_CACHE_DIR must be set to the BareKit fetch cache directory (the podspec's own script_phase always sets this)."
  exit 1
fi
CACHE_DIR="$FLUTTER_PEAR_BAREKIT_CACHE_DIR"

if [ ! -f "$PIN_PATH" ]; then
  echo "error: flutter_pear preflight: barekit-pin.json not found at $PIN_PATH -- this checkout is missing a pack-epic artifact (a shallow/partial checkout is the usual cause). See $TROUBLESHOOTING."
  exit 1
fi

BARE_KIT_VERSION=$(python3 -c "import json; print(json.load(open('$PIN_PATH'))['bareKitVersion'])" 2>/dev/null)
EXPECTED_SHA=$(python3 -c "import json; print(json.load(open('$PIN_PATH'))['repackedSha256'])" 2>/dev/null)
PINNED_URL=$(python3 -c "import json; print(json.load(open('$PIN_PATH'))['repackedUrl'])" 2>/dev/null)
if [ -z "$BARE_KIT_VERSION" ] || [ -z "$EXPECTED_SHA" ] || [ -z "$PINNED_URL" ]; then
  echo "error: flutter_pear preflight: could not read bareKitVersion/repackedSha256/repackedUrl from $PIN_PATH -- it may be malformed. See $TROUBLESHOOTING."
  exit 1
fi

errors=()

# The committed addon set (flutter_pear-ovt.3.1/3.5) -- kept in sync with
# Package.swift's own AddonXxx binaryTarget list by hand; a version bump
# changes both together, same as every other pin in this repo. Checking
# against this fixed list (not just "whatever's in addons/") is what
# catches an addon renamed/deleted out from under the directory entirely --
# a bare glob over addons/*.xcframework would just silently see fewer
# entries and report them all fine, missing exactly that failure mode
# (confirmed by testing: renaming one away made a plain glob-based version
# of this check report "11 addon xcframeworks OK" instead of failing).
EXPECTED_ADDONS=(
  bare-fs.4.7.3
  bare-inspect.3.1.4
  bare-os.3.9.3
  bare-type.1.1.0
  bare-url.2.4.5
  fs-native-extensions.1.5.0
  quickbit-native.2.4.8
  rabin-native.2.0.0
  rocksdb-native.3.17.1
  simdle-native.1.3.9
  sodium-native.5.1.0
  udx-native.1.20.7
)

# --- (a) every expected addon xcframework is present with its required simulator slice ---
if [ ! -d "$ADDONS_DIR" ]; then
  errors+=("no addons/ directory found at $ADDONS_DIR -- run \`dart run flutter_pear:pack\` to regenerate the committed addon xcframeworks, or check out a complete copy of this repo (a shallow/partial checkout is the other common cause). See $TROUBLESHOOTING#ios-addon-missing.")
else
  for name in "${EXPECTED_ADDONS[@]}"; do
    xcfw="$ADDONS_DIR/$name.xcframework"
    if [ ! -d "$xcfw" ]; then
      errors+=("$name.xcframework is missing from $ADDONS_DIR -- run \`dart run flutter_pear:pack\` to regenerate the committed addon xcframeworks, or check out a complete copy of this repo. See $TROUBLESHOOTING#ios-addon-missing.")
      continue
    fi
    sim_slice="$xcfw/ios-arm64-simulator"
    if [ ! -d "$sim_slice" ]; then
      errors+=("$name.xcframework is missing its ios-arm64-simulator slice. flutter_pear_bare ships arm64-only simulator slices by design (D21) -- an Intel-Mac x86_64 simulator isn't a supported target, so this isn't that. If you're on an Apple Silicon Mac and still see this, $name.xcframework itself is corrupt or incomplete: run \`dart run flutter_pear:pack\` to regenerate it. See $TROUBLESHOOTING#ios-sim-slice-missing.")
    fi
  done
fi

# --- (b) the fetched BareKit framework is present and its cached zip still matches the pin ---
ZIP="$CACHE_DIR/BareKit.xcframework.zip"
FRAMEWORK_INFO="$CACHE_DIR/BareKit.xcframework/Info.plist"
if [ ! -f "$ZIP" ]; then
  errors+=("BareKit v$BARE_KIT_VERSION has not been fetched yet (expected $ZIP, from $PINNED_URL). This step normally runs after the podspec's own fetch script_phase -- re-run the build so that step can complete; if it keeps failing, download $PINNED_URL yourself and place it at exactly that path. See $TROUBLESHOOTING#ios-barekit-not-fetched.")
elif [ ! -f "$FRAMEWORK_INFO" ]; then
  errors+=("BareKit v$BARE_KIT_VERSION's zip is present at $ZIP but was never extracted to $CACHE_DIR/BareKit.xcframework. Delete $CACHE_DIR and rebuild to force a clean re-fetch+extract. See $TROUBLESHOOTING#ios-barekit-not-fetched.")
else
  ACTUAL_SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
  if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    errors+=("BareKit v$BARE_KIT_VERSION's cached zip at $ZIP no longer matches barekit-pin.json's pinned checksum (expected sha256:$EXPECTED_SHA, got sha256:$ACTUAL_SHA) -- it was corrupted or tampered with after the original fetch. Delete $CACHE_DIR and rebuild to force a clean re-fetch. See $TROUBLESHOOTING#ios-barekit-cache-corrupt.")
  fi
fi

if [ "${#errors[@]}" -gt 0 ]; then
  echo "error: flutter_pear preflight found ${#errors[@]} problem(s) before compile/link:"
  for e in "${errors[@]}"; do
    echo "  - $e"
  done
  exit 1
fi

echo "flutter_pear preflight: BareKit v$BARE_KIT_VERSION and all ${#EXPECTED_ADDONS[@]} addon xcframeworks OK."
exit 0
