import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_pear_bare/flutter_pear_bare.dart';

import 'base.dart';
import 'bee.dart';
import 'bundle_version.dart';
import 'crypto.dart';
import 'drive.dart';
import 'exceptions.dart';
import 'lifecycle.dart';
import 'pairing.dart';
import 'platform_info.dart';
import 'rpc.dart';
import 'schema.dart';
import 'store.dart';
import 'swarm.dart';

/// Entry point to the Pear P2P stack.
///
/// ```dart
/// final pear = await Pear.start();
/// final swarm = await pear.join(PearCrypto.unsafeTopicFromString('my-room'));
/// swarm.connections.listen((conn) => conn.write(utf8.encode('hi')));
/// // ...
/// await pear.dispose();
/// ```
class Pear {
  Pear._(this.worklet, this._rpc, Duration linger) {
    lifecycle = PearLifecycle(
      // Auto-triggered, not caller-awaited -- _guardedAutoCall reports
      // instead of silently swallowing a failure (see its own doc).
      onSuspend: () => unawaited(_guardedAutoCall(suspend)),
      onResume: () => unawaited(_guardedAutoCall(resume)),
      linger: linger,
    );
    if (platformInfo.backgroundExecution == PearBackgroundExecution.unrestricted) {
      // flutter_pear-iqp (E-D4): on a platform with no OS-imposed
      // background execution limit (desktop), auto-suspending on
      // AppLifecycleState.hidden/paused would be actively WRONG, not just
      // unnecessary -- a minimized window or an alt-tab away is a routine,
      // frequent event that never threatens the connection the way
      // mobile backgrounding does, so treating it as a suspend trigger
      // would flip PearSwarm.state to `suspended` (and, on the default
      // 20s linger, actually call the native no-op suspend) for a swarm
      // that is, in reality, still fully connected -- directly
      // contradicting this platform's own `unrestricted` pin above.
      // `lifecycle.policy` stays public and mutable either way, so a
      // desktop app that specifically wants mobile-style
      // suspend-on-hide can still opt back in.
      lifecycle.policy = PearLifecyclePolicy.manual;
    }
  }

  /// The underlying Bare worklet. Use directly only for the low-level echo/IPC
  /// path or a custom bundle; the high-level API covers normal use.
  final BareWorklet worklet;

  final PearRpc _rpc;

  /// Wires `AppLifecycleState` to [suspend]/[resume] with a linger window
  /// (E6.2, "lifecycle by default") — set `lifecycle.policy` to
  /// [PearLifecyclePolicy.manual] to opt out of automatic suspend/resume;
  /// [suspend]/[resume] stay public and callable directly either way.
  late final PearLifecycle lifecycle;

  // Serializes suspend()/resume() calls on THIS Pear (never rejects, so a
  // failed call doesn't wedge the ones queued behind it) -- without this,
  // two overlapping unawaited calls (e.g. a manual pear.suspend() racing
  // PearLifecycle's own auto-suspend) could both read worklet.state before
  // either's `await worklet.suspend()`/`resume()` actually flips it,
  // both see the same stale wasRunning/wasSuspended snapshot, and both
  // notify every joined PearSwarm -- a duplicate, spurious state
  // transition on PearSwarm.state that the wasRunning/wasSuspended check
  // was specifically added to prevent. [dispose] also awaits this queue,
  // so it never tears down [_rpc] out from under an in-flight suspend/
  // resume's later notifyWorkletSuspended call.
  Future<void> _lifecycleQueue = Future<void>.value();

