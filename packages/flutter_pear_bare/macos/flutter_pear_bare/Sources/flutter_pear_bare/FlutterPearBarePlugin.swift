import Cocoa
import FlutterMacOS
import Foundation

/// Subpath (within `flutter_pear`'s Flutter assets) of the bundled pear-end
/// -- macOS uses the DESKTOP bundle (flutter_pear-6yz, E-D3), not the
/// mobile assets/pear-end.bundle: unlike mobile's addons (linked ahead of
/// time into this same binary), a desktop bare subprocess loads addons from
/// real `file:` prebuilds at runtime, which only the desktop-specific
/// bundle (built via bin/pack.dart's buildDesktopBundle, `--offload-addons`
/// instead of `--linked`) ships alongside. `#if arch` is a compile-time
/// check -- a compiled macOS binary never switches architecture at runtime,
/// so this is exactly as reliable as the mobile hosts' own per-ABI/
/// per-slice compiled targets.
#if arch(arm64)
private let bundleAssetSubpath = "assets/desktop/darwin-arm64/pear-end.bundle"
#elseif arch(x86_64)
private let bundleAssetSubpath = "assets/desktop/darwin-x64/pear-end.bundle"
#else
#error("flutter_pear_bare (macOS): unsupported architecture -- only arm64 and x86_64 have a committed desktop bundle (flutter_pear-6yz)")
#endif
private let bundlePackage = "flutter_pear"

// Worklet lifecycle (mirrors WorkletState in bare_worklet.dart). This
// comment block is duplicated VERBATIM in FlutterPearBarePlugin.kt/.swift,
// the Linux host (linux/flutter_pear_bare_plugin.cc), and the Windows host
// (windows/flutter_pear_bare_plugin.cpp) (eng-4A) -- edit all together,
// never just one, or the hosts silently drift apart.
//
//   stopped --start() (fresh boot)--> running --suspend()--> suspended
//      ^                                 |  ^                    |
//      |                                 |  |--------resume()----|
//      |--------------terminate()--------|
//      |
//      |--onWorkletExit (crash backstop, from EITHER running or suspended)
//
// macOS-specific (flutter_pear-71g E-D2a, flutter_pear-iqp E-D4): unlike
// iOS/Android, which boot a native BareKit worklet in-process, this host
// spawns the real `bare` runtime as a SUBPROCESS (E-D1's proven embedding
// shape, flutter_pear-bxp) and relays raw binary IPC over its stdin/stdout
// -- no BareKit dependency, no xcframework linking. `suspend`/`resume` are
// deliberate no-ops here, not an unfinished MVP shortcut: desktop has no
// OS-imposed background execution limit the way iOS/Android do (see
// `Pear.platformInfo`'s `PearBackgroundExecution.unrestricted` for this
// platform), so there is nothing to pause -- a swarm surviving a window
// minimize is the expected behavior, not something requiring a native
// suspend call. Reattach-across-hot-restart IS implemented: the static
// `process`/`stdinHandle`/`stdoutPipe` survive a plugin reinit exactly like
// the iOS/Android hosts' own static state, and every `start()` call
// (fresh boot AND reattach) re-arms the worklet -> Dart relay via
// `relayFromWorklet()` so a hot restart's new plugin instance keeps
// receiving data instead of it being silently dropped by a stale
// `[weak self]` (the flutter_pear-iqp bug fix).
private enum FlutterPearBareError: Error, CustomStringConvertible {
  case bundleNotFound
  case processLaunchFailed(String)

  var description: String {
    switch self {
    case .bundleNotFound:
      return "flutter_pear_bare: could not resolve the bundled \(bundleAssetSubpath) asset"
    case .processLaunchFailed(let reason):
      return "flutter_pear_bare: failed to launch the bare subprocess: \(reason)"
    }
  }
}

/// Boots the real `bare` runtime as a subprocess from the bundled pear-end
/// and pipes its stdin/stdout bidirectionally to Dart over the
/// `flutter_pear_bare/ipc` channel -- the macOS twin of
/// `FlutterPearBarePlugin.swift` (iOS)/`.kt` (Android), matching their
/// Flutter-channel CONTRACT exactly (same method names, same IPC framing
/// left entirely to the caller -- this host is a dumb byte relay in both
/// directions, exactly like the mobile hosts' BareIPC relay) while using a
/// completely different embedding mechanism underneath (E-D1's proven
/// subprocess + stdio shape instead of a linked native BareKit).
public class FlutterPearBarePlugin: NSObject, FlutterPlugin {
  private var control: FlutterMethodChannel!
  private var ipc: FlutterBasicMessageChannel!
  private var attached = true

  private static var process: Process?
  private static var stdinHandle: FileHandle?
  private static var stdoutPipe: Pipe?
  private static var workletGeneration = 0
  private static var terminationObserverRegistered = false

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterPearBarePlugin()
    let messenger = registrar.messenger

