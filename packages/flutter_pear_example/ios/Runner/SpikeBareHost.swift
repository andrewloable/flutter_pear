// BareKit.xcframework ships no module map, so BareWorklet/BareIPC come in via
// the bridging header (#import <BareKit/BareKit.h>) instead of `import BareKit`.
import Flutter
import Foundation

/// THROWAWAY T0/T1 spike host (flutter_pear-ovt.1.4, switched to the real
/// bundle by flutter_pear-ovt.1.7): boots a BareKit `Worklet` from the REAL
/// `flutter_pear` package's `assets/pear-end.bundle` (with every native addon
/// embedded alongside it -- see BareKitShim/Package.swift) and relays its IPC
/// bidirectionally over the SAME `flutter_pear_bare/control` +
/// `flutter_pear_bare/ipc` channels `bare_worklet.dart` already speaks to the
/// real Android host (`FlutterPearBarePlugin.kt`) -- proves the real pear-end
/// boots with all addons resolving and the version handshake passes (T1).
/// Not a formalized plugin: lives in the example app's Runner only, never
/// `packages/flutter_pear_bare/ios` (that formalization is a later epic).
final class SpikeBareHost: NSObject {
  private let control: FlutterMethodChannel
  private let ipc: FlutterBasicMessageChannel
  private var worklet: BareWorklet?
  private var workletIpc: BareIPC?

  init(messenger: FlutterBinaryMessenger) {
    control = FlutterMethodChannel(name: "flutter_pear_bare/control", binaryMessenger: messenger)
    // StandardMessageCodec, not the binary codec -- mirrors bare_worklet.dart's
    // own doc comment on why (flutter/flutter#19849-class engine bug on the
    // Android side; kept symmetric here rather than special-cased per platform).
    ipc = FlutterBasicMessageChannel(
      name: "flutter_pear_bare/ipc",
      binaryMessenger: messenger,
      codec: FlutterStandardMessageCodec.sharedInstance()
    )
    super.init()

    control.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    ipc.setMessageHandler { [weak self] message, reply in
      if let data = (message as? FlutterStandardTypedData)?.data {
        NSLog("SpikeBareHost: DEBUG dart->native write, \(data.count) bytes")
        let n = self?.workletIpc?.write(data) ?? -999
        NSLog("SpikeBareHost: DEBUG write() returned \(n)")
      } else {
        NSLog("SpikeBareHost: DEBUG dart->native message was not FlutterStandardTypedData: \(String(describing: message))")
      }
      reply(nil)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      startWorklet()
      // Spike has no reattach story (that's T2's hot-restart scope,
      // flutter_pear-ovt.1.10) -- always a fresh boot.
      result(["reattached": false, "generationId": 1])
    case "suspend", "resume":
      result(nil) // no-op for the spike (T2's lifecycle investigation covers this for real)
    case "terminate":
      workletIpc?.close()
      worklet?.terminate()
      workletIpc = nil
      worklet = nil
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startWorklet() {
    guard worklet == nil else {
      NSLog("SpikeBareHost: DEBUG startWorklet() called again, worklet already exists -- no-op")
      return
    }
    // The real flutter_pear package's committed, versioned bundle -- same
    // asset the Android host resolves via FlutterAssets.getAssetFilePathBySubpath
    // + package "flutter_pear" (see pack.dart's bundleAssetPath doc comment).
    let key = FlutterDartProject.lookupKey(forAsset: "assets/pear-end.bundle", fromPackage: "flutter_pear")
    guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
      fatalError("SpikeBareHost: pear-end.bundle asset not found at key \(key)")
    }
    NSLog("SpikeBareHost: DEBUG resolved bundle path: \(path)")
    guard let w = BareWorklet(configuration: nil) else {
      fatalError("SpikeBareHost: BareWorklet failed to initialize")
    }
    NSLog("SpikeBareHost: DEBUG BareWorklet initialized, calling start()")
    // index.js's Bare.argv[0] is this worklet's private storage directory
    // (BULK_STORAGE_DIR, PearStore's Corestore root, ...) -- index.js throws
    // synchronously at module-load time if it's missing (flutter_pear-pcg
    // guard), same as Android's Worklet.start() passes
    // applicationContext.filesDir.absolutePath as argv[0]. Library/ is the
    // iOS analogue of Android's private filesDir (not Documents, which is
    // user-visible/iTunes-file-sharing-exposed).
    let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].path
    w.start(path, arguments: [libraryDir])
    NSLog("SpikeBareHost: DEBUG BareWorklet.start() returned")
    worklet = w
    guard let wipc = BareIPC(worklet: w) else {
      fatalError("SpikeBareHost: BareIPC failed to initialize")
    }
    NSLog("SpikeBareHost: DEBUG BareIPC initialized, arming read loop")
    workletIpc = wipc
    armReadLoop(wipc)
  }

  /// Re-arms the worklet -> Dart read loop, mirroring
  /// `FlutterPearBarePlugin.kt`'s `relayFromWorklet` re-arm-per-chunk pattern.
  /// `BareIPC.read`'s completion can fire on a background thread, so every
  /// touch of the Flutter channel is marshaled onto the main thread (Eng2 #8).
  private func armReadLoop(_ activeIpc: BareIPC) {
    NSLog("SpikeBareHost: DEBUG armReadLoop calling read()")
    activeIpc.read { [weak self] data, error in
      NSLog("SpikeBareHost: DEBUG read() completion fired, data=\(data?.count ?? -1) bytes, error=\(String(describing: error))")
      guard let self = self, self.workletIpc === activeIpc else {
        NSLog("SpikeBareHost: DEBUG read() completion dropped -- stale/deallocated")
        return
      }
      if let error = error {
        NSLog("SpikeBareHost: read from worklet failed: \(error)")
        return
      }
      guard let data = data else {
        NSLog("SpikeBareHost: worklet IPC ended")
        return
      }
      DispatchQueue.main.async {
        self.ipc.sendMessage(FlutterStandardTypedData(bytes: data))
      }
      self.armReadLoop(activeIpc)
    }
  }
}
