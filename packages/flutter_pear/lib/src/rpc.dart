import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_pear_bare/flutter_pear_bare.dart';

import 'exceptions.dart';
import 'schema.dart';

/// A worklet-emitted event: a [name] like `swarm.connection` and its [payload].
typedef PearEvent = ({String name, Object? payload});

/// Minimal request/response + event bridge over the worklet's binary IPC.
///
/// Every IPC frame is a 1-byte [PearFrameType] discriminator followed by a
/// body. For [PearFrameType.json] (the only kind sent today) the body is one
/// UTF-8 JSON object:
/// ```
/// {"id":1,"m":"swarm.join","p":{...}}   request  (Dart→worklet)
/// {"id":1,"ok":{...},"n":"..."}          response (worklet→Dart)
/// {"id":1,"err":{"message","code","stack"},"n":"..."}
/// {"ev":"swarm.connection","p":{...},"n":"..."}   event (worklet→Dart)
/// ```
/// A [PearFrameType.raw] frame, an unrecognized discriminator byte, or a
/// JSON frame whose body fails to parse all surface as a
/// [PearEventName.rpcDiagnostic] event instead of vanishing silently.
///
/// A [call] that never gets a response (a dropped frame, a dead worklet)
/// fails with a typed timeout error instead of hanging forever — see
/// [PearRpcDefaults.callTimeout].
///
/// Every worklet→Dart frame carries a session nonce (`n`,
/// [PearHandshakeField.envelopeNonce]) identifying which worklet
/// process/generation sent it. [Pear.start] asks for it via
/// [PearMethod.attachInfo] immediately after constructing a [PearRpc];
/// events from any OTHER generation (e.g. a straggler frame from a worklet
/// just killed for reporting a stale bundle version) are silently dropped —
/// except [PearEventName.workletCrash] while NO session is established yet
/// (the boot-time-crash case); once one is, it's gated exactly like any
/// other event — see [_onFrame].
///
/// ponytail: a JSON envelope is fine for control-plane traffic (swarm, kv keys).
/// Bulk binary (Hyperdrive contents) gets a raw-payload frame type when M3 needs
/// it — don't base64 megabytes through JSON. Small message bytes ride as base64
/// for now (see PearConnection).
class PearRpc {
  /// Binds to a running [worklet]'s IPC.
  PearRpc(this._worklet) {
    _sub = _worklet.incoming.listen(_onFrame);
    // Native-detected backstop (E2.6) -- see WorkletIpc.onCrash's doc for
    // why this is separate from (and less detailed than) the
    // PearEventName.workletCrash case _onFrame handles below.
    _crashSub =
        _worklet.onCrash.listen((c) => _onCrash(c.reason, detail: c.detail));
  }

  final WorkletIpc _worklet;
  late final StreamSubscription<Uint8List> _sub;
  late final StreamSubscription<WorkletCrash> _crashSub;
  bool _disposed = false;
  bool _crashed = false;
  final Map<int, Completer<Object?>> _pending = {};
  final Map<int, Timer> _timers = {};
  final StreamController<PearEvent> _events =
      StreamController<PearEvent>.broadcast();
  final StreamController<bool> _workletSuspendedChanges =
      StreamController<bool>.broadcast();

  static final Random _idRandom = Random();

  // The session nonce established by the first frame this instance accepts
  // as authoritative (see _onFrame) -- null until then.
  String? _currentNonce;

  /// All worklet-emitted events (swarm connections, watch notifications, …).
  Stream<PearEvent> get events => _events.stream;

  /// Broadcasts `true` when `Pear.suspend` suspends the worklet, `false`
  /// when `Pear.resume` resumes it (E6.2) — every `PearSwarm` sharing this
  /// [PearRpc] listens so it can reflect suspension on its own
  /// `PearSwarm.state`, since pear-end itself can never emit anything while
  /// genuinely suspended (a paused worklet can't run JS at all, so there's
  /// no JS-side event to relay). [PearRpc] is the natural shared object for
  /// this — a `Pear` and every `PearSwarm` it creates already hold the same
  /// instance, unlike `Pear`/`PearSwarm` themselves, which are separate
  /// libraries with no private access into each other.
  Stream<bool> get workletSuspendedChanges => _workletSuspendedChanges.stream;