  /// This platform's pinned [PearBackgroundExecution] and
  /// [PearValidationTier] (DX2-55, D17) — a release-time constant, not a
  /// worklet round trip, so this is safe to read before [start] and needs
  /// no worklet at all: a dedicated Dart-only call (`defaultTargetPlatform`)
  /// was chosen over asking the worklet's `attach.info` specifically so
  /// this stays device-free for the fake/unit-test path (and honors
  /// `debugDefaultTargetPlatformOverride`, letting a single test process
  /// exercise both platforms' values).
  ///
  /// iOS's [PearBackgroundExecution.foregroundOnly] is D11's finding, not a
  /// guess: the pure-Dart linger timer never fires while genuinely
  /// backgrounded on iOS (the whole isolate freezes). D11's recommended
  /// native-side `suspend(withLinger:)` fix (flutter_pear-ovt.3.4) has since
  /// shipped and is verified on-simulator, but it only makes backgrounding
  /// transition *cleanly* (a prompt, well-behaved suspend instead of an
  /// undefined frozen state) — it does not keep the worklet connected
  /// *during* backgrounding, since the short `beginBackgroundTask` used to
  /// make the native call reliable ends immediately after, leaving iOS free
  /// to suspend the process at any point. Nothing here is a background-
  /// execution entitlement (no VoIP, no background fetch). So this pin
  /// stays correct even after that fix: claiming
  /// [PearBackgroundExecution.bestEffort] would still overclaim what the
  /// library does. See `doc/ios.md`'s "Background execution on iOS"
  /// section for the full picture.
  ///
  /// macOS's [PearBackgroundExecution.unrestricted] (flutter_pear-iqp,
  /// E-D4) reflects a real capability upgrade over mobile, not just a
  /// looser pin: desktop imposes no OS-level suspension on a backgrounded
  /// app at all. See `doc/macos.md`'s "Background execution on macOS"
  /// section for the full picture, including why [Pear]'s own
  /// [PearLifecycle] auto-suspend policy defaults to
  /// [PearLifecyclePolicy.manual] on this platform.
  static PearPlatformInfo get platformInfo {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return const PearPlatformInfo(
          backgroundExecution: PearBackgroundExecution.bestEffort,
          validationTier: PearValidationTier.device,
        );
      case TargetPlatform.iOS:
        return const PearPlatformInfo(
          backgroundExecution: PearBackgroundExecution.foregroundOnly,
          validationTier: PearValidationTier.simulator,
        );
      case TargetPlatform.macOS:
        return const PearPlatformInfo(
          // flutter_pear-iqp (E-D4): macOS spawns `bare` as a plain
          // subprocess (flutter_pear-71g, E-D2a) with no OS-level app-
          // lifecycle suspension the way iOS/Android impose — minimizing or
          // backgrounding the app does not pause or throttle it, verified
          // by holding a real swarm connection open across a window
          // minimize. `validationTier: device` is accurate here, not an
          // overclaim: unlike iOS Simulator/Android Emulator, a macOS build
          // runs directly on real hardware — desktop has no separate
          // simulator layer to distinguish from.
          backgroundExecution: PearBackgroundExecution.unrestricted,
          validationTier: PearValidationTier.device,
        );
      default:
        throw UnsupportedError(
          'Pear.platformInfo is only defined for TargetPlatform.android, '
          'TargetPlatform.iOS, and TargetPlatform.macOS, got '
          '$defaultTargetPlatform.',
        );
    }
  }

  /// Starts the worklet (from the bundled pear-end, or [bundlePath] if given).
  ///
  /// Always asks the worklet's [PearMethod.attachInfo] for the bundle
  /// [linger] (flutter_pear-ovt.3.4, D11) is [lifecycle]'s configured
  /// linger window, forwarded to [BareWorklet.start] so the iOS host can
  /// honor it for its own native `suspendWithLinger` even if Dart's own
  /// isolate never gets a chance to run while backgrounded (DX2 #52: a
  /// public API's configured value must reach whichever host actually
  /// needs it, not be silently bypassed).
  ///
  /// Always asks the worklet's [PearMethod.attachInfo] for the bundle
  /// version it's actually running (E6.3, LOCKED rule: reattach only when
  /// HEALTHY and version-matched, else kill + cleanly restart — never
  /// require an app reinstall). If [BareWorklet.reattached] reports this
  /// attached to an already-running worklet (a Dart hot restart), that
  /// first probe is bounded to the short [PearRpcDefaults.attachHealthTimeout]
  /// — an unresponsive REATTACHED worklet is genuinely suspicious, so a
  /// quick "can't trust it, kill + restart" is the right call. A worklet
  /// [BareWorklet.start] just booted fresh gets the normal, longer
  /// [PearRpcDefaults.callTimeout] instead — real JS engine + native module
  /// init legitimately takes real time, and misclassifying that as
  /// "unhealthy" would make [start] fail forever on a device merely slow to
  /// cold-boot. A version mismatch (the reattached worklet is running a
  /// bundle that predates a rebuild) gets the same kill + restart response
  /// as an unhealthy reattach. The retry after either kill is always a
  /// fresh boot (nothing is "already running" to reattach to anymore), so
  /// it always uses the normal timeout too. If the retry still fails
  /// (mismatched, or a non-timeout failure), this throws rather than
  /// silently proceeding — there's nothing left to retry with, and a
  /// version mismatch specifically means the bundled asset itself is
  /// likely stale (someone forgot to re-run `dart run flutter_pear:pack`).
  static Future<Pear> start({
    String? bundlePath,
    Duration linger = PearLifecycleDefaults.linger,
  }) async {
    var worklet = await BareWorklet.start(
      bundlePath: bundlePath,
      lingerMs: linger.inMilliseconds,
    );
    var rpc = PearRpc(worklet);
    try {
      String? bundleVersion;
      try {
        bundleVersion = await _fetchBundleVersion(
          rpc,
          timeout: worklet.reattached
              ? PearRpcDefaults.attachHealthTimeout
              : PearRpcDefaults.callTimeout,
        );
      } on PearException catch (e) {
        if (e.code != PearErrorCode.rpcTimeout) rethrow;
        // Unhealthy: this reattached worklet never answered attach.info
        // within the bounded health-probe timeout -- treated exactly like
        // a version mismatch below (same "can't trust it, kill + restart
        // once" response). Only a TIMEOUT is reinterpreted this way; any
        // other failure (e.g. the worklet self-reporting WORKLET_CRASHED)
        // is a materially different problem and must travel to the
        // caller immediately, not be silently papered over by a retry.
        bundleVersion = null;
      }

      if (bundleVersion != kPearEndBundleVersion) {
        await rpc.dispose();
        await worklet.terminate();
        worklet = await BareWorklet.start(
          bundlePath: bundlePath,
          lingerMs: linger.inMilliseconds,
        );
        rpc = PearRpc(worklet);
        // Second attempt: always a fresh boot (whatever was running got
        // terminated above), so the normal timeout applies -- and a
        // genuine failure here is no longer reinterpreted as "maybe just
        // unhealthy, try once more"; there's nothing left to retry with,
        // so it's allowed to propagate normally instead of being masked
        // as a version mismatch.
        bundleVersion = await _fetchBundleVersion(
          rpc,
          timeout: PearRpcDefaults.callTimeout,
        );

        if (bundleVersion != kPearEndBundleVersion) {
          throw pearExceptionFor(
            'pear-end bundle version mismatch persists after a kill+restart '
            '(expected $kPearEndBundleVersion, worklet reports $bundleVersion) '
            '-- the bundled asset is likely stale; run '
            '`dart run flutter_pear:pack` and rebuild.',
            code: PearErrorCode.bundleVersionMismatch,
          );
        }
      }
    } catch (_) {
      // Whatever worklet+rpc is currently held (the first boot, or the
      // kill+restart's second attempt) must not leak if we're about to
      // throw -- e.g. attach.info itself timing out on a slow/cold-booting
      // device. Otherwise a caller that retries Pear.start() reattaches to
      // a worklet nobody terminated, with an orphaned PearRpc still
      // subscribed to it and never disposed.
      await rpc.dispose();
      await worklet.terminate();
      rethrow;
    }

    return Pear._(worklet, rpc, linger);
  }

  /// The [PearMethod.attachInfo] probe [start] uses for both its reattach
  /// health check and any post-kill-restart retry (E6.3) — [timeout] is
  /// [PearRpcDefaults.attachHealthTimeout] only when probing a possibly-
  /// already-running (reattached) worklet; every other case uses the
  /// normal [PearRpcDefaults.callTimeout] (see [start]'s own doc for why).
  static Future<String> _fetchBundleVersion(
    PearRpc rpc, {
    required Duration timeout,
  }) async {
    final info = await rpc.call(PearMethod.attachInfo, null, timeout) as Map;
    return info[PearHandshakeField.bundleVersion] as String;
  }

  /// Joins a Hyperswarm [topic] and surfaces peer connections.
  Future<PearSwarm> join(PearKey topic) => PearSwarm.join(_rpc, topic);

  /// The Corestore-backed store for append-only [PearCore] logs (E5.2).
  PearStore get store => PearStore(_rpc);

  /// Opens a Hyperbee key/value store (E5.3) — see [PearBee.open] for the
  /// [name]/[key] contract.
  Future<PearBee> bee({String? name, PearKey? key}) =>
      PearBee.open(_rpc, name: name, key: key);

  /// Opens a Hyperdrive file store (E5.5) — see [PearDrive.open] for the
  /// [name]/[key] contract.
  Future<PearDrive> drive({String? name, PearKey? key}) =>
      PearDrive.open(_rpc, name: name, key: key);

  /// Creates a blind-pairing invite (E5.6) — see [PearPairing.createInvite].
  Future<PearInvite> createInvite({Duration? ttl}) =>
      PearPairing.createInvite(_rpc, ttl: ttl);

  /// Accepts a blind-pairing invite (E5.6) — see [PearPairing.acceptInvite].
  Future<PearKey> acceptInvite(
    Uint8List invite, {
    Uint8List? userData,
    Duration timeout = const Duration(seconds: 30),
  }) =>
      PearPairing.acceptInvite(_rpc, invite,
          userData: userData, timeout: timeout);

  /// Opens an Autobase multi-writer data structure (E5.8) — see
  /// [PearBase.open] for the [recipe]/[name]/[key] contract.
  Future<PearBase> base({
    required PearRecipe recipe,
    String? name,
    PearKey? key,
  }) =>
      PearBase.open(_rpc, recipe: recipe, name: name, key: key);

  /// Suspends the worklet (E6.2) — called automatically by [lifecycle] when
  /// its `policy` is [PearLifecyclePolicy.auto], or call this directly at
  /// any time regardless of policy. A no-op if the worklet isn't currently
  /// running (including if it's already suspended) — matches
  /// `BareWorklet.suspend`'s own idempotency, and additionally skips
  /// notifying every joined `PearSwarm` when nothing actually changed (a
  /// quick app-switch that never reaches [PearLifecycle]'s linger window
  /// must never appear on `PearSwarm.state` as a spurious transition).
  /// Serialized against [resume] and other [suspend] calls on this same
  /// [Pear] — see [_lifecycleQueue]'s doc. See `BACKGROUND_EXECUTION.md`
  /// for what suspending actually buys you on Android versus what's
  /// entirely outside this library's control (E6.4).
  Future<void> suspend() => _queueLifecycleOp(() async {
        final wasRunning = worklet.state == WorkletState.running;
        await worklet.suspend();
        if (wasRunning) _rpc.notifyWorkletSuspended(true);
      });

  /// Resumes a suspended worklet (E6.2) — see [suspend]'s doc for the
  /// idempotency/no-spurious-transition/serialization guarantees, mirrored
  /// here for resume.
  Future<void> resume() => _queueLifecycleOp(() async {
        final wasSuspended = worklet.state == WorkletState.suspended;
        await worklet.resume();
        if (wasSuspended) _rpc.notifyWorkletSuspended(false);
      });

  Future<void> _queueLifecycleOp(Future<void> Function() op) {
    final result = _lifecycleQueue.then((_) => op());
    _lifecycleQueue = result.catchError((_) {});
    return result;
  }

  /// Runs an auto-triggered (not caller-awaited) [lifecycle] callback and
  /// reports — rather than silently swallowing — any failure via
  /// [FlutterError.reportError], since nothing else is awaiting this call's
  /// Future to observe a thrown error otherwise (CLAUDE.md's "errors must
  /// travel" non-negotiable: a failed auto-suspend/resume must be loud, not
  /// a silent gap). A directly-awaited `pear.suspend()`/`pear.resume()`
  /// call needs no such wrapper — its own Future already carries the error
  /// to its caller normally.
  Future<void> _guardedAutoCall(Future<void> Function() op) async {
    try {
      await op();
    } catch (error, stack) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'flutter_pear',
        context:
            ErrorDescription('PearLifecycle auto-triggered suspend/resume'),
      ));
    }
  }

  /// Tears down the RPC bridge and terminates the worklet.
  Future<void> dispose() async {
    lifecycle.dispose();
    // Waits for any in-flight suspend()/resume() (including one
    // PearLifecycle just triggered right before this call) to fully
    // finish before _rpc is disposed -- otherwise a still-running
    // notifyWorkletSuspended could call .add() on _rpc's already-closed
    // stream.
    await _lifecycleQueue;
    await _rpc.dispose();
    await worklet.terminate();
  }
}
