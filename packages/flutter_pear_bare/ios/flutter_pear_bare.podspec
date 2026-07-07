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
# fresh cache rather than silently reusing a stale binary. Podspec-relative
# (not an absolute/PODS_TARGET_SRCROOT-based path): a plain vendored_frameworks
# entry (like the 12 committed addons already use) is the only wiring that
# reliably reaches Swift's explicit-module dependency scanner -- manually
# driving FRAMEWORK_SEARCH_PATHS/OTHER_LDFLAGS at an arbitrary cache location
# was tried first and rejected (the scanner resolved #import <BareKit/
# BareKit.h> against a different, precomputed search path that never
# included it, confirmed by testing). vendored_frameworks tolerates the
# path not existing yet at `pod install` time; the script_phase below
# populates it before the linker/compiler ever need it.
cache_relative_dir = "barekit_cache/#{bare_kit_version}"

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
  # s.source is required even though Flutter always resolves plugin pods
  # as CocoaPods "development pods" (a Podfile :path entry it generates
  # itself, symlinked via .symlinks/plugins/) -- removing it outright
  # (tried during this task's own development) fails validation with
  # "Missing required attribute `source`". { :path => '.' } is Flutter's
  # own official podspec template's exact convention (plugin_darwin_spm/
  # darwin.tmpl/projectName.podspec.tmpl) despite `pod install` printing a
  # benign "acceptable ones are: git, hg, http, svn" WARNING (not an
  # error) about it on every single Flutter plugin built this way.
  s.source           = { :path => '.' }

  # The SAME Swift source the SPM package (flutter_pear_bare/Package.swift)
  # builds -- one source tree, two manifests, per Flutter's own documented
  # dual-build-system plugin convention. FlutterPearBarePlugin.swift's
  # `#if canImport(CBareKit) import CBareKit #endif` is false here (no such
  # module exists on this path) -- BareWorklet/BareIPC instead become part
  # of THIS pod's own auto-generated module (public_header_files +
  # DEFINES_MODULE below), visible to this Swift file with no import at
  # all (same-module ObjC-to-Swift visibility, standard for a mixed
  # CocoaPods framework pod). A bridging header was tried first and
  # rejected outright by Xcode ("Using bridging headers with framework
  # targets is unsupported": CocoaPods builds every pod as a framework
  # target); a separate hand-written module.modulemap (mirroring the SPM
  # CBareKit shim exactly) was tried second and rejected too ("Redefinition
  # of module" against CocoaPods' own auto-generated one, once
  # DEFINES_MODULE = YES is also set, which this needs regardless).
  # public_header_files only DISTINGUISHES which of source_files' matches
  # are public -- it doesn't independently pull in files source_files
  # itself doesn't already match, so the include/*.h glob must ALSO be
  # part of source_files (a Swift-only glob here, tried first, is why
  # consumers -- e.g. GeneratedPluginRegistrant.m -- failed to find this
  # header via the compiled framework's own umbrella header even though
  # this pod's OWN Swift file could already see it via HEADER_SEARCH_PATHS
  # below; confirmed by testing).
  s.source_files     = [
    'flutter_pear_bare/Sources/flutter_pear_bare/*.swift',
    'flutter_pear_bare/Sources/flutter_pear_bare/include/*.h',
  ]
  s.public_header_files = 'flutter_pear_bare/Sources/flutter_pear_bare/include/*.h'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.9'

  # The 12 addon xcframeworks are committed (never fetched, always present
  # at `pod install` time); BareKit.xcframework is fetched by the
  # script_phase below, into cache_relative_dir, before this same list is
  # actually needed at compile/link time. Globbed via the absolute
  # __dir__ (reliable regardless of Dir.pwd when the podspec is evaluated)
  # but STORED as podspec-relative paths -- `pod install` rejects an
  # absolute vendored_frameworks entry outright ("File patterns must be
  # relative and cannot start with a slash"), caught by actually running
  # `pod install` during this task's own development, not guessed.
  s.vendored_frameworks = Dir.glob(File.join(__dir__, 'addons/*.xcframework'))
    .map { |p| "addons/#{File.basename(p)}" } +
    ["#{cache_relative_dir}/BareKit.xcframework"]

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # BareKit.xcframework has no module map of its own -- Clang's module
    # purity check otherwise rejects FlutterPearBareUmbrella.h's #import
    # of it from inside this pod's OWN modular framework ("Include of
    # non-modular header inside framework module"), the standard,
    # documented Xcode escape hatch for exactly this "wrap a modulemap-
    # less third-party framework" scenario.
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    # The xcconfig boolean above alone did not suffice (confirmed by
    # testing) -- Swift's own Clang importer needs the raw flag passed
    # through explicitly via -Xcc for its module-purity check specifically.
    'OTHER_SWIFT_FLAGS' => '-Xcc -Wno-non-modular-include-in-framework-module $(inherited)',
    # CocoaPods' own auto-generated umbrella header #imports
    # FlutterPearBareUmbrella.h by bare filename -- the nested
    # Sources/flutter_pear_bare/include/ path (needed so SPM's
    # publicHeadersPath-equivalent nesting matches) isn't on CocoaPods'
    # own default header search path, so it must be added explicitly.
    'HEADER_SEARCH_PATHS' => '$(PODS_TARGET_SRCROOT)/flutter_pear_bare/Sources/flutter_pear_bare/include $(inherited)',
    # Xcode 16+'s Swift explicit-module-build dependency scanner still
    # fails to find BareKit/BareKit.h even via a native vendored_frameworks
    # entry (confirmed by testing) -- falling back to the older, per-
    # target-build-settings-respecting implicit scanner fixes it.
    'SWIFT_ENABLE_EXPLICIT_MODULES' => 'NO',
    'CLANG_ENABLE_EXPLICIT_MODULES' => 'NO',
    # vendored_frameworks alone gets BareKit compiling (search paths for
    # the module scan above) but NOT linking -- confirmed by testing
    # ("Undefined symbol: _OBJC_CLASS_$_BareWorklet/_BareIPC"). CocoaPods
    # only auto-adds a vendored framework's link flags for frameworks it
    # can actually see when computing them at `pod install` time; BareKit
    # doesn't exist yet then (the script_phase fetches it later, before
    # compile), so the flag needs adding explicitly.
    'OTHER_LDFLAGS' => '-framework BareKit $(inherited)',
    # The 12 committed addon xcframeworks only ship an ios-arm64-simulator
    # slice (Apple Silicon only) -- unlike BareKit's own upstream release,
    # which ships a genuine dual-arch ios-arm64_x86_64-simulator slice.
    # `flutter build ios --simulator` requests a universal arm64+x86_64
    # simulator binary by default, so CocoaPods' auto-generated "[CP] Copy
    # XCFrameworks" phase can't find a matching addon slice for x86_64 and
    # silently skips it -- confirmed by testing ("Unable to find matching
    # slice ... for the current build architectures (arm64 x86_64)"),
    # which only then surfaces later as a "Framework ... not found" linker
    # error. Excluding x86_64 from simulator builds is the standard fix for
    # an arm64-only-simulator xcframework (Intel Mac simulators are not a
    # target here); it doesn't limit BareKit, which supports both anyway.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64',
  }
  # The consuming app's own target (Runner) ALSO needs
  # CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES: precompiled
  # Clang modules are cached keyed partly by the compiling context's own
  # build settings, and GeneratedPluginRegistrant.m (Runner, not this pod)
  # triggering the SAME module build without this override hit the
  # identical "Include of non-modular header" failure independently.
  #
  # Runner also needs the x86_64-simulator exclusion above (it's the target
  # that actually links the addon frameworks in), but NOT via EXCLUDED_ARCHS
  # -- confirmed by testing that Flutter's own auto-generated
  # ios/Flutter/Generated.xcconfig sets EXCLUDED_ARCHS[sdk=iphonesimulator*]
  # = i386 and is #include'd AFTER Pods-Runner.xcconfig in Debug.xcconfig,
  # so it silently clobbers whatever this podspec sets for that same key on
  # Runner (the pod's own target above isn't affected -- Generated.xcconfig
  # only applies to the app target). VALID_ARCHS isn't touched by
  # Generated.xcconfig, and Xcode intersects it with ARCHS, so restricting
  # it to arm64 for the simulator SDK achieves the same drop-x86_64 effect
  # without being overridable by a file this podspec can't edit.
  s.user_target_xcconfig = {
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES',
    'VALID_ARCHS[sdk=iphonesimulator*]' => 'arm64',
  }

  # NEVER the pre-install hook some CocoaPods pods use for this kind of
  # fetch: CocoaPods never runs it for :path-installed pods (CocoaPods#2187),
  # and Flutter installs every plugin pod exactly that way (development pods
  # via .symlinks/plugins) -- that hook here would silently never run.
  # execution_position :before_compile instead, so BareKit.xcframework
  # exists by the time the linker needs it.
  s.script_phase = {
    :name => 'Fetch BareKit (flutter_pear-ovt.3.6)',
    :execution_position => :before_compile,
    :script => <<-SCRIPT
set -e
CACHE_DIR="${PODS_TARGET_SRCROOT}/#{cache_relative_dir}"
FRAMEWORK_DIR="$CACHE_DIR/BareKit.xcframework"

if [ -f "$FRAMEWORK_DIR/Info.plist" ]; then
  echo "flutter_pear_bare: BareKit v#{bare_kit_version} already present at $FRAMEWORK_DIR -- skipping fetch."
else
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
fi

# flutter_pear-ovt.3.7: runs on EVERY build (fresh fetch or cache-hit alike)
# -- catches a corrupted/tampered cache or a missing/incomplete committed
# addon as ONE flutter_pear-branded message, before compile/link ever
# reach a raw linker error for whichever piece happens to be broken.
FLUTTER_PEAR_BAREKIT_CACHE_DIR="$CACHE_DIR" "${PODS_TARGET_SRCROOT}/tool/preflight.sh"
    SCRIPT
  }
end
