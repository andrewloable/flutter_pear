import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pear_bare/flutter_pear_bare.dart';

import 'exceptions.dart';

/// A worklet-emitted event: a [name] like `swarm.connection` and its [payload].
typedef PearEvent = ({String name, Object? payload});

/// Minimal request/response + event bridge over the worklet's binary IPC.
///
/// Each IPC frame is one UTF-8 JSON object:
/// ```
/// {"id":1,"m":"swarm.join","p":{...}}   request  (Dart→worklet)
/// {"id":1,"ok":{...}}                    response (worklet→Dart)
/// {"id":1,"err":{"message","code","stack"}}
/// {"ev":"swarm.connection","p":{...}}    event    (worklet→Dart)
/// ```
///
/// ponytail: a JSON envelope is fine for control-plane traffic (swarm, kv keys).
/// Bulk binary (Hyperdrive contents) gets a raw-payload frame type when M3 needs
/// it — don't base64 megabytes through JSON. Small message bytes ride as base64
/// for now (see PearConnection).
class PearRpc {
  /// Binds to a running [worklet]'s IPC.
  PearRpc(this._worklet) {
    _sub = _worklet.incoming.listen(_onFrame);
  }

  final BareWorklet _worklet;
  late final StreamSubscription<Uint8List> _sub;
  int _nextId = 1;
  final Map<int, Completer<Object?>> _pending = {};
  final StreamController<PearEvent> _events =
      StreamController<PearEvent>.broadcast();

  /// All worklet-emitted events (swarm connections, watch notifications, …).
  Stream<PearEvent> get events => _events.stream;

  /// Sends a request and completes with its result, or throws a [PearException].
  Future<Object?> call(String method, [Map<String, Object?>? params]) {
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _worklet.send(_encode({
      'id': id,
      'm': method,
      if (params != null) 'p': params,
    }));
    return completer.future;
  }

  void _onFrame(Uint8List frame) {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(frame));
    } catch (_) {
      return; // not a JSON control frame; ignore
    }
    if (decoded is! Map) return;

    final id = decoded['id'];
    if (id is int) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (decoded.containsKey('err')) {
        final err = decoded['err'] as Map;
        completer.completeError(PearException(
          err['message']?.toString() ?? 'worklet error',
          code: err['code']?.toString(),
          stack: err['stack']?.toString(),
        ));
      } else {
        completer.complete(decoded['ok']);
      }
    } else if (decoded['ev'] is String) {
      _events.add((name: decoded['ev'] as String, payload: decoded['p']));
    }
  }

  Uint8List _encode(Map<String, Object?> frame) =>
      Uint8List.fromList(utf8.encode(jsonEncode(frame)));

  /// Cancels the IPC subscription and fails any in-flight requests.
  Future<void> dispose() async {
    await _sub.cancel();
    for (final c in _pending.values) {
      c.completeError(PearException('worklet disposed'));
    }
    _pending.clear();
    await _events.close();
  }
}
