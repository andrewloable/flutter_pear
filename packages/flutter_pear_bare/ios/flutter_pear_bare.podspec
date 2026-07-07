#
# flutter_pear_bare's CocoaPods compat path (flutter_pear-ovt.3.6) -- the
# legacy route for SPM-disabled projects/older Flutter. The primary,
# recommended path is the Swift Package Manager manifest at
# flutter_pear_bare/Package.swift (flutter_pear-ovt.3.1/3.5), which this
# podspec deliberately reuses source from rather than duplicating.
#
# `pod lib lint` is not run automatically (this repo has no CI) -- run the
# DO-step-4 external-consumer proof by hand before every release instead
# (see flutter_pear-ovt.3.6's bd notes for the exact commands).
#
require 'json'
require 'shellwords'

pin_path = File.join(__dir__, '..', 'barekit-pin.json')
pin = JSON.parse(File.read(pin_path))
bare_kit_version = pin.fetch('bareKitVersion')
repacked_url = pin.fetch('repackedUrl')
repacked_sha256 = pin.fetch('repackedSha256')
# Shell-escaped for embedding directly (unquoted) into the script_phase body
# below wherever a value is assigned to its own shell variable --
# repackedUrl is NOT a trusted-safe string: repackBareKit's own
# PENDING-UPLOAD sentinel (barekit-pin.json, flutter_pear-ovt.2.3) contains
# literal backticks, which a naive `URL="#{repacked_url}"` double-quoted
# assignment would hand to bash as REAL command substitution -- caught by
# actually rendering and running this exact script during this task's own
# development, not guessed. repacked_sha256_sh is escaped the same way for
# consistency even though a sha256 hex string can't contain shell
# metacharacters today; bare_kit_version never needs it (only ever
# interpolated inside an already-safe echo message or path segment, never
# assigned as its own shell token) so no _sh variant is used for it.
repacked_url_sh = Shellwords.escape(repacked_url)
repacked_sha256_sh = Shellwords.escape(repacked_sha256)

# Version-scoped (like the Android Gradle fetch's own build/bare-kit/<version>/
# and the SPM path's url:/checksum: pin) so bumping bareKitVersion starts a
# fresh cache rather than silently reusing a stale binary. PODS_TARGET_SRCROOT
# is this pod's own source directory -- for a :path (development pod), which
# is how Flutter installs ALL plugins including this one, that's the real
# checked-out flutter_pear_bare/ios/ directory itself, not a copy.
cache_dir = "${PODS_TARGET_SRCROOT}/.barekit_cache/#{bare_kit_version}"

Pod::Spec.new do |s|
  s.name             = 'flutter_pear_bare'
  s.version          = '0.0.1'
  s.summary          = 'Low-level Bare Kit worklet bindings for flutter_pear.'
  s.description      = <<-DESC
