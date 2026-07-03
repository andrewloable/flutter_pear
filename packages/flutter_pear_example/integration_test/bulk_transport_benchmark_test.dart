// E5.1 -- real device/emulator benchmark: round-trip throughput + latency
// for 1KB/64KB/1MB/16MB payloads through BOTH candidate bulk-transport
// paths -- the in-channel BasicMessageChannel route (debug.echo, a raw
// round trip with no other JS-side work) and the file-path seam
// (bulk.writeFile, E4.4). The numbers this test prints are the evidence
// behind E5.1's decision record (see BENCHMARK.md at the flutter_pear
// package root) -- LOCKED default is file-path unless these numbers argue
// otherwise.
//
// Run: flutter test integration_test/bulk_transport_benchmark_test.dart -d <device>
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_pear/flutter_pear.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/rpc.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _sizes = {
  '1KB': 1024,
  '64KB': 64 * 1024,
  '1MB': 1024 * 1024,
  '16MB': 16 * 1024 * 1024,
};

Uint8List _randomBytes(int size) {
  final random = Random();
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

/// One in-channel round trip: base64-encode [size] random bytes, send via
/// [PearMethod.debugEcho], and time the full response.
Future<Duration> _benchmarkInChannel(PearRpc rpc, int size) async {
  final data = _randomBytes(size);
  final encoded = base64Encode(data);
  final stopwatch = Stopwatch()..start();
  final result =
      await rpc.call(PearMethod.debugEcho, {'data': encoded}, const Duration(seconds: 30))
          as Map;
  stopwatch.stop();
  final echoed = base64Decode(result['data'] as String);
  // Byte-for-byte, not just length -- catches a transport corrupting
  // content while preserving size (e.g. E4.4's historical frame-coalescing
  // bug), which a length-only check would miss.
  expect(echoed, equals(data),
      reason: 'debug.echo must return the full payload unmodified');
  return stopwatch.elapsed;
}

/// One file-path round trip: write [size] random bytes via
/// [PearMethod.bulkWriteFile] (E4.4), then read the file straight back from
/// disk -- the actual shape a real caller would use (see PearDrive's
/// planned "get returns bytes read from the worklet's own storage" API).
Future<Duration> _benchmarkFilePath(PearRpc rpc, int size) async {
  final data = _randomBytes(size);
  final encoded = base64Encode(data);
  final stopwatch = Stopwatch()..start();
  final result =
      await rpc.call(PearMethod.bulkWriteFile, {'data': encoded}, const Duration(seconds: 30))
          as Map;
  final path = result['path'] as String;
  final readBack = await File(path).readAsBytes();
  stopwatch.stop();
  expect(readBack, equals(data),
      reason: 'the file written via bulk.writeFile must contain the full payload, unmodified');
  return stopwatch.elapsed;
}

String _fmtThroughput(int bytes, Duration elapsed) {
  if (elapsed.inMicroseconds == 0) return 'n/a (too fast to measure)';
  final mbPerSec = (bytes / (1024 * 1024)) / (elapsed.inMicroseconds / 1e6);
  return '${mbPerSec.toStringAsFixed(2)} MB/s (${elapsed.inMilliseconds}ms)';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'E5.1 benchmark: in-channel vs file-path round trip for 1KB-16MB payloads',
      (tester) async {
    final pear = await Pear.start().timeout(const Duration(seconds: 8));
    // A second PearRpc sharing the same worklet -- safe because responses
    // are matched by per-instance request id, not by which PearRpc sent
    // the request (see PearRpc._generateId's doc): a response for an id
    // this instance never issued is silently ignored, not misdelivered to
    // Pear's own internal rpc. No attach.info handshake needed here either
    // -- unlike ordinary events, responses aren't nonce-gated.
    final rpc = PearRpc(pear.worklet);

    final results = <String, Map<String, Duration>>{};
    for (final entry in _sizes.entries) {
      final inChannel = await _benchmarkInChannel(rpc, entry.value);
      final filePath = await _benchmarkFilePath(rpc, entry.value);
      results[entry.key] = {'in-channel': inChannel, 'file-path': filePath};
    }

    // ignore: avoid_print
    print('=== E5.1 bulk-transport benchmark (${Platform.operatingSystem}) ===');
    for (final entry in results.entries) {
      final size = _sizes[entry.key]!;
      // ignore: avoid_print
      print('${entry.key.padRight(6)} '
          'in-channel: ${_fmtThroughput(size, entry.value['in-channel']!).padRight(28)} '
          'file-path: ${_fmtThroughput(size, entry.value['file-path']!)}');
    }

    await rpc.dispose();
    await pear.dispose();
  });
}