  /// Called by `Pear.suspend`/`Pear.resume` — not meant to be called
  /// directly. A no-op after [dispose] — defensive, since `Pear.dispose`
  /// itself already waits for any in-flight suspend/resume to finish
  /// before disposing this [PearRpc], but a stray call must never throw
  /// trying to add to an already-closed broadcast stream.
  void notifyWorkletSuspended(bool suspended) {
    if (_disposed) return;
    _workletSuspendedChanges.add(suspended);
  }

  /// Sends a request and completes with its result, or throws a
  /// [PearException] — including [PearErrorCode.rpcTimeout] if the worklet
  /// doesn't respond within [timeout], [PearErrorCode.sendFailed] if the
  /// frame never reached the worklet at all, immediately
  /// [PearErrorCode.workletCrashed] if the worklet has already crashed, or
  /// immediately [PearErrorCode.workletDisposed] if [dispose] already ran.
  Future<Object?> call(
    String method, [
    Map<String, Object?>? params,
    Duration timeout = PearRpcDefaults.callTimeout,
  ]) {
    if (_crashed) {
      return Future.error(pearExceptionFor('worklet crashed',
          code: PearErrorCode.workletCrashed));
    }
    if (_disposed) {
      return Future.error(pearExceptionFor('worklet disposed',
          code: PearErrorCode.workletDisposed));
    }
    final id = _generateId();
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _timers[id] = Timer(
      timeout,
      () => _settle(
        id,
        error: pearExceptionFor(
          'no response from worklet within $timeout',
          code: PearErrorCode.rpcTimeout,
        ),
      ),
    );
    // Not awaited (a hung write shouldn't block call() from returning), but
    // an immediate failure -- e.g. the worklet isn't running -- must settle
    // this call right away instead of silently going unhandled and leaving
    // it to fail the full [timeout] later with the wrong code.
    _worklet
        .send(_encode({
      'id': id,
      'm': method,
      if (params != null) 'p': params,
    }))
        .catchError((Object error) {
      _settle(
        id,
        error: pearExceptionFor('failed to send to worklet: $error',
            code: PearErrorCode.sendFailed),
      );
    });
    return completer.future;
  }

  /// A fresh request id, never currently pending on this instance.
  ///
  /// Random, not sequential -- and NOT a `static` counter shared across
  /// instances either, despite that being tempting (E2.5 audit note: a
  /// static counter was tried first and is wrong). A Dart hot restart tears
  /// down and recreates the whole isolate, resetting ALL static/global
  /// state, while the NATIVE worklet keeps running with any of its
  /// in-flight, not-yet-answered calls still outstanding. A sequential
  /// counter -- static or not -- starts back at a small number after every
  /// restart, so a stale response finally arriving from before the restart
  /// is LIKELY, not just theoretically possible, to collide with an id the
  /// new instance has since reissued -- and worse, on a same-worklet hot
  /// restart (as opposed to a version-mismatch kill+restart) the envelope
  /// nonce is unchanged too, so nonce-checking responses wouldn't catch it
  /// either. A random id from a wide-enough range makes that collision
  /// vanishingly unlikely regardless of whether the worklet generation
  /// changed, which is what actually lets responses skip the nonce check.
  int _generateId() {
    int id;
    do {
      id = _idRandom.nextInt(1 << 31);
    } while (_pending.containsKey(id));
    return id;
  }

