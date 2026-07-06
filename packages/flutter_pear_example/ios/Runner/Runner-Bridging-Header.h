#import "GeneratedPluginRegistrant.h"
// THROWAWAY T0 spike (flutter_pear-ovt.1.4): BareKit.xcframework ships no
// Modules/module.modulemap, so `import BareKit` fails as a Swift module --
// bridge it as a plain textual header include instead (SpikeBareHost.swift
// uses BareWorklet/BareIPC with no import statement, same as any other
// bridging-header-exposed ObjC type).
#import <BareKit/BareKit.h>
