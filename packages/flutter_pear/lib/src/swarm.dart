import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'exceptions.dart';
import 'rpc.dart';
import 'schema.dart';

/// One connection-state transition for a joined topic (see [PearSwarm.state]
/// and [PearSwarmState]). `error` is set only when `state` is
/// [PearSwarmState.failed] — the reason (e.g. [PearErrorCode.connectTimeout]
/// or [PearErrorCode.udpBlocked]) travels as a typed [PearException], not
/// just a bare code string, matching every other typed failure in this API.
typedef PearSwarmStatus = ({PearSwarmState state, PearException? error});

/// One peer connection: a duplex byte pipe, Noise/secret-stream encrypted inside
/// the worklet.
///
/// EPHEMERAL, not a durable session (E6.5, see `RECONNECT_CONTRACT.md` for
/// the full decision): when this connection drops, [data] closes and
/// [write] starts failing — it never silently recovers. A reconnect to the
/// same peer arrives as a BRAND-NEW [PearConnection] on
/// [PearSwarm.connections], never this same object revived. There is also
/// NO message-delivery guarantee here: a byte in flight when the connection
/// drops is simply lost, with no retry/replay at this layer — an app
/// needing delivery/ordering guarantees across a reconnect needs a
/// Hypercore/Autobase-backed structure (E5.2–E5.8), not raw [write]/[data].
class PearConnection {
  PearConnection._(this._rpc, this.remotePublicKey);

  final PearRpc _rpc;

  /// The remote peer's public key.
  final PearKey remotePublicKey;

  final StreamController<Uint8List> _data =
      StreamController<Uint8List>.broadcast();
  bool _closed = false;

  /// Bytes received from the peer. Closes when this connection drops — see
  /// this class's own doc for why that's never silently recovered.
  Stream<Uint8List> get data => _data.stream;

  void _add(Uint8List bytes) => _data.add(bytes);

  /// Sends [bytes] to the peer — no delivery/ordering guarantee if this
  /// connection drops mid-flight (see this class's own doc). Fails with
  /// [PearErrorCode.connectionClosed] once this connection has closed —
  /// checked LOCALLY, by this specific object, so a stale reference held
  /// past a drop can never silently resume delivering over a later
  /// reconnect's different `PearConnection` (the underlying
  /// `PearMethod.connectionWrite` RPC is keyed only by peer public key, so
  /// without this check a write on an old, already-closed object would
  /// otherwise reach the peer's NEW connection once it reconnects).
  Future<void> write(Uint8List bytes) {
    if (_closed) {
      return Future.error(pearExceptionFor(
        'cannot write: this PearConnection has already closed (the peer '
        'may have reconnected as a new PearConnection instead)',
        code: PearErrorCode.connectionClosed,
      ));
    }
    return _rpc.call(PearMethod.connectionWrite, {
      'peer': remotePublicKey.hex,
      // ponytail: base64 works for chat-sized messages today; M3 swaps in a
      // raw-payload frame so Hyperdrive bulk doesn't inflate through JSON.
      'data': base64Encode(bytes),
    });
  }

  Future<void> _close() {
    _closed = true;
    return _data.close();
  }
}

/// Membership in a Hyperswarm [topic] and the peer connections it yields.
///
/// ```dart
/// final pear = await Pear.start();
/// final topic = PearCrypto.unsafeTopicFromString('my-secret-room');
/// final swarm = await pear.join(topic);
///
/// swarm.connections.listen((conn) {
///   conn.data.listen((bytes) => print('peer: ${utf8.decode(bytes)}'));
///   conn.write(utf8.encode('hello'));
/// });
/// ```
class PearSwarm {
  PearSwarm._(this._rpc, this.topic);

  final PearRpc _rpc;

  /// The joined topic.
  final PearKey topic;

  final StreamController<PearConnection> _connections =
      StreamController<PearConnection>.broadcast();
  final StreamController<PearSwarmStatus> _state =
      StreamController<PearSwarmStatus>.broadcast();
  final Map<String, PearConnection> _byKey = {};
  final List<PearConnection> _established = [];
  late final StreamSubscription<PearEvent> _eventSub;
  late final StreamSubscription<bool> _suspendSub;
  Timer? _joinTimer;
  bool _everConnected = false;
  bool _firstConnectionsListenerAttached = false;
  PearSwarmStatus _currentState =
      (state: PearSwarmState.discovering, error: null);

