// Used ONLY by the CocoaPods compat podspec (flutter_pear-ovt.3.6), via
// its s.public_header_files + DEFINES_MODULE = YES -- CocoaPods auto-
// generates a Clang module for the flutter_pear_bare pod's OWN framework
// from its public headers, so this file's #import makes BareWorklet/
// BareIPC visible to FlutterPearBarePlugin.swift with NO import statement
// at all (same-module ObjC-to-Swift visibility, standard for a mixed
// ObjC+Swift CocoaPods framework pod). The SPM plugin package
// (flutter_pear-ovt.3.1/3.5) never references this file at all -- it uses
// the separate CBareKit shim module instead (SPM has no equivalent
// "framework's own public headers" mechanism to piggyback on). A bridging
// header and a hand-written module.modulemap were both tried first here
// and rejected (see git history / bd notes on flutter_pear-ovt.3.6):
// bridging headers are unsupported for CocoaPods' framework targets, and
// a custom module.modulemap alongside DEFINES_MODULE = YES caused a
// "Redefinition of module" conflict with CocoaPods' own auto-generated one.
#import <BareKit/BareKit.h>