    let control = FlutterMethodChannel(name: "flutter_pear_bare/control", binaryMessenger: messenger)
    instance.control = control
    registrar.addMethodCallDelegate(instance, channel: control)

    let ipc = FlutterBasicMessageChannel(
      name: "flutter_pear_bare/ipc",
      binaryMessenger: messenger,
      codec: FlutterStandardMessageCodec.sharedInstance()
    )
    instance.ipc = ipc
    ipc.setMessageHandler { message, reply in
      if let data = (message as? FlutterStandardTypedData)?.data {
        FlutterPearBarePlugin.stdinHandle?.write(data)
      }
      reply(nil)
    }

    registerTerminationObserverOnce()
  }

  /// Kills the worklet subprocess on a NORMAL app quit (Cmd-Q, Dock quit,
  /// `NSApplication.terminate(_:)`) -- flutter_pear-iqp (E-D4). Registered
  /// once for the whole process lifetime, not per plugin instance, same
  /// rationale as iOS's `registerBackgroundObserversOnce`. This closes the
  /// orphaned-subprocess gap observed during E-D2a/E-D3 testing (`pgrep -fl
  /// bare` showing leftover processes after the parent app was killed) only
  /// for THIS path -- an external SIGKILL of the Flutter app can never be
  /// intercepted by any in-process code, a fundamental OS limit, not a gap
  /// this fixes.
  private static func registerTerminationObserverOnce() {
    guard !terminationObserverRegistered else { return }
    terminationObserverRegistered = true
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { _ in
      guard let process = FlutterPearBarePlugin.process else { return }
      NSLog("FlutterPearBarePlugin (macOS): app terminating, killing worklet subprocess")
      process.terminationHandler = nil
      FlutterPearBarePlugin.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
      process.terminate()
      FlutterPearBarePlugin.process = nil
      FlutterPearBarePlugin.stdinHandle = nil
      FlutterPearBarePlugin.stdoutPipe = nil
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      do {
        let args = call.arguments as? [String: Any]
        let reattached = try startWorklet(bundlePath: args?["bundlePath"] as? String)
        result(["reattached": reattached, "generationId": FlutterPearBarePlugin.workletGeneration])
      } catch {
        result(FlutterError(code: "worklet_start_failed", message: "\(error)", details: nil))
      }
    case "suspend", "resume":
      // Deliberate no-op (flutter_pear-iqp, E-D4): desktop has no OS-imposed
      // background execution limit, so there is nothing to pause -- ack
      // rather than FlutterMethodNotImplemented so Dart's own no-op-safe
      // suspend()/resume() (bare_worklet.dart) doesn't throw calling these.
      result(nil)
    case "terminate":
      terminateWorklet()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Returns true if this call reattached to an already-running worklet,
  /// false if it booted a fresh one.
  private func startWorklet(bundlePath: String?) throws -> Bool {
    // Hot-restart safe: Dart state resets but the subprocess keeps running
    // -- just re-point the read loop at the (new) Dart-side ipc. Fixed
    // flutter_pear-iqp bug: this used to return `true` here WITHOUT
    // re-arming the readabilityHandler, so the OLD plugin instance's
    // `[weak self]` (now nil after the old instance was deallocated)
    // silently dropped all incoming worklet data after any reattach.
    if FlutterPearBarePlugin.process != nil {
      relayFromWorklet()
      return true
    }

    let resolvedBundlePath: String
    if let bundlePath = bundlePath {
      resolvedBundlePath = bundlePath
    } else {
      let assetKey = FlutterDartProject.lookupKey(forAsset: bundleAssetSubpath, fromPackage: bundlePackage)
      // macOS-specific (unlike iOS, confirmed by testing): lookupKeyForAsset
      // on macOS returns a path already relative to the OUTER .app bundle's
      // ROOT (e.g. "Contents/Frameworks/App.framework/Resources/
      // flutter_assets/..."), not a plain resource name to hand to
      // Bundle.path(forResource:ofType:) the way iOS's flatter bundle
      // layout allows -- that API searches relative to resourcePath
      // (Contents/Resources/), which double-nests and never resolves.
      // Appending the key directly to Bundle.main's own bundlePath is the
      // correct join; App.framework/Resources is a standard macOS
      // framework-versioning symlink to Versions/Current/Resources, so this
      // reaches the real file transparently.
      let path = Bundle.main.bundlePath + "/" + assetKey
      guard FileManager.default.fileExists(atPath: path) else {
        throw FlutterPearBareError.bundleNotFound
      }
      resolvedBundlePath = path
    }

    // Application Support -- the SAME storage-root decision as iOS (Eng2
    // decision 35: never Documents, an iCloud restore of Hypercore writer
    // keys onto a second device forks cores). macOS's FileManager API is
    // identical to iOS's here.
    let appSupportURL = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let storageBase = appSupportURL.appendingPathComponent("flutter_pear", isDirectory: true)
    try FileManager.default.createDirectory(at: storageBase, withIntermediateDirectories: true)

    // `Process` has no PATH search of its own (unlike Dart's Process.start
    // or a plain shell) -- /usr/bin/env is the standard indirection.
    // pear-end/index.js's desktop branch expects the storage dir at
    // Bare.argv[2] (flutter_pear-71g's own pear-end fix): `env bare
    // <bundlePath> <storageDir>` execs bare with argv = ["bare",
    // bundlePath, storageDir] (env passes the literal command name through
    // as argv[0], confirmed by this task's own E-D1-era probing), matching
    // that position exactly regardless of exactly what ends up in argv[0].
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["bare", resolvedBundlePath, storageBase.path]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    // Inherit stderr (not piped) -- pear-end's own uncaughtException/
    // unhandledRejection handler already reports crashes over the IPC data
    // channel itself; stderr is a debugging convenience, not a signal this
    // host parses.

    let activeGeneration = FlutterPearBarePlugin.workletGeneration + 1
    process.terminationHandler = { [weak self] proc in
      DispatchQueue.main.async {
        self?.reportUnexpectedExit(
          reason: "bare subprocess exited (status \(proc.terminationStatus))",
          generation: activeGeneration)
      }
    }

    do {
      try process.run()
    } catch {
      throw FlutterPearBareError.processLaunchFailed("\(error)")
    }

    FlutterPearBarePlugin.process = process
    FlutterPearBarePlugin.stdinHandle = stdinPipe.fileHandleForWriting
    FlutterPearBarePlugin.stdoutPipe = stdoutPipe
    FlutterPearBarePlugin.workletGeneration = activeGeneration

    relayFromWorklet()

    return false
  }

  /// Arms the worklet -> Dart read loop against the CURRENT plugin
  /// instance's `ipc`/`self` -- called on every `start()` call (both a
  /// fresh boot and a reattach), mirroring the iOS host's identically-named
  /// `relayFromWorklet()`. Reads off `FlutterPearBarePlugin.stdoutPipe`
  /// (static, survives a hot restart) rather than a locally-captured pipe,
  /// so a reattach can re-point the handler at a plugin instance that
  /// didn't exist when the pipe was created.
  private func relayFromWorklet() {
    guard let stdoutPipe = FlutterPearBarePlugin.stdoutPipe else { return }
    let readHandle = stdoutPipe.fileHandleForReading
    readHandle.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard let self = self else { return }
      if data.isEmpty {
        // EOF on stdout -- the subprocess closed its output, whether via a
        // clean exit or a crash. terminationHandler above reports the exit
        // itself; this just stops reading.
        handle.readabilityHandler = nil
        return
      }
      DispatchQueue.main.async {
        if self.attached {
          self.ipc.sendMessage(FlutterStandardTypedData(bytes: data))
        }
      }
    }
  }

  /// Tears down this generation's static state (so the next `startWorklet`
  /// boots fresh instead of "reattaching" to a subprocess that's actually
  /// gone) and notifies Dart via the control channel with `reason`. Mirrors
  /// FlutterPearBarePlugin.swift (iOS)'s identically-named method.
  private func reportUnexpectedExit(reason: String, generation: Int) {
    guard generation == FlutterPearBarePlugin.workletGeneration, FlutterPearBarePlugin.process != nil else {
      return // already torn down by terminateWorklet(), or a stale generation
    }
    NSLog("FlutterPearBarePlugin (macOS): worklet exited unexpectedly: \(reason)")
    FlutterPearBarePlugin.process = nil
    FlutterPearBarePlugin.stdinHandle = nil
    FlutterPearBarePlugin.stdoutPipe = nil
    guard attached else { return }
    control.invokeMethod("onWorkletExit", arguments: ["reason": reason, "generationId": generation])
  }

  private func terminateWorklet() {
    let processToTerminate = FlutterPearBarePlugin.process
    let pipeToClear = FlutterPearBarePlugin.stdoutPipe
    FlutterPearBarePlugin.process = nil
    FlutterPearBarePlugin.stdinHandle = nil
    FlutterPearBarePlugin.stdoutPipe = nil
    // Clear terminationHandler/readabilityHandler BEFORE terminate() so the
    // intentional stop below is never reported as an unexpected exit --
    // same ordering rationale as the iOS host's terminateWorklet().
    processToTerminate?.terminationHandler = nil
    pipeToClear?.fileHandleForReading.readabilityHandler = nil
    processToTerminate?.terminate()
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    attached = false
    control.setMethodCallHandler(nil)
    ipc.setMessageHandler(nil)
  }
}
