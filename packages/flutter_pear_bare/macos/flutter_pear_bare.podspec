#
# flutter_pear_bare's macOS CocoaPods compat path (flutter_pear-71g, E-D2a) --
# mirrors ios/flutter_pear_bare.podspec's role (SPM at
# flutter_pear_bare/Package.swift is primary; this is the legacy route for
# SPM-disabled projects). Far simpler than the iOS podspec: the macOS host
# spawns the real `bare` runtime as a subprocess (E-D1's proven embedding
# shape, flutter_pear-bxp) instead of linking a native BareKit.xcframework,
# so there is no fetch/link script_phase to write here at all.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_pear_bare'
  s.version          = '0.0.1'
  s.summary          = 'Low-level Bare Kit worklet bindings for flutter_pear.'
  s.description      = <<-DESC
Boots the real `bare` runtime as a subprocess and pipes raw binary IPC to
Dart over stdin/stdout. This podspec is the CocoaPods-mode compat path for
macOS -- see flutter_pear_bare/Package.swift for the primary Swift Package
Manager path.
                       DESC
  s.homepage         = 'https://github.com/andrewloable/flutter_pear'
  s.license          = { :type => 'MIT' }
  s.author           = { 'flutter_pear' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_pear_bare/Sources/flutter_pear_bare/**/*.swift'
  # CocoaPods' own resource_bundles mechanism, mirroring Package.swift's
  # `resources: [.copy("Resources/desktop")]` (flutter_pear-9ng) -- the SAME
  # on-disk files, packaged the CocoaPods way for this compat path. Produces
  # a `flutter_pear_bare_desktop.bundle` inside the app; see
  # FlutterPearBarePlugin.swift's `#if SWIFT_PACKAGE` branch for how each
  # packaging system's result is located at runtime.
  s.resource_bundles = {
    'flutter_pear_bare_desktop' => [
      'flutter_pear_bare/Sources/flutter_pear_bare/Resources/desktop/**/*'
    ]
  }
  s.dependency 'FlutterMacOS'
  # 12.0, kept in sync with flutter_pear_bare/Package.swift's own
  # .macOS("12.0") pin. Raised from 10.15.4 in 0.4.2 (flutter_pear-na0):
  # Xcode 27 refuses to target macOS below 12.0 outright -- "the range of
  # supported deployment target versions is 12.0 to 27.0.x" -- so the old
  # floor was not merely unvalidated, it could not be built at all.
  s.platform         = :osx, '12.0'
  s.swift_version    = '5.9'
end
