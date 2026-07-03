import 'package:flutter_pear_bare/flutter_pear_bare.dart';

import 'bee.dart';
import 'bundle_version.dart';
import 'crypto.dart';
import 'drive.dart';
import 'exceptions.dart';
import 'rpc.dart';
import 'schema.dart';
import 'store.dart';
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
  ///
  /// Whether this attaches to an already-running worklet (a Dart hot
  /// restart) or boots a fresh one, it always asks the worklet's
  /// [PearMethod.attachInfo] for the bundle version it's actually running.
  /// A mismatch (a hot-restart reattach to a worklet loaded from a bundle
  /// that predates a rebuild) triggers exactly one kill + fresh start —
  /// never converse with a stale bundle. If the version STILL mismatches
  /// after that restart, the bundled asset itself must be stale (someone
  /// forgot to re-run `dart run flutter_pear:pack`), so this throws rather
  /// than silently proceeding against a worklet known not to match.
  static Future<Pear> start({String? bundlePath}) async {
    var worklet = await BareWorklet.start(bundlePath: bundlePath);
    var rpc = PearRpc(worklet);
    try {
      var bundleVersion = await _fetchBundleVersion(rpc);

      if (bundleVersion != kPearEndBundleVersion) {
        await rpc.dispose();
        await worklet.terminate();
        worklet = await BareWorklet.start(bundlePath: bundlePath);
        rpc = PearRpc(worklet);
        bundleVersion = await _fetchBundleVersion(rpc);

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

    return Pear._(worklet, rpc);
  }

  static Future<String> _fetchBundleVersion(PearRpc rpc) async {
    final info = await rpc.call(PearMethod.attachInfo) as Map;
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

  /// Tears down the RPC bridge and terminates the worklet.
  Future<void> dispose() async {
    await _rpc.dispose();
    await worklet.terminate();
  }
}