  /// New peer connections discovered on this topic — including a fresh
  /// [PearConnection] for a peer reconnecting after a drop (E6.5, see
  /// [PearConnection]'s own doc for the full ephemeral-connection contract).
  ///
  /// The very FIRST listener to ever subscribe (across this [PearSwarm]'s
  /// whole lifetime) additionally, synchronously replays every connection
  /// already in [establishedConnections] before continuing with live ones
  /// (flutter_pear-c2b) — on a REJOIN, pear-end's own SWARM_JOIN handler
  /// replays `swarmConnection` for an already-connected peer synchronously,
  /// as part of the very `swarmJoin` RPC response [join] awaits internally;
  /// that replay lands in [_established] correctly regardless (a plain,
  /// unconditional list-append inside [_wire]'s handler) but, absent this
  /// replay, would be lost forever by this stream specifically — a caller's
  /// own `.connections.listen(...)` can only run AFTER [join] returns,
  /// strictly after the replay already fired. A SECOND (or later) listener
  /// gets ordinary broadcast semantics with no replay, matching the
  /// buffer-once-drain-once convention `flutter_pear_example`'s own
  /// `PrejoinedSwarmWiring` uses for an analogous, pairing-flow-specific
  /// gap (the realistic case — one app-level subscriber per swarm — never
  /// distinguishes first vs. later, but a hypothetical second subscriber
  /// shouldn't see [establishedConnections] delivered to it twice, e.g. via
  /// a re-triggered `conn.data.listen(...)` double-registration).
  Stream<PearConnection> get connections => Stream.multi((controller) {
        if (!_firstConnectionsListenerAttached) {
          _firstConnectionsListenerAttached = true;
          for (final conn in _established) {
            controller.add(conn);
          }
        }
        final sub = _connections.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
        controller.onCancel = sub.cancel;
      });

  /// Every connection seen so far, in arrival order — this class's
  /// synchronous-snapshot equivalent of [currentState], but for
  /// [connections]. A plain broadcast stream can't replay a past event to a
  /// listener that subscribes late, so a peer connecting faster than a
  /// caller gets around to `.connections.listen(...)` (plausible on a fast
  /// network, and always true against a fake worklet with zero discovery
  /// delay) would otherwise be missed permanently. Read this right after
  /// subscribing to catch anything that already arrived; includes
  /// connections that have since closed.
  List<PearConnection> get establishedConnections =>
      List.unmodifiable(_established);

  /// The state as of right now — starts at [PearSwarmState.discovering] the
  /// instant [join] is called. Read this first if you need to know where
  /// things stand before subscribing to [state]: a plain broadcast stream
  /// can't replay a past event to a listener that attaches late, and by the
  /// time [join]'s returned Future resolves there's no way to have
  /// subscribed early enough to catch the initial discovering transition
  /// on the stream itself.
  PearSwarmStatus get currentState => _currentState;

  /// Connection-state transitions for this topic (E2.7) — see
  /// [PearSwarmState]. Broadcast, like every other Pear event stream
  /// ([PearRpc.events], [connections]): delivers every transition from the
  /// moment a listener subscribes onward (starting no earlier than
  /// [PearSwarmState.connecting] — see [currentState] for the implicit
  /// starting point).
  ///
  /// Relies on each incoming worklet frame arriving as its own separate
  /// platform-channel task (see `BareWorklet._onIpc`): Dart always finishes
  /// running a caller's synchronous continuation after `await join(...)` —
  /// including a `.state.listen(...)` call right after it — before the
  /// NEXT frame's task can be processed, so a transition can't race ahead
  /// of a listener that subscribes immediately after `join` returns.
  Stream<PearSwarmStatus> get state => _state.stream;

