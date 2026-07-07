// Two build systems share this file (Flutter's own convention): the SPM
// plugin package (flutter_pear-ovt.3.1/3.5) and the CocoaPods compat
// podspec (flutter_pear-ovt.3.6). SPM targets can't use a bridging header
// at all, so BareWorklet/BareIPC come in via the CBareKit shim module
// there; CocoaPods pods CAN use a bridging header (its
// SWIFT_OBJC_BRIDGING_HEADER build setting, wired in the podspec's
// pod_target_xcconfig), which exposes the exact same symbols with no
// import needed -- canImport(CBareKit) is false on that path, so this
// import is skipped rather than failing the CocoaPods build outright.
#if canImport(CBareKit)
import CBareKit
#endif
import Flutter
import Foundation
import UIKit

/// Subpath (within `flutter_pear`'s Flutter assets) of the bundled pear-end.
private let bundleAssetSubpath = "assets/pear-end.bundle"
private let bundlePackage = "flutter_pear"

// Worklet lifecycle (mirrors WorkletState in bare_worklet.dart). This
// comment block is duplicated VERBATIM in FlutterPearBarePlugin.kt and
// FlutterPearBarePlugin.swift (eng-4A) -- edit both together, never just
// one, or the two hosts silently drift apart.
//
//   stopped --start() (fresh boot)--> running --suspend()--> suspended
//      ^                                 |  ^                    |
//      |                                 |  |--------resume()----|
//      |--------------terminate()--------|
//      |
//      |--onWorkletExit (crash backstop, from EITHER running or suspended)
//
//   Reattach: start() on an already-running worklet (e.g. a Dart hot
//   restart) goes running -> running directly, same generation id, never
//   through stopped. A fresh start() (stopped -> running) always bumps the
//   generation id. onWorkletExit always reports the generation captured
//   when the exit was detected, so a stale straggler from an earlier
//   generation is never misattributed to the current one (flutter_pear-3vh).
//
// iOS-only addition (flutter_pear-ovt.3.4, D11): Dart's own linger Timer
// (lifecycle.dart) was found to freeze entirely while the app is
// backgrounded on the simulator, only firing once the app returns to the
// foreground -- too late to have suspended anything for real. The iOS host
// arms BareKit's own suspendWithLinger on didEnterBackgroundNotification,
// which BareKit tracks natively and can act on even if the Dart isolate
// never runs again before the process is reclaimed. The Android host has
// no equivalent observer: its Dart-side timer already suspends correctly,
// so it needs no functional change for D11, only this mirrored comment.

private enum FlutterPearBareError: Error, CustomStringConvertible {
  case bundleNotFound
  case workletInitFailed

  var description: String {
    switch self {
    case .bundleNotFound:
      return "flutter_pear_bare: could not resolve the bundled \(bundleAssetSubpath) asset"
    case .workletInitFailed:
      return "flutter_pear_bare: BareWorklet/BareIPC failed to initialize"
    }
  }
}

/// Boots a Bare Kit `BareWorklet` from the bundled pear-end and pipes its
/// `BareIPC` bidirectionally to Dart over the `flutter_pear_bare/ipc`
/// channel -- the Swift-side twin of `FlutterPearBarePlugin.kt`, mirrored
/// one-for-one (flutter_pear-ovt.3.1). See that file's doc comment for the
/// full rationale (hot-restart reattach, the crash backstop); this class
/// changes nothing about that contract, only the platform underneath it.
public class FlutterPearBarePlugin: NSObject, FlutterPlugin {
  private var control: FlutterMethodChannel!
  private var ipc: FlutterBasicMessageChannel!

  // False once this instance has detached (e.g. a hot restart moved on to a
  // new plugin instance/engine) -- a read-loop closure captured before
  // detach checks this so it stops forwarding to the now-dead `ipc` channel
  // instead of silently dropping worklet data into the void.
  private var attached = true

  // The worklet and its IPC pipe live in STATIC (type-level) state, not on
  // the plugin instance: a Flutter hot restart tears down and recreates the
  // Dart VM (and this plugin object) without killing the iOS process, so
  // `startWorklet` must detect and reattach to an already-running worklet
  // rather than boot a second one.
  private static var worklet: BareWorklet?
  private static var workletIpc: BareIPC?

