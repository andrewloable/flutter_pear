// Real device/emulator integration test for PearDrive (flutter_pear-g28):
// exercises the wrapper's REAL public Dart API (lib/src/drive.dart) against
// the REAL pear-end worklet, over a REAL Hyperswarm connection, talking to a
// REAL desktop peer process -- tool/peer.js's `--drive` mode, already
// validated process-to-process by tool/peer.check.js's checkDriveRoundTrip.
// Unlike drive_test.dart's FakeBareWorklet-driven unit tests (which never
// leave flutter_pear_test's in-memory fake), every byte here crosses a real
// Bare worklet, a real Android platform channel, the real
// Hyperswarm/Hyperdrive wire protocol, and a real network hop to a real Node
// process on the host machine.
//
// Mirrors checkDriveRoundTrip's own ALREADY-PROVEN direction exactly, rather
// than inventing an untested one (see peer.js's own header comment on
// --drive mode): the desktop peer -- driven by `--put <file>`, exactly like
// checkDriveRoundTrip's own sender -- is the side that PUTS. This phone-side
// test is the RECEIVER: it learns the desktop's drive key over the
// 'pear-connection-data' Protomux channel (the exact same handshake
// lib/file_drop_screen.dart's real "Check for files" flow uses --
// encodeDriveKeyAnnouncement/decodeDriveKeyAnnouncement there is byte-for-
// byte the same wire shape peer.js's runDrive emits: utf8 of the drive key's
// hex), opens that drive BY KEY, replicates it, and mirrors it to a local
// directory with [PearDrive.mirrorToDisk] -- the same call
// file_drop_screen.dart's `_checkForFiles` makes.
//
// Deliberately a SMALL payload (a couple dozen bytes of plain text), not the
// 5MB checkDriveRoundTrip uses for its own desktop-to-desktop check, and
// nowhere near a large multi-MB/64MB+ transfer -- this test's only job is
// proving the phone-side PearDrive.replicate()/mirrorToDisk() path is
// byte-exact against a real peer. The large-transfer/no-OOM/no-full-file-
// JSON-frame property (flutter_pear-doi's own 2vz.5 note: ">=64MB...
// proving no OOM and no full-file JSON frame") is a DIFFERENT, heavier
// validation deliberately OUT OF SCOPE here -- see
// bulk_transport_benchmark_test.dart for throughput/size benchmarking, and
// PearDrive's own class doc for why file-path (never in-memory bytes) is
// what makes a large transfer safe in the first place. Don't fold that
// heavier check into this one.
//
// This test cannot spawn or drive the desktop peer itself -- there is no
// path from device-side Dart to a HOST-machine process (same limit
// bee_transport_test.dart's own header comment describes). The desktop peer
// must already be running, on the SAME topic, with a file matching this
// file's `_kFileName`/`_kContent` constants exactly, before this test's own
// join() call:
//   node tool/peer.js --drive --put <path/to/drive-transport-payload.txt> \
//     --topic <topic> --timeout <seconds>
//
// Run: flutter test integration_test/drive_transport_test.dart -d <device> \
//   --dart-define=PEER_TOPIC=<topic matching the desktop peer's --topic>
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Must match, byte-for-byte, the file the desktop peer.js --drive --put
// process is given -- both its basename (peer.js's runDrive derives the
// drive's virtual path as `/${path.basename(args.put)}`) and its content.
const _kFileName = 'drive-transport-payload.txt';
const _kContent = 'flutter_pear-g28 drive-transport integration test payload\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'PearDrive mirrors a real desktop peer\'s put() file over a real '
    'Hyperswarm connection, byte-identical (flutter_pear-g28)',
    (tester) async {
      // Same derivation as PearCrypto.unsafeTopicFromString (SHA-256 of the
      // UTF-8 string) -- overridable via --dart-define so the host-side
      // orchestration can pick a fresh, randomized topic per run. See
      // peer.js's own header comment: a FIXED topic on the real, public DHT
      // is a real, empirically-hit source of flakiness/collision.
      const topicName = String.fromEnvironment('PEER_TOPIC',
          defaultValue: 'flutter-pear-drive-transport-test');

      final pear = await Pear.start().timeout(const Duration(seconds: 20));
      addTearDown(pear.dispose);

      final topic = PearCrypto.unsafeTopicFromString(topicName);
      final swarm = await pear.join(topic);
      addTearDown(swarm.leave);

      // Real, public DHT discovery -- the phone side has no bootstrap
      // override (pear-end's own `new Hyperswarm()` takes none, unlike
      // peer.js's --bootstrap), so this can't be routed onto
      // peer.check.js's private local testnet. Same generous bound as
      // bee_transport_test.dart's own connection wait, for the same reason.
      final connection =
          await swarm.connections.first.timeout(const Duration(seconds: 90));
      // ignore: avoid_print
      print('drive-transport: connected to '
          '${connection.remotePublicKey.hex.substring(0, 8)}…');

      // The desktop peer.js --drive process announces its OWN drive key
      // over this SAME 'pear-connection-data' Protomux channel
      // PearConnection.data surfaces -- unconditionally, the instant it
      // connects (see peer.js's runDrive: `message.send(...)` fires right
      // after `channel.open()`) -- so this is the very first payload this
      // connection ever delivers. Subscribing here, in the same synchronous
      // continuation as the `connections.first` await above resolving,
      // matches PearSwarm.state's own documented ordering guarantee.
      final keyBytes =
          await connection.data.first.timeout(const Duration(seconds: 15));
      final desktopDriveKey = PearKey.fromHex(utf8.decode(keyBytes));
      // ignore: avoid_print
      print('drive-transport: learned desktop drive key '
          '${desktopDriveKey.hex}');

      // Opened BY KEY, not by name -- this side never owns the writer key
      // for this drive, exactly matching drive_test.dart's own "two peers
      // replicate a drive" fake test (the receiving side always attaches by
      // key) and file_drop_screen.dart's own _onPeerDriveKey.
      final drive = await pear.drive(key: desktopDriveKey);

      // Both sides must call replicate() for data to flow (see drive.dart's
      // own doc + drive_test.dart's "replicate() called by only ONE side
      // never syncs data" test) -- the desktop side already began
      // replicating ITS OWN drive the instant it connected (peer.js's
      // runDrive chains core-then-blobs replication unconditionally, before
      // any key exchange), so this call is this side's half of that pair. A
      // single call here -- PearDrive.replicate chains core AND blobs
      // replication internally on the pear-end side (see index.js's
      // DRIVE_REPLICATE handler), unlike peer.js's own two explicit
      // replicate() calls.
      await drive.replicate(connection);

      final mirrorDir = await Directory.systemTemp
          .createTemp('flutter_pear-drive-transport-');
      addTearDown(() => mirrorDir.delete(recursive: true));

      // The desktop peer already --put its file BEFORE ever joining the
      // swarm (peer.js's runDrive streams --put into the drive before
      // `swarm.on('connection', ...)` is even wired) -- the same
      // "content exists before replication starts" shape as drive_test.dart's
      // own "before.txt" fake test. Unlike bee_transport_test.dart's
      // watch-for-a-FUTURE-put, there is no live event to wait for here:
      // mirrorToDisk's own mirror-drive diff/copy naturally waits on
      // whatever Hyperdrive blocks haven't replicated in yet (the same
      // wait-by-default block semantics peer.js's own --store
      // `core.get(i)` relies on), so a single call is normally enough on a
      // healthy connection -- retried a few times anyway, purely as
      // insurance against real-network timing variance a single fixed 10s
      // RPC timeout (PearRpcDefaults.callTimeout, which
      // PearDrive.mirrorToDisk doesn't let a caller override) might not
      // always clear on a slow real-DHT-discovered path. mirrorToDisk is
      // idempotent (mirror-drive only ever copies what's actually changed),
      // so retrying after a timeout is safe.
      PearDriveMirrorResult? result;
      for (var attempt = 1; attempt <= 6; attempt++) {
        try {
          result = await drive.mirrorToDisk(mirrorDir.path);
          break;
        } on PearException catch (e) {
          if (attempt == 6) rethrow;
          // ignore: avoid_print
          print('drive-transport: mirrorToDisk attempt $attempt failed '
              '($e), retrying…');
        }
      }
      // ignore: avoid_print
      print('drive-transport: mirrorToDisk result: $result');

      final mirroredFile = File('${mirrorDir.path}/$_kFileName');
      expect(await mirroredFile.exists(), isTrue,
          reason: "mirrorToDisk() must have written the desktop peer's "
              '--put file at the expected path');
      final mirroredContent = await mirroredFile.readAsString();
      expect(mirroredContent, _kContent,
          reason: 'the mirrored file must be byte-identical to the one the '
              'desktop peer --put');
      // ignore: avoid_print
      print('drive-transport: observed real cross-runtime file, '
          'byte-identical');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
