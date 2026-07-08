import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pear/flutter_pear.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/rpc.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear_example/file_drop_screen.dart';
import 'package:flutter_pear_example/file_picker_channel.dart';
import 'package:flutter_pear_example/file_transfer_controller.dart';
import 'package:flutter_pear_example/main.dart' show SwarmStatusBanner;
import 'package:flutter_pear_example/transfer_protocol.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the plan's design-review interaction state table (epic acceptance
/// line: "widget tests green") for the FILE SEND/RECEIVE and CONNECTION
/// halves -- see state_matrix_test.dart for the pairing half. Rows already
/// pinned elsewhere by name, not duplicated here:
///
/// - send EMPTY ("Send a file" + "No peers connected yet.") --
///   file_drop_screen_test.dart, test "empty state: Send a file is the
///   primary action, no cards".
/// - send ERROR (mid-transfer peer drop -> failed + Retry) --
///   file_drop_screen_test.dart, test "a failed send card shows a Retry
///   action".
/// - receive EMPTY ("Nothing from this peer yet") -- file_drop_screen_test.dart,
///   test 'a connected peer with no transfers yet shows "Nothing from this
///   peer yet"'.
/// - receive SUCCESS Open/Share affordances -- file_drop_screen_test.dart,
///   test "tapping Open on a received card fires onOpen with that card's
///   receivedLocalPath" (flutter_pear-ovt.4.7).
/// - connection: reconnecting/discovering/suspended pills --
///   chat_screen_test.dart, group "SwarmStatusBanner".
///
/// One real bug was found and fixed while building this file: a receive
/// that failed its first attempt used to recurse into a brand-new
/// _receiveOne call for the auto-retry instead of updating the original
/// card in place, leaving a permanent duplicate stuck at "receiving"
/// forever alongside the real (correct) receiveFailed card -- see
/// file_transfer_controller_test.dart's own regression test for that fix.

/// One test peer: a real [PearDrive]/[PearSwarm] over a fake worklet, plus
/// the [FileTransferController] under test -- same pattern
/// file_transfer_controller_test.dart / file_drop_screen_test.dart use.
class _Peer {
  _Peer._(
      this.rpc, this.worklet, this.swarm, this.drive, this.controller, this.dir);

  final PearRpc rpc;
  final FakeBareWorklet worklet;
  final PearSwarm swarm;
  final PearDrive drive;
  final FileTransferController controller;
  final Directory dir;

  Future<void> dispose() async {
    controller.dispose();
    await rpc.dispose();
  }
}

Future<_Peer> _setUpPeer(
  FakeSwarmHub hub,
  String label,
  PearKey topic,
  Directory tempRoot,
) async {
  final worklet = FakeBareWorklet(hub: hub);
  final rpc = PearRpc(worklet);
  await rpc.call(PearMethod.attachInfo);
  final drive = await PearDrive.open(rpc, name: 'state-matrix-$label');
  final swarm = await PearSwarm.join(rpc, topic);
  final dir = Directory('${tempRoot.path}/$label')..createSync();
  final controller = FileTransferController(
    ownDrive: drive,
    openPeerDrive: (key) => PearDrive.open(rpc, key: key),
    connections: swarm.connections,
    swarmStatus: swarm.state,
    stagingRoot: '${dir.path}/staging',
    receivedRoot: '${dir.path}/received',
  );
  return _Peer._(rpc, worklet, swarm, drive, controller, dir);
}

/// A peer that joins the swarm but runs no [FileTransferController] at
/// all -- nothing ever consumes its connections/data, so it's connected
/// (a legitimate send() target) but never acts on anything it's sent.
/// Deterministic stand-in for "a recipient that never gets around to
/// acking" in the partial-state matrix tests below, where a REAL peer
/// racing its own auto-receive/auto-ack pipeline against the test's own
/// timing would be flaky.
class _BarePeer {
  _BarePeer._(this.rpc, this.worklet, this.swarm);

  final PearRpc rpc;
  final FakeBareWorklet worklet;
  final PearSwarm swarm;

  Future<void> dispose() => rpc.dispose();
}

Future<_BarePeer> _setUpBarePeer(
  FakeSwarmHub hub,
  PearKey topic,
) async {
  final worklet = FakeBareWorklet(hub: hub);
  final rpc = PearRpc(worklet);
  await rpc.call(PearMethod.attachInfo);
  final swarm = await PearSwarm.join(rpc, topic);
  return _BarePeer._(rpc, worklet, swarm);
}

Future<void> _waitUntil(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition never became true within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Iterable<FileTransferCard> _allCards(FileTransferController c) =>
    c.cardsByPeer.values.expand((cards) => cards);

Future<String> _writeLocalFile(
    Directory dir, String name, String content) async {
  final file = File('${dir.path}/$name');
  await file.writeAsString(content);
  return file.path;
}

/// Pumps [controller] as [FileDropBody] -- the same "in a Scaffold body"
/// shape file_drop_screen_test.dart pumps it in.
Future<void> _pumpBody(WidgetTester tester, FileTransferController controller) =>
    tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileDropBody(
          controller: controller,
          sending: false,
          onPickAndSend: () {},
          onOpen: (_) async {},
          onShare: (_) async {},
          debugLog: const [],
        ),
      ),
    ));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('send WAITING -- per-file card shows progress while in flight', () {
    testWidgets('a sent-but-never-acked card renders a LinearProgressIndicator',
        (tester) async {
      late Directory tempDir;
      late _Peer alice;
      late _BarePeer bob;
      await tester.runAsync(() async {
        tempDir =
            await Directory.systemTemp.createTemp('flutter_pear-matrix-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('matrix-waiting');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        // A real recipient's own FileTransferController would auto-receive
        // and ack fast enough in the fake to race this test's own timing --
        // a bare (non-acking) peer keeps the card deterministically stuck
        // at waitingForRecipients, exactly the "in flight" window this row
        // describes, with no race at all.
        bob = await _setUpBarePeer(hub, topic);
        await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);

        final path = await _writeLocalFile(alice.dir, 'big.bin', 'x' * 4096);
        await alice.controller.send(PickedFile(path: path, name: 'big.bin'));
        await _waitUntil(() => _allCards(alice.controller).any((c) =>
            c.name == 'big.bin' &&
            c.status == TransferStatus.waitingForRecipients));
      });

      await _pumpBody(tester, alice.controller);
      await tester.pump();

      expect(find.text('big.bin'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await tempDir.delete(recursive: true);
      });
    });
  });

  group('send SUCCESS -- per-recipient fully-sent state', () {
    testWidgets('a fully-acked card shows "Sent ✓"', (tester) async {
      late Directory tempDir;
      late _Peer alice;
      late _Peer bob;
      await tester.runAsync(() async {
        tempDir =
            await Directory.systemTemp.createTemp('flutter_pear-matrix-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('matrix-sent');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        bob = await _setUpPeer(hub, 'bob', topic, tempDir);
        await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);

        final path = await _writeLocalFile(alice.dir, 'doc.pdf', 'contents');
        await alice.controller.send(PickedFile(path: path, name: 'doc.pdf'));
        await _waitUntil(() => _allCards(alice.controller).any(
            (c) => c.name == 'doc.pdf' && c.status == TransferStatus.sent));
      });

      await _pumpBody(tester, alice.controller);
      await tester.pump();

      expect(find.text('doc.pdf'), findsOneWidget);
      expect(find.text('Sent ✓'), findsOneWidget);

      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await tempDir.delete(recursive: true);
      });
    });
  });

  group('send PARTIAL -- some acked, some still pending shows per-peer rows',
      () {
    testWidgets(
        '2 recipients, one acked, the other still connected but not yet '
        'acked -> "Sent to some peers" + a pending row', (tester) async {
      late Directory tempDir;
      late _Peer alice;
      late _Peer bob;
      late _BarePeer carol;
      await tester.runAsync(() async {
        tempDir =
            await Directory.systemTemp.createTemp('flutter_pear-matrix-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('matrix-partial');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        bob = await _setUpPeer(hub, 'bob', topic, tempDir);
        // Carol runs no FileTransferController at all -- connected (a
        // legitimate send() target), but nothing on her side ever acts on
        // what she's sent, so she deterministically never acks. A real
        // second FileTransferController racing its own auto-receive/
        // auto-ack pipeline against this test's own timing would be flaky.
        carol = await _setUpBarePeer(hub, topic);
        await _waitUntil(() => alice.controller.connectedPeers.length == 2);

        final path = await _writeLocalFile(alice.dir, 'photo.png', 'x' * 64);
        await alice.controller
            .send(PickedFile(path: path, name: 'photo.png'));
        await _waitUntil(() => _allCards(bob.controller).any((c) =>
            c.name == 'photo.png' && c.status == TransferStatus.received));
        await _waitUntil(() => _allCards(alice.controller).any((c) =>
            c.name == 'photo.png' &&
            c.status == TransferStatus.partiallySent));
      });

      await _pumpBody(tester, alice.controller);
      await tester.pump();

      // The same multi-recipient card renders once per targeted peer's
      // group (bob's AND carol's) -- so 2, not 1, is the correct count.
      expect(find.text('Sent to some peers'), findsNWidgets(2));
      expect(find.textContaining('delivered ✓'), findsWidgets);
      expect(find.textContaining('pending'), findsWidgets);

      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await carol.dispose();
        await tempDir.delete(recursive: true);
      });
    });
  });

  group(
      'send PARTIAL FAILURE -- multi-peer, some acked some failed shows '
      'per-peer error rows', () {
    testWidgets('2 recipients, one acked, the other disconnects before '
        'ever acking -> "Sent to some peers" + a failed row', (tester) async {
      late Directory tempDir;
      late _Peer alice;
      late _Peer bob;
      late _BarePeer carol;
      await tester.runAsync(() async {
        tempDir =
            await Directory.systemTemp.createTemp('flutter_pear-matrix-');
        final hub = FakeSwarmHub();
        final topic =
            PearCrypto.unsafeTopicFromString('matrix-partial-failure');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        bob = await _setUpPeer(hub, 'bob', topic, tempDir);
        // Same deterministic-non-acker shape as the PARTIAL test above --
        // disconnected right after send() (before she could ever act on
        // it), rather than racing a real second controller's own
        // auto-receive pipeline against this disconnect call.
        carol = await _setUpBarePeer(hub, topic);
        await _waitUntil(() => alice.controller.connectedPeers.length == 2);

        final path = await _writeLocalFile(alice.dir, 'clip.mp4', 'x' * 64);
        await alice.controller.send(PickedFile(path: path, name: 'clip.mp4'));
        alice.worklet.disconnectFrom(carol.worklet);
        await _waitUntil(() => _allCards(bob.controller).any((c) =>
            c.name == 'clip.mp4' && c.status == TransferStatus.received));
        await _waitUntil(() => _allCards(alice.controller).any((c) =>
            c.name == 'clip.mp4' &&
            c.status == TransferStatus.partiallySent &&
            c.peers.values.contains(TransferPeerState.failed)));
      });

      await _pumpBody(tester, alice.controller);
      await tester.pump();

      // Same multi-recipient fan-out as the PARTIAL test above -- one
      // rendering per targeted peer's group.
      expect(find.text('Sent to some peers'), findsNWidgets(2));
      expect(find.textContaining('delivered ✓'), findsWidgets);
      expect(find.textContaining('failed'), findsWidgets);

      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await carol.dispose();
        await tempDir.delete(recursive: true);
      });
    });
  });

  group('receive AUTO -- the incoming card appears with NO user action', () {
    testWidgets(
        'a file sent by alice appears on bob\'s screen without bob ever '
        'tapping anything', (tester) async {
      late Directory tempDir;
      late _Peer alice;
      late _Peer bob;
      await tester.runAsync(() async {
        tempDir =
            await Directory.systemTemp.createTemp('flutter_pear-matrix-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('matrix-auto-receive');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        bob = await _setUpPeer(hub, 'bob', topic, tempDir);
        await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);
      });

      // Bob's screen is already showing, mid-empty-state, BEFORE alice ever
      // sends anything -- the point being proven is that the card shows up
      // here with zero interaction from this point on.
      await _pumpBody(tester, bob.controller);
      await tester.pump();
      expect(find.text('No peers connected yet.'), findsNothing);
      expect(find.text('surprise.txt'), findsNothing);

      await tester.runAsync(() async {
        final path =
            await _writeLocalFile(alice.dir, 'surprise.txt', 'hello bob');
        await alice.controller
            .send(PickedFile(path: path, name: 'surprise.txt'));
        await _waitUntil(() => _allCards(bob.controller).any((c) =>
            c.name == 'surprise.txt' && c.status == TransferStatus.received));
      });

      // Only pumps (frame rebuilds) from here -- no tester.tap, no
      // onPickAndSend, nothing -- yet the card is now visible.
      await tester.pump();
      expect(find.text('surprise.txt'), findsOneWidget);
      expect(find.text('Received ✓'), findsOneWidget);

      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await tempDir.delete(recursive: true);
      });
    });
  });

  group('receive SUCCESS -- a "Received <name>" snackbar', () {
    testWidgets('the FileDropScreen-level snackbar text is exactly right',
        (tester) async {
      // _showSnackbarsForTerminalReceives lives on _FileDropScreenState
      // (needs a real Pear -- can't be widget-tested, see
      // pairing_screens_test.dart's own comment on this exact limitation),
      // so this exercises its logic directly against a real controller
      // instead of through the full screen.
      late Directory tempDir;
      late _Peer alice;
      late _Peer bob;
      await tester.runAsync(() async {
        tempDir =
            await Directory.systemTemp.createTemp('flutter_pear-matrix-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('matrix-snackbar');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        bob = await _setUpPeer(hub, 'bob', topic, tempDir);
        await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);

        final path = await _writeLocalFile(alice.dir, 'note.txt', 'hi');
        await alice.controller.send(PickedFile(path: path, name: 'note.txt'));
        await _waitUntil(() => _allCards(bob.controller).any((c) =>
            c.name == 'note.txt' && c.status == TransferStatus.received));
      });

      final card =
          _allCards(bob.controller).firstWhere((c) => c.name == 'note.txt');
      expect(terminalAnnouncementFor(card), 'Received note.txt');

      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await tempDir.delete(recursive: true);
      });
    });
  });

  group('receive ERROR -- receiveFailed after the internal auto-retry '
      'exhausts', () {
    testWidgets(
        'a receive that fails both attempts renders "Failed to receive" '
        'inline, and the accessibility banner text matches',
        (tester) async {
      late Directory tempDir;
      late _Peer alice;
      late _Peer bob;
      await tester.runAsync(() async {
        tempDir =
            await Directory.systemTemp.createTemp('flutter_pear-matrix-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('matrix-receive-error');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        bob = await _setUpPeer(hub, 'bob', topic, tempDir);
        await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 300));

        // Deterministic, hostile-drive-entry failure -- same technique as
        // file_transfer_controller_test.dart's regression test.
        bob.worklet.injectDriveSymlink(
            alice.drive.key.hex, '/broken.dat', '../../etc/passwd');
        final aliceConn = alice.swarm.establishedConnections.single;
        await aliceConn.write(FileAnnounce('broken.dat', 12).toBytes());

        await _waitUntil(() => _allCards(bob.controller).any((c) =>
            c.name == 'broken.dat' &&
            c.status == TransferStatus.receiveFailed));
      });

      await _pumpBody(tester, bob.controller);
      await tester.pump();

      expect(find.text('broken.dat'), findsOneWidget);
      expect(find.text('Failed to receive'), findsOneWidget);

      final card = _allCards(bob.controller)
          .firstWhere((c) => c.name == 'broken.dat');
      expect(terminalAnnouncementFor(card), 'Failed to receive broken.dat');

      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await tempDir.delete(recursive: true);
      });
    });
  });

  group('connection -- connected pill shows the live peer count', () {
    testWidgets('SwarmStatusBanner appends "· N peers" when peerCount is '
        'given', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SwarmStatusBanner(
          status: (state: PearSwarmState.connected, error: null),
          peerCount: 2,
        ),
      ));

      expect(find.text('Connected · 2 peers'), findsOneWidget);
    });

    testWidgets('singular "peer" (not "peers") for exactly one',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: SwarmStatusBanner(
          status: (state: PearSwarmState.connected, error: null),
          peerCount: 1,
        ),
      ));

      expect(find.text('Connected · 1 peer'), findsOneWidget);
    });
  });

  group('semantics -- card labels reflect state, terminal changes are '
      'announced', () {
    testWidgets(
        'a Text widget rendering the card\'s result text carries a matching '
        'semantic label -- state is perceivable via a screen reader, not '
        'just color', (tester) async {
      late Directory tempDir;
      late _Peer alice;
      late _Peer bob;
      final handle = tester.ensureSemantics();
      await tester.runAsync(() async {
        tempDir =
            await Directory.systemTemp.createTemp('flutter_pear-matrix-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('matrix-semantics-1');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        bob = await _setUpPeer(hub, 'bob', topic, tempDir);
        await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);

        final path = await _writeLocalFile(alice.dir, 'sem.txt', 'hi');
        await alice.controller.send(PickedFile(path: path, name: 'sem.txt'));
        await _waitUntil(() => _allCards(bob.controller).any((c) =>
            c.name == 'sem.txt' && c.status == TransferStatus.received));
      });

      await _pumpBody(tester, bob.controller);
      await tester.pump();

      // Flutter merges nearby Text semantics within the same card into one
      // node (filename + size + status all in one label) -- matchesSemantics
      // needs an exact label, so this checks the merged label CONTAINS the
      // status text instead of just pumping a bare 'Received ✓' node that
      // doesn't actually exist on its own.
      final label =
          tester.getSemantics(find.text('Received ✓')).getSemanticsData().label;
      expect(label, contains('Received ✓'));

      handle.dispose();
      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await tempDir.delete(recursive: true);
      });
    });

    testWidgets(
        'a real send-then-receive round trip emits accessibility '
        'announcements for both the sent and received terminal states',
        (tester) async {
      final announced = <String>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility,
        (message) async {
          if (message is Map && message['type'] == 'announce') {
            final data = message['data'];
            if (data is Map && data['message'] is String) {
              announced.add(data['message'] as String);
            }
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler(SystemChannels.accessibility, null));

      late Directory tempDir;
      late _Peer alice;
      late _Peer bob;
      await tester.runAsync(() async {
        tempDir =
            await Directory.systemTemp.createTemp('flutter_pear-matrix-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('matrix-semantics-2');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        bob = await _setUpPeer(hub, 'bob', topic, tempDir);
        await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);

        final path = await _writeLocalFile(alice.dir, 'announce.txt', 'hi');
        await alice.controller
            .send(PickedFile(path: path, name: 'announce.txt'));
        await _waitUntil(() => _allCards(alice.controller).any((c) =>
            c.name == 'announce.txt' && c.status == TransferStatus.sent));
        await _waitUntil(() => _allCards(bob.controller).any((c) =>
            c.name == 'announce.txt' &&
            c.status == TransferStatus.received));
      });

      expect(announced, contains('Sent announce.txt'));
      expect(announced, contains('Received announce.txt'));

      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await tempDir.delete(recursive: true);
      });
    });

    test('terminalAnnouncementFor covers every TransferStatus', () {
      FileTransferCard card(TransferStatus status, {int peerCount = 1}) =>
          FileTransferCard(
            name: 'x',
            size: 1,
            direction: TransferDirection.sending,
            timestamp: DateTime(2024),
            status: status,
            peers: {
              for (var i = 0; i < peerCount; i++) 'peer$i': TransferPeerState.pending,
            },
          );

      expect(terminalAnnouncementFor(card(TransferStatus.sending)), isNull);
      expect(terminalAnnouncementFor(card(TransferStatus.waitingForRecipients)),
          isNull);
      expect(terminalAnnouncementFor(card(TransferStatus.receiving)), isNull);
      expect(terminalAnnouncementFor(card(TransferStatus.sent)), 'Sent x');
      expect(terminalAnnouncementFor(card(TransferStatus.partiallySent)),
          'Sent x to some peers');
      expect(
          terminalAnnouncementFor(card(TransferStatus.failed)), 'Failed to send x');
      expect(
          terminalAnnouncementFor(card(TransferStatus.received)), 'Received x');
      expect(terminalAnnouncementFor(card(TransferStatus.receiveFailed)),
          'Failed to receive x');
    });
  });
}