Boots a Bare Kit worklet and pipes raw binary IPC to Dart. This podspec is
the CocoaPods-mode compat path -- see flutter_pear_bare/Package.swift for
the primary Swift Package Manager path.
                       DESC
  s.homepage         = 'https://github.com/andrewloable/flutter_pear'
  s.license          = { :type => 'MIT' }
  s.author           = { 'flutter_pear' => 'noreply@example.com' }
  s.source           = { :path => '.' }

  # The SAME Swift source the SPM package (flutter_pear_bare/Package.swift)
  # builds -- one source tree, two manifests, per Flutter's own documented
  # dual-build-system plugin convention. #if canImport(CBareKit) in
  # FlutterPearBarePlugin.swift skips the SPM-only shim-module import here;
  # SWIFT_OBJC_BRIDGING_HEADER below supplies the same BareWorklet/BareIPC
  # symbols this build system's own way instead.
  s.source_files     = 'flutter_pear_bare/Sources/flutter_pear_bare/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.9'

  # The 12 addon xcframeworks are committed (never fetched) -- present at
  # `pod install` time, so a plain vendored_frameworks entry is fine for
  # these. BareKit itself is NOT listed here (see below): it doesn't exist
  # until the script_phase fetches it, and CocoaPods' handling of a
  # vendored_frameworks entry that's absent at `pod install` time isn't
  # reliable enough to depend on -- FRAMEWORK_SEARCH_PATHS/OTHER_LDFLAGS
  # below wire it explicitly instead.
  s.vendored_frameworks = Dir.glob(File.join(__dir__, 'addons/*.xcframework'))

  s.pod_target_xcconfig = {
    'SWIFT_OBJC_BRIDGING_HEADER' => '$(PODS_TARGET_SRCROOT)/flutter_pear_bare/Sources/flutter_pear_bare/CocoaPods-Bridging-Header.h',
    'FRAMEWORK_SEARCH_PATHS' => "\"#{cache_dir}\" $(inherited)",
    'OTHER_LDFLAGS' => '-framework BareKit $(inherited)',
  }

  # NEVER prepare_command: CocoaPods never runs it for :path-installed pods
  # (CocoaPods#2187), and Flutter installs every plugin pod exactly that
  # way (development pods via .symlinks/plugins) -- a prepare_command here
  # would silently never run. execution_position :before_compile instead,
  # so BareKit.xcframework exists by the time the linker needs it.
  s.script_phase = {
    :name => 'Fetch BareKit (flutter_pear-ovt.3.6)',
    :execution_position => :before_compile,
    :script => <<-SCRIPT
set -e
CACHE_DIR="#{cache_dir}"
FRAMEWORK_DIR="$CACHE_DIR/BareKit.xcframework"

if [ -f "$FRAMEWORK_DIR/Info.plist" ]; then
  echo "flutter_pear_bare: BareKit v#{bare_kit_version} already present at $FRAMEWORK_DIR -- skipping fetch."
  exit 0
fi

URL=#{repacked_url_sh}
case "$URL" in
  PENDING-UPLOAD*)
    echo "error: flutter_pear_bare: barekit-pin.json's repackedUrl for v#{bare_kit_version} is still a PENDING-UPLOAD placeholder -- run \\`dart run flutter_pear:pack --repack-barekit\\` (uploading enabled) first. See packages/flutter_pear/doc/troubleshooting.md."
    exit 1
    ;;
esac

mkdir -p "$CACHE_DIR"
ZIP="$CACHE_DIR/BareKit.xcframework.zip"
PART="$ZIP.part"
rm -f "$PART"

echo "flutter_pear_bare: downloading BareKit v#{bare_kit_version}..."
ATTEMPT=1
DOWNLOAD_OK=0
while [ "$ATTEMPT" -le 2 ]; do
  if curl -fL --silent --show-error -o "$PART" "$URL"; then
    DOWNLOAD_OK=1
    break
  fi
  if [ "$ATTEMPT" -lt 2 ]; then
    echo "flutter_pear_bare: download attempt $ATTEMPT failed -- retrying once..."
  fi
  ATTEMPT=$((ATTEMPT + 1))
done
if [ "$DOWNLOAD_OK" -ne 1 ]; then
  rm -f "$PART"
  echo "error: flutter_pear_bare: failed to download BareKit v#{bare_kit_version} from $URL after 2 attempts."
  exit 1
fi

ACTUAL_SHA=$(shasum -a 256 "$PART" | awk '{print $1}')
EXPECTED_SHA=#{repacked_sha256_sh}
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
  rm -f "$PART"
  echo "error: flutter_pear_bare: checksum mismatch for BareKit v#{bare_kit_version} from $URL -- expected sha256:$EXPECTED_SHA, got sha256:$ACTUAL_SHA. Delete $CACHE_DIR and rebuild."
  exit 1
fi
mv "$PART" "$ZIP"

EXTRACT_TMP="$CACHE_DIR/.extract_tmp"
rm -rf "$EXTRACT_TMP"
mkdir -p "$EXTRACT_TMP"
unzip -q "$ZIP" -d "$EXTRACT_TMP"
rm -rf "$FRAMEWORK_DIR"
mv "$EXTRACT_TMP/BareKit.xcframework" "$FRAMEWORK_DIR"
rm -rf "$EXTRACT_TMP"
echo "flutter_pear_bare: BareKit v#{bare_kit_version} ready at $FRAMEWORK_DIR"
    SCRIPT
  }
end