  // Identifies the CURRENTLY RUNNING worklet process/IPC pair -- bumped
  // only on a fresh boot (startWorklet's worklet == nil branch), left
  // unchanged across a reattach. Echoed to Dart in "start"'s result and
  // stamped on every onWorkletExit call (flutter_pear-3vh) so
  // bare_worklet.dart can tell a genuine exit of ITS OWN generation apart
  // from a stale straggler about an earlier one.
  private static var workletGeneration = 0

  // The most recently start()-supplied linger window, in milliseconds
  // (flutter_pear-ovt.3.4, D11) -- read by the background-notification
  // observer below, which can fire with no Dart isolate running at all, so
  // it cannot ask Dart for this value at the moment it actually needs it.
  // Falls back to PearLifecycleDefaults.linger's own 20s (mirrored here as
  // a plain literal, not shared code, since flutter_pear_bare has no
  // dependency on flutter_pear) for a caller that starts the worklet
  // without going through Pear.start at all.
  private static var lingerMs: Int?
  private static let defaultLingerMs: Int32 = 20_000
  private static var backgroundObserversRegistered = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterPearBarePlugin()
    let messenger = registrar.messenger()

    let control = FlutterMethodChannel(name: "flutter_pear_bare/control", binaryMessenger: messenger)
    instance.control = control
    registrar.addMethodCallDelegate(instance, channel: control)
    registerBackgroundObserversOnce()