  /// Joins [topic] over [rpc] and starts surfacing connections.
  ///
  /// If [PearSwarmState.connected] is never reached within [joinTimeout]
  /// (default `PearSwarmDefaults.joinTimeout`), [state] emits
  /// [PearSwarmState.failed] with [PearErrorCode.connectTimeout] instead of
  /// waiting forever — an unreachable network (e.g. UDP blocked by a NAT)
  /// becomes an honest, bounded failure rather than an infinite silent
  /// wait. This method itself still returns as soon as the join request is
  /// acknowledged; watch [state] (or [connections]) for what happens next.
  static Future<PearSwarm> join(
    PearRpc rpc,
    PearKey topic, {
    Duration joinTimeout = PearSwarmDefaults.joinTimeout,
  }) async {
    final swarm = PearSwarm._(rpc, topic);
    swarm._wire();
    swarm._joinTimer = Timer(joinTimeout, swarm._onJoinTimeout);
    await rpc.call(PearMethod.swarmJoin, {'topic': topic.hex});
    return swarm;
  }

  void _wire() {
    _eventSub = _rpc.events.listen((e) {
      final p = e.payload;
      if (p is! Map || p['topic'] != topic.hex) return;
      switch (e.name) {
        case PearEventName.swarmConnection:
          final key = PearKey.fromHex(p['peer'] as String);
          final conn = PearConnection._(_rpc, key);
          _byKey[key.hex] = conn;
          _established.add(conn);
          _connections.add(conn);
        case PearEventName.connectionData:
          _byKey[p['peer']]?._add(base64Decode(p['data'] as String));
        case PearEventName.connectionClose:
          _byKey.remove(p['peer'])?._close();
        case PearEventName.swarmLifecycle:
          _applyLifecycle(p);
      }
    });
    // E6.2: a suspended worklet can't run JS at all, so pear-end can never
    // itself emit a swarmLifecycle transition for this -- PearRpc.
    // notifyWorkletSuspended is the Dart-local substitute (see its own doc
    // for why PearRpc, not a direct Pear<->PearSwarm link, carries this).
    _suspendSub = _rpc.workletSuspendedChanges.listen((suspended) {
      if (suspended) {
        _setState(PearSwarmState.suspended, null);
        return;
      }
      // Resuming doesn't itself prove anything about connectivity --
      // pear-end may or may not notice a real change (e.g. the OS actually
      // dropped every socket while backgrounded) once it's running again,
      // and reports that separately, in its own time, as an ordinary
      // swarmLifecycle transition. This is just the immediate, best-effort
      // signal that gets `state` OFF of `suspended` right away, from
      // whatever this swarm already knows locally. PearSwarmState.
      // reconnecting's own doc requires having been connected at least
      // once -- a swarm suspended while still discovering (never
      // connected) must resume back to discovering, not reconnecting.
      final PearSwarmState resumedState;
      if (_byKey.isNotEmpty) {
        resumedState = PearSwarmState.connected;
      } else if (_everConnected) {
        resumedState = PearSwarmState.reconnecting;
      } else {
        resumedState = PearSwarmState.discovering;
      }
      _setState(resumedState, null);
    });
  }

  void _applyLifecycle(Map<Object?, Object?> p) {
    final wireState = p['state'];
    if (wireState is! String) {
      return; // an ad hoc notice, not a state transition
    }
    final parsed = PearSwarmState.values.asNameMap()[wireState];
    if (parsed == null) {
      return; // a state name this version of the schema doesn't know
    }
    if (parsed == PearSwarmState.connected) {
      _everConnected = true;
      _joinTimer?.cancel();
    }
    final reasonCode = p['reason'];
    final error = reasonCode is String
        ? pearExceptionFor('swarm failed: $reasonCode', code: reasonCode)
        : null;
    _setState(parsed, error);
  }

  /// Fires when [joinTimeout] elapses without ever reaching
  /// [PearSwarmState.connected] — the bounded-failure guarantee described
  /// on [join].
  void _onJoinTimeout() {
    if (_everConnected) return; // already succeeded; nothing to time out
    _setState(
      PearSwarmState.failed,
      pearExceptionFor(
        'no peer connection within the join timeout',
        code: PearErrorCode.connectTimeout,
      ),
    );
  }

  void _setState(PearSwarmState newState, PearException? error) {
    _currentState = (state: newState, error: error);
    _state.add(_currentState);
  }

  /// Leaves the topic and closes its connections.
  Future<void> leave() async {
    _joinTimer?.cancel();
    await _rpc.call(PearMethod.swarmLeave, {'topic': topic.hex});
    await _eventSub.cancel();
    await _suspendSub.cancel();
    for (final c in _byKey.values) {
      await c._close();
    }
    _byKey.clear();
    await _connections.close();
    await _state.close();
  }
}