  /// Resolves the pending call [id], if it's still pending, with [result] or
  /// [error] (exactly one is passed).
  ///
  /// The per-call timeout, [_onFrame], and [dispose] are the only three ways
  /// a call is ever resolved, and each goes through here — so whichever one
  /// gets there first removes the entry, and the other(s) find it already
  /// gone and do nothing. A response frame that arrives after a timeout (or
  /// after dispose) is exactly that "already gone" case: silently ignored,
  /// not a double-complete crash.
  void _settle(int id, {Object? result, PearException? error}) {
    final completer = _pending.remove(id);
    _timers.remove(id)?.cancel();
    if (completer == null) return;
    if (error != null) {
      completer.completeError(error);
    } else {
      completer.complete(result);
    }
  }

  void _onFrame(Uint8List frame) {
    if (frame.isEmpty) return; // no discriminator byte to read; nothing to do

    final frameType = frame[0];
    if (frameType != PearFrameType.json) {
      // No PearFrameType.raw reader exists yet (M3 is the first planned
      // consumer) -- surfaced, not silently dropped, same as any other
      // byte this version of the schema doesn't recognize.
      _diagnostic('unhandled frame type', {'frameType': frameType});
      return;
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(frame.sublist(1)));
    } catch (error) {
      _diagnostic('malformed JSON control frame', {'error': error.toString()});
      return;
    }
    if (decoded is! Map) {
      _diagnostic('JSON control frame was not an object', {'decoded': decoded});
      return;
    }

    final frameNonce = decoded[PearHandshakeField.envelopeNonce];
    if (frameNonce is! String) {
      // The worklet stamps this on every frame it sends (E2.5 LOCKED) -- a
      // missing/wrong-typed one is the same "shape we don't recognize" case
      // as the checks above.
      _diagnostic('worklet frame missing session nonce', {'decoded': decoded});
      return;
    }

