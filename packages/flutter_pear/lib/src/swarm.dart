import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'rpc.dart';

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
  Future<void> write(Uint8List bytes) => _rpc.call('connection.write', {
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
  final Map<String, PearConnection> _byKey = {};
  late final StreamSubscription<PearEvent> _eventSub;

  /// New peer connections discovered on this topic.
  Stream<PearConnection> get connections => _connections.stream;

  /// Joins [topic] over [rpc] and starts surfacing connections.
  static Future<PearSwarm> join(PearRpc rpc, PearKey topic) async {
    final swarm = PearSwarm._(rpc, topic);
    swarm._wire();
    await rpc.call('swarm.join', {'topic': topic.hex});
    return swarm;
  }

  void _wire() {
    _eventSub = _rpc.events.listen((e) {
      final p = e.payload;
      if (p is! Map || p['topic'] != topic.hex) return;
      switch (e.name) {
        case 'swarm.connection':
          final key = PearKey.fromHex(p['peer'] as String);
          final conn = PearConnection._(_rpc, key);
          _byKey[key.hex] = conn;
          _connections.add(conn);
        case 'connection.data':
          _byKey[p['peer']]?._add(base64Decode(p['data'] as String));
        case 'connection.close':
          _byKey.remove(p['peer'])?._close();
      }
    });
  }

  /// Leaves the topic and closes its connections.
  Future<void> leave() async {
    await _rpc.call('swarm.leave', {'topic': topic.hex});
    await _eventSub.cancel();
    for (final c in _byKey.values) {
      await c._close();
    }
    _byKey.clear();
    await _connections.close();
  }
}
