import 'dart:io';
import 'dart:isolate';

/// Desktop CLI peer (E7.3, X7) -- a second peer for the chat demo that runs
/// on a laptop instead of a second phone (the one-phone dev's path; an
/// emulator's NAT often breaks UDP hole-punching a real second phone
/// wouldn't hit), and a scriptable peer for CI.
///
/// ```bash
/// dart run flutter_pear_example:peer --topic my-secret-room
/// ```
///
/// Thin wrapper only: the actual Hyperswarm/Protomux logic lives in
/// `tool/peer.js`, run as a plain Node process -- see that file's
/// own doc for why this is Node, not a Bare worklet. Exits with the same
/// code the JS side does, including nonzero on a connect timeout, so this
/// is usable as a scripted assertion in CI.
Future<void> main(List<String> args) async {
  // `Platform.script` points at wherever `dart run` staged/snapshotted this
  // file (e.g. `.dart_tool/pub/bin/...` under the `flutter_pear_example:peer`
  // invocation form), not this package's actual source tree -- resolving
  // `package:flutter_pear_example/` instead finds `lib/` via
  // `.dart_tool/package_config.json`, which is invocation-independent.
  final libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:flutter_pear_example/'),
  );
  if (libUri == null) {
    stderr.writeln(
      'Could not resolve package:flutter_pear_example/ -- this needs a '
      '.dart_tool/package_config.json (e.g. `dart run` or `flutter run`), '
      'not a standalone `dart compile exe` binary.',
    );
    exit(1);
  }
  final packageRoot = Directory.fromUri(libUri).parent;
  final peerJs = File('${packageRoot.path}/tool/peer.js').absolute.path;

  final process = await Process.start(
    'node',
    [peerJs, ...args],
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
