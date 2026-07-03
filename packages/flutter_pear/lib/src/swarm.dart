import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'exceptions.dart';
import 'rpc.dart';
import 'schema.dart';

/// One connection-state transition for a joined topic (see [PearSwarm.state]
/// and [PearSwarmState]). [error] is set only when [state] is
/// [PearSwarmState.failed] — the reason (e.g. [PearErrorCode.connectTimeout]
/// or [PearErrorCode.udpBlocked]) travels as a typed [PearException], not
/// just a bare code string, matching every other typed failure in this API.
typedef PearSwarmStatus = ({PearSwarmState state, PearException? error});

/// One peer connection: a duplex byte pipe, Noise/secret-stream encrypted inside
/// the worklet.
class PearConnection {
  PearConnection._(this._rpc, this.remotePublicKey);

  final PearRpc _rpc;

  /// The remote peer's public key.
  final PearKey remotePublicKey;

  final StreamController<Uint8List> _data =
      StreamController<Uint8List>.broadcast();

  /// Bytes received from the peer.
  Stream<Uint8List> get data => _data.stream;

  void _add(Uint8List bytes) => _data.add(bytes);

  /// Sends [bytes] to the peer.
  Future<void> write(Uint8List bytes) => _rpc.call(PearMethod.connectionWrite, {
        'peer': remotePublicKey.hex,
        // ponytail: base64 works for chat-sized messages today; M3 swaps in a
        // raw-payload frame so Hyperdrive bulk doesn't inflate through JSON.
        'data': base64Encode(bytes),
      });

  Future<void> _close() => _data.close();
}

/// Membership in a Hyperswarm [topic] and the peer connections it yields.
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
  late final StreamSubscription<PearEvent> _eventSub;
  Timer? _joinTimer;
  bool _everConnected = false;
  PearSwarmStatus _currentState =
      (state: PearSwarmState.discovering, error: null);

  /// New peer connections discovered on this topic.
  Stream<PearConnection> get connections => _connections.stream;

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
          _connections.add(conn);
        case PearEventName.connectionData:
          _byKey[p['peer']]?._add(base64Decode(p['data'] as String));
        case PearEventName.connectionClose:
          _byKey.remove(p['peer'])?._close();
        case PearEventName.swarmLifecycle:
          _applyLifecycle(p);
      }
    });
  }

  void _applyLifecycle(Map<Object?, Object?> p) {
    final wireState = p['state'];
    if (wireState is! String) return; // an ad hoc notice, not a state transition
    final parsed = PearSwarmState.values.asNameMap()[wireState];
    if (parsed == null) return; // a state name this version of the schema doesn't know
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
    for (final c in _byKey.values) {
      await c._close();
    }
    _byKey.clear();
    await _connections.close();
    await _state.close();
  }
}
