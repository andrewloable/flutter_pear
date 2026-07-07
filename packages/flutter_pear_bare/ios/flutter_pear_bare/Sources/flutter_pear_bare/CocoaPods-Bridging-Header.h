// Used ONLY by the CocoaPods compat podspec (flutter_pear-ovt.3.6), wired
// via its pod_target_xcconfig's SWIFT_OBJC_BRIDGING_HEADER -- the SPM
// plugin package (flutter_pear-ovt.3.1/3.5) never references this file at
// all (SPM targets can't use a bridging header; see FlutterPearBarePlugin
// .swift's own top-of-file comment). BareKit.xcframework ships no
// Modules/module.modulemap, so this is the CocoaPods-side equivalent of
// that package's CBareKit shim module.
#import <BareKit/BareKit.h>