    // StandardMessageCodec, not the raw binary codec -- mirrors
    // bare_worklet.dart's own doc comment on why (flutter/flutter#19849
    // class engine bug on the Android side; kept symmetric here rather
    // than special-cased per platform).
    let ipc = FlutterBasicMessageChannel(
      name: "flutter_pear_bare/ipc",
      binaryMessenger: messenger,
      codec: FlutterStandardMessageCodec.sharedInstance()
    )
    instance.ipc = ipc
    ipc.setMessageHandler { message, reply in
      if let data = (message as? FlutterStandardTypedData)?.data {
        FlutterPearBarePlugin.workletIpc?.write(data) { error in
          if let error = error {
            NSLog("FlutterPearBarePlugin: write to worklet failed: \(error)")
          }
        }
      }
      reply(nil)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      do {
        let args = call.arguments as? [String: Any]
        let reattached = try startWorklet(lingerMs: args?["lingerMs"] as? Int)
        result(["reattached": reattached, "generationId": FlutterPearBarePlugin.workletGeneration])
      } catch {
        // A genuine native-side crash can't be caught here at all -- that's
        // a platform limit, not one this catch clause can widen further.
        result(FlutterError(code: "worklet_start_failed", message: "\(error)", details: nil))
      }
    case "suspend":
      withRunningWorklet(result) { $0.suspend() }
    case "resume":
      withRunningWorklet(result) { $0.resume() }
    case "terminate":
      terminateWorklet()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func withRunningWorklet(_ result: @escaping FlutterResult, _ action: (BareWorklet) -> Void) {
    guard let w = FlutterPearBarePlugin.worklet else {
      result(FlutterError(code: "worklet_not_started", message: "no worklet is running", details: nil))
      return
    }
    action(w)
    result(nil)
  }

  /// Returns true if this call reattached to an already-running worklet, false if it booted a fresh one.
  /// [lingerMs]: see the static `lingerMs` field's doc.
  private func startWorklet(lingerMs: Int?) throws -> Bool {
    if let lingerMs = lingerMs {
      FlutterPearBarePlugin.lingerMs = lingerMs
    }

    // argv[0] must be a writable per-app dir (pear-end/index.js refuses to
    // boot without it, same as Android's Worklet.start() passing
    // applicationContext.filesDir.absolutePath) -- Application Support is
    // the iOS analogue of Android's private filesDir, and it must be
    // Application Support, NEVER Documents (Eng2 decision 35): an iCloud
    // backup restore of Hypercore writer keys onto a second device FORKS
    // cores -- protocol corruption, not a UX nicety.
    let appSupportURL = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let storageBase = appSupportURL.appendingPathComponent("flutter_pear", isDirectory: true)
    // These two names MUST match pear-end/index.js's own Corestore/
    // BULK_STORAGE_DIR directory names exactly -- see
    // ios_storage_rules_test.dart (this file's counterpart to Android's
    // backup_rules_test.dart) for the "don't let this silently drift" rule.
    let corestoreDir = storageBase.appendingPathComponent("pear-corestore", isDirectory: true)
    let bulkDir = storageBase.appendingPathComponent("pear-bulk", isDirectory: true)

    // Hot-restart safe: Dart state resets but the native worklet keeps
    // running -- just re-point the read loop at the (new) Dart-side ipc.
    if FlutterPearBarePlugin.worklet != nil {
      // Idempotent re-assertion: a backup/restore can resurrect these
      // directories without the exclusion attribute even while this
      // process keeps running, so this is re-applied on every start, not
      // just the fresh-boot path below.
      try? excludeFromBackup(corestoreDir)
      try? excludeFromBackup(bulkDir)
      relayFromWorklet()
      return true
    }

    let assetKey = FlutterDartProject.lookupKey(forAsset: bundleAssetSubpath, fromPackage: bundlePackage)
    guard let bundlePath = Bundle.main.path(forResource: assetKey, ofType: nil) else {
      throw FlutterPearBareError.bundleNotFound
    }

    // Application Support is not auto-created on iOS, and index.js creates
    // pear-corestore/pear-bulk lazily via Corestore's own open -- but the
    // exclusion attribute needs the directories to already exist, so both
    // are created eagerly here, before the worklet boots.
    try FileManager.default.createDirectory(at: corestoreDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bulkDir, withIntermediateDirectories: true)
    try excludeFromBackup(corestoreDir)
    try excludeFromBackup(bulkDir)

    guard let w = BareWorklet(configuration: nil) else {
      throw FlutterPearBareError.workletInitFailed
    }
    w.start(bundlePath, arguments: [storageBase.path])
    guard let wipc = BareIPC(worklet: w) else {
      throw FlutterPearBareError.workletInitFailed
    }
    FlutterPearBarePlugin.worklet = w
    FlutterPearBarePlugin.workletIpc = wipc
    FlutterPearBarePlugin.workletGeneration += 1 // a fresh boot is always a NEW generation (flutter_pear-3vh)
    relayFromWorklet()
    return false
  }

  private func excludeFromBackup(_ url: URL) throws {
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
  }

  /// Arms the D11 native-suspend fix: registered once (guarded by
  /// `backgroundObserversRegistered`) for the whole process lifetime, not
  /// per plugin instance, since these read/write only STATIC state and
  /// must keep working even if a later hot restart creates a fresh
  /// instance -- a second registration on a fresh instance would otherwise
  /// double-fire both observers.
  private static func registerBackgroundObserversOnce() {
    guard !backgroundObserversRegistered else { return }
    backgroundObserversRegistered = true

    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { _ in
      guard let w = FlutterPearBarePlugin.worklet else { return }
      let linger = FlutterPearBarePlugin.lingerMs ?? Int(defaultLingerMs)
      NSLog("FlutterPearBarePlugin: entered background, arming suspendWithLinger(\(linger)ms)")
      // Short background task (DO step 1): just enough to make sure this
      // call is actually delivered before the app suspends -- BareKit's
      // own suspendWithLinger tracks the countdown natively from here,
      // independent of whether Dart's isolate ever runs again.
      let taskID = UIApplication.shared.beginBackgroundTask(withName: "flutter_pear_bare.suspend")
      w.suspend(withLinger: Int32(linger))
      if taskID != .invalid {
        UIApplication.shared.endBackgroundTask(taskID)
      }
    }
    NotificationCenter.default.addObserver(
      forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
    ) { _ in
      NSLog("FlutterPearBarePlugin: entering foreground, resuming worklet")
      FlutterPearBarePlugin.worklet?.resume()
    }
  }

  /// Re-arms the worklet -> Dart read loop. `BareIPC.read`'s completion can
  /// arrive off-main and can fire synchronously if data is already
  /// buffered, so every touch of the Flutter channel -- including the
  /// re-arm itself -- is marshaled onto the main thread via
  /// `DispatchQueue.main.async` (mirrors Kotlin's `Handler.post`): calling
  /// this function directly from inside that completion would recurse on
  /// the call stack once per chunk with no return in between, eventually
  /// blowing the stack under a continuous burst.
  private func relayFromWorklet() {
    guard let activeIpc = FlutterPearBarePlugin.workletIpc else { return }
    // Captured once per arm, alongside `activeIpc` -- lets Dart reject a
    // stale exit report about an earlier generation (flutter_pear-3vh).
    let activeGeneration = FlutterPearBarePlugin.workletGeneration
    activeIpc.read { [weak self] data, error in
      // Stale-callback guard: this closure was armed against `activeIpc`.
      // If a restart replaced it with a fresh IPC, or terminate() nulled
      // it out, don't re-arm and don't forward data for a generation
      // nobody is listening to anymore.
      guard FlutterPearBarePlugin.workletIpc === activeIpc else { return }
      guard let self = self else { return }
      if let error = error {
        NSLog("FlutterPearBarePlugin: read from worklet failed: \(error)")
        self.reportUnexpectedExit(reason: "ipc read error: \(error)", generation: activeGeneration)
        return
      }
      guard let data = data else {
        // The E2.6 backstop: the worklet's IPC ended without us calling
        // terminate() ourselves. Most crashes are already reported in
        // detail by pear-end's own uncaughtException/unhandledRejection
        // handler over the IPC data channel itself before it exits --
        // this fires for whatever's left: a crash too early for that JS
        // handler to have registered, or a native-level abort bypassing
        // JS entirely.
        self.reportUnexpectedExit(reason: "worklet IPC ended unexpectedly", generation: activeGeneration)
        return
      }
      let bytes = FlutterStandardTypedData(bytes: data)
      DispatchQueue.main.async {
        if self.attached {
          self.ipc.sendMessage(bytes)
        }
        self.relayFromWorklet()
      }
    }
  }

  /// Tears down this generation's static state (so the next `startWorklet`
  /// boots fresh instead of "reattaching" to a worklet that's actually
  /// gone) and notifies Dart via the control channel with `reason`.
  /// `generation` is `relayFromWorklet`'s own captured `activeGeneration`,
  /// NOT the (possibly already-bumped) current `workletGeneration` -- see
  /// `FlutterPearBarePlugin.kt`'s `reportUnexpectedExit` doc for why.
  private func reportUnexpectedExit(reason: String, generation: Int) {
    NSLog("FlutterPearBarePlugin: worklet exited unexpectedly: \(reason)")
    FlutterPearBarePlugin.workletIpc = nil
    FlutterPearBarePlugin.worklet = nil
    guard attached else { return }
    DispatchQueue.main.async {
      self.control.invokeMethod("onWorkletExit", arguments: ["reason": reason, "generationId": generation])
    }
  }

  private func terminateWorklet() {
    // Capture + null the static fields BEFORE calling native close()/
    // terminate(): if IPC.close() synchronously fires relayFromWorklet's
    // pending read completion with data == nil, its stale-callback guard
    // must already see workletIpc as nil/different so it skips
    // reportUnexpectedExit -- this is an intentional stop, not a crash to
    // report. IPC must be torn down before/at Worklet.terminate() -- using
    // an IPC built on an already-terminated Worklet touches freed native
    // memory.
    let ipcToClose = FlutterPearBarePlugin.workletIpc
    let workletToTerminate = FlutterPearBarePlugin.worklet
    FlutterPearBarePlugin.workletIpc = nil
    FlutterPearBarePlugin.worklet = nil
    ipcToClose?.close()
    workletToTerminate?.terminate()
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    attached = false
    control.setMethodCallHandler(nil)
    ipc.setMessageHandler(nil)
  }
}
