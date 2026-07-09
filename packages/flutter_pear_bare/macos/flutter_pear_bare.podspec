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
  s.dependency 'FlutterMacOS'
  s.platform         = :osx, '10.15'
  s.swift_version    = '5.9'
end
