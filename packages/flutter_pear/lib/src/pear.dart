import 'package:flutter_pear_bare/flutter_pear_bare.dart';

import 'crypto.dart';
import 'rpc.dart';
import 'swarm.dart';

/// Entry point to the Pear P2P stack.
///
/// ```dart
/// final pear = await Pear.start();
/// final swarm = await pear.join(PearCrypto.topicFromString('my-room'));
/// swarm.connections.listen((conn) => conn.write(utf8.encode('hi')));
/// // ...
/// await pear.dispose();
/// ```
class Pear {
  Pear._(this.worklet, this._rpc);

  /// The underlying Bare worklet. Use directly only for the low-level echo/IPC
  /// path or a custom bundle; the high-level API covers normal use.
  final BareWorklet worklet;

  final PearRpc _rpc;

  /// Starts the worklet (from the bundled pear-end, or [bundlePath] if given).
  static Future<Pear> start({String? bundlePath}) async {
    final worklet = await BareWorklet.start(bundlePath: bundlePath);
    return Pear._(worklet, PearRpc(worklet));
  }

  /// Joins a Hyperswarm [topic] and surfaces peer connections.
  Future<PearSwarm> join(PearKey topic) => PearSwarm.join(_rpc, topic);

  /// Tears down the RPC bridge and terminates the worklet.
  Future<void> dispose() async {
    await _rpc.dispose();
    await worklet.terminate();
  }
}