    final id = decoded['id'];
    if (id is int) {
      // Responses are protected by _generateId's randomness, not by
      // matching frameNonce against _currentNonce: a stale generation's
      // response is vanishingly unlikely to coincidentally land on a live
      // pending id here (see _generateId's doc for why a sequential
      // counter -- even a static one -- doesn't give this guarantee, but a
      // wide-enough random id does regardless of whether the worklet
      // generation changed). That's what lets the FIRST response we ever
      // see -- the attach.info round trip Pear.start makes immediately
      // after constructing this instance -- establish _currentNonce in the
      // first place, without a chicken-and-egg problem.
      _currentNonce ??= frameNonce;
      if (decoded.containsKey('err')) {
        final err = decoded['err'] as Map;
        _settle(
          id,
          error: pearExceptionFor(
            err['message']?.toString() ?? 'worklet error',
            code: err['code']?.toString(),
            stack: err['stack']?.toString(),
          ),
        );
      } else {
        _settle(id, result: decoded['ok']);
      }
    } else if (decoded['ev'] is String) {
      final evName = decoded['ev'] as String;
      final nonceMatches = _currentNonce != null && frameNonce == _currentNonce;
      if (evName == PearEventName.workletCrash &&
          (_currentNonce == null || nonceMatches)) {
        // The worklet's own self-report (E2.6), sent just before it calls
        // Bare.exit() -- see pear-end/index.js. Routed through _onCrash
        // rather than forwarded as-is so this and the native onCrash
        // backstop converge on one consistent app-facing shape/behavior.
        //
        // Only exempted from the nonce gate below while NO session is
        // established yet (_currentNonce == null) -- once one is, a crash
        // event still has to match it like any other event. That narrow
        // pre-session exemption exists because a crash can arrive before
        // Dart has ever received a single response (e.g. a boot-time throw
        // in module-level JS, before attach.info's handler is even
        // reachable -- see reportCrash's doc comment in pear-end/index.js),
        // which is exactly when _currentNonce is still null and there is no
        // established identity to check a nonce against anyway. That's
        // also the highest-value window to not lose the detailed
        // kind/message/stack in -- the alternative is attach.info silently
        // timing out with an unhelpful RPC_TIMEOUT instead of the real
        // reason.
        //
        // This is a knowing, bounded trade-off, not a closed hole: _ipc and
        // _control (bare_worklet.dart) are STATIC channels shared across
        // BareWorklet instances, and Flutter buffers a channel message that
        // arrives with no handler registered for later delivery to
        // whichever handler is registered next -- so a stale worklet
        // generation's crash report, delayed in flight past a kill+restart
        // (Pear.start's version-mismatch path), could in principle reach
        // a brand new, healthy PearRpc while its own _currentNonce is still
        // null and wrongly fail its pending calls. Accepted because the
        // failure mode is loud (WORKLET_CRASHED, immediately actionable),
        // not silent, and the same channel-reassignment risk class already
        // exists, unaddressed, in the native onCrash backstop's control
        // channel too -- see flutter_pear-7be.6's closing notes for the
        // follow-up ticket that tracks hardening this properly.
        final p = decoded['p'];
        final kind = p is Map ? p['kind']?.toString() ?? 'unknown' : 'unknown';
        final message = p is Map ? p['message']?.toString() : null;
        final stack = p is Map ? p['stack']?.toString() : null;
        _onCrash(kind,
            detail: stack != null ? '$message\n$stack' : message);
        return;
      }
      // Ordinary events have no id to correlate against, so unlike
      // responses they ARE at genuine risk from a killed worklet's
      // straggler frame -- reject anything not carrying the
      // currently-accepted session's nonce (including everything, if no
      // session is accepted yet). A workletCrash event falls through to
      // here too once a session IS established -- same protection applies.
      if (!nonceMatches) {
        return; // stale (or pre-session) generation's event -- silent drop
      }
      _events.add((name: evName, payload: decoded['p']));
    } else {
      // Valid JSON object, but neither a response (numeric id) nor an event
      // (string ev) -- the same "shape we don't recognize" case as the
      // decoded-is-not-a-Map branch above, so it gets the same treatment.
      _diagnostic('JSON control frame matched neither response nor event',
          {'decoded': decoded});
    }
  }

  /// Reacts to the worklet being gone -- from either signal (E2.6): the
  /// worklet's own detailed self-report ([PearEventName.workletCrash], via
  /// [_onFrame]) or the native detail-free backstop (`WorkletIpc.onCrash`,
  /// via the constructor's subscription). Idempotent -- whichever fires
  /// first wins; a second signal for the same crash is a no-op, not a
  /// double fail-all.
  void _onCrash(String reason, {String? detail}) {
    if (_crashed) return;
    _crashed = true;
    for (final id in _pending.keys.toList()) {
      _settle(
        id,
        error: pearExceptionFor('worklet crashed: $reason',
            code: PearErrorCode.workletCrashed),
      );
    }
    _events.add((
      name: PearEventName.workletCrash,
      payload: {'reason': reason, if (detail != null) 'detail': detail},
    ));
    // The worklet is gone -- nothing more will ever arrive on either
    // stream, and no new call should be allowed to pretend otherwise (see
    // call()'s _crashed check).
    unawaited(_sub.cancel());
    unawaited(_crashSub.cancel());
    unawaited(_events.close());
  }

  void _diagnostic(String reason, Map<String, Object?> extra) {
    _events.add((
      name: PearEventName.rpcDiagnostic,
      payload: {'reason': reason, ...extra},
    ));
  }

  Uint8List _encode(Map<String, Object?> frame) {
    final body = utf8.encode(jsonEncode(frame));
    return Uint8List(body.length + 1)
      ..[0] = PearFrameType.json
      ..setRange(1, body.length + 1, body);
  }

  /// Cancels the IPC subscription and fails any in-flight requests with
  /// [PearErrorCode.workletDisposed]. Any [call] made after this returns
  /// fails the same way immediately, rather than hanging until it times out.
  Future<void> dispose() async {
    _disposed = true;
    await _sub.cancel();
    await _crashSub.cancel();
    for (final id in _pending.keys.toList()) {
      _settle(
        id,
        error: pearExceptionFor('worklet disposed',
            code: PearErrorCode.workletDisposed),
      );
    }
    await _events.close();
    await _workletSuspendedChanges.close();
  }
}
