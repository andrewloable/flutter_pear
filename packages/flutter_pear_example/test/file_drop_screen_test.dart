import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_pear/flutter_pear.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/rpc.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear_example/file_drop_screen.dart';
import 'package:flutter_pear_example/file_picker_channel.dart';
import 'package:flutter_pear_example/file_transfer_controller.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// One test peer's [FileTransferController], backed by a REAL
/// [PearDrive]/[PearSwarm] over a fake worklet -- same pattern
/// file_transfer_controller_test.dart uses, reused here so [FileDropBody]
/// can be widget-tested against a real controller without a real
/// `Pear`/`PearSwarm`/native platform channel.
class _Peer {
  _Peer._(this.rpc, this.worklet, this.controller, this.dir);

  final PearRpc rpc;
  final FakeBareWorklet worklet;
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
  final drive = await PearDrive.open(rpc, name: 'file-drop-$label');
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
  return _Peer._(rpc, worklet, controller, dir);
}

/// Polls [condition], REAL time, not the widget-test fake clock -- callers
/// must invoke this from inside `tester.runAsync(...)`, same as every other
/// genuinely-asynchronous (file I/O, RPC round trip) step in these tests:
/// `testWidgets`' default binding runs on a virtual clock where a bare
/// `Future.delayed` never actually elapses, which is exactly what hung
/// every test in this file before this fix (10-minute timeouts, not
/// assertion failures).
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

void main() {
  testWidgets('empty state: Send a file is the primary action, no cards',
      (tester) async {
    late Directory tempDir;
    late _Peer alice;
    await tester.runAsync(() async {
      tempDir =
          await Directory.systemTemp.createTemp('flutter_pear-body-test-');
      final hub = FakeSwarmHub();
      final topic = PearCrypto.unsafeTopicFromString('body-empty-test');
      alice = await _setUpPeer(hub, 'alice', topic, tempDir);
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileDropBody(
          controller: alice.controller,
          sending: false,
          onPickAndSend: () {},
          onOpen: (_) async {},
          onShare: (_) async {},
          debugLog: const [],
        ),
      ),
    ));

    expect(find.text('Send a file'), findsOneWidget);
    expect(find.text('No peers connected yet.'), findsOneWidget);

    await tester.runAsync(() async {
      await alice.dispose();
      await tempDir.delete(recursive: true);
    });
  });

  testWidgets(
      'a connected peer with no transfers yet shows "Nothing from this '
      'peer yet"', (tester) async {
    late Directory tempDir;
    late _Peer alice;
    late _Peer bob;
    await tester.runAsync(() async {
      tempDir =
          await Directory.systemTemp.createTemp('flutter_pear-body-test-');
      final hub = FakeSwarmHub();
      final topic = PearCrypto.unsafeTopicFromString('body-nothing-yet-test');
      alice = await _setUpPeer(hub, 'alice', topic, tempDir);
      bob = await _setUpPeer(hub, 'bob', topic, tempDir);
      await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileDropBody(
          controller: alice.controller,
          sending: false,
          onPickAndSend: () {},
          onOpen: (_) async {},
          onShare: (_) async {},
          debugLog: const [],
        ),
      ),
    ));
    await tester.pump();

    expect(find.textContaining('Peer '), findsOneWidget);
    expect(find.text('Nothing from this peer yet'), findsOneWidget);

    await tester.runAsync(() async {
      await alice.dispose();
      await bob.dispose();
      await tempDir.delete(recursive: true);
    });
  });

  testWidgets('a received card shows the filename and human-readable size',
      (tester) async {
    late Directory tempDir;
    late _Peer alice;
    late _Peer bob;
    await tester.runAsync(() async {
      tempDir =
          await Directory.systemTemp.createTemp('flutter_pear-body-test-');
      final hub = FakeSwarmHub();
      final topic = PearCrypto.unsafeTopicFromString('body-received-test');
      alice = await _setUpPeer(hub, 'alice', topic, tempDir);
      bob = await _setUpPeer(hub, 'bob', topic, tempDir);
      await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);

      final path = await _writeLocalFile(alice.dir, 'photo.png', 'x' * 2048);
      await alice.controller.send(PickedFile(path: path, name: 'photo.png'));
      await _waitUntil(() => _allCards(bob.controller).any((c) =>
          c.name == 'photo.png' && c.status == TransferStatus.received));
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileDropBody(
          controller: bob.controller,
          sending: false,
          onPickAndSend: () {},
          onOpen: (_) async {},
          onShare: (_) async {},
          debugLog: const [],
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('photo.png'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);
    expect(find.text('Received ✓'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);

    await tester.runAsync(() async {
      await alice.dispose();
      await bob.dispose();
      await tempDir.delete(recursive: true);
    });
  });

  testWidgets(
      'tapping Open on a received card fires onOpen with that card\'s '
      'receivedLocalPath', (tester) async {
    late Directory tempDir;
    late _Peer alice;
    late _Peer bob;
    await tester.runAsync(() async {
      tempDir =
          await Directory.systemTemp.createTemp('flutter_pear-body-test-');
      final hub = FakeSwarmHub();
      final topic = PearCrypto.unsafeTopicFromString('body-open-test');
      alice = await _setUpPeer(hub, 'alice', topic, tempDir);
      bob = await _setUpPeer(hub, 'bob', topic, tempDir);
      await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);

      final path = await _writeLocalFile(alice.dir, 'doc.pdf', 'contents');
      await alice.controller.send(PickedFile(path: path, name: 'doc.pdf'));
      await _waitUntil(() => _allCards(bob.controller).any((c) =>
          c.name == 'doc.pdf' && c.status == TransferStatus.received));
    });

    FileTransferCard? openedCard;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileDropBody(
          controller: bob.controller,
          sending: false,
          onPickAndSend: () {},
          onOpen: (card) async => openedCard = card,
          onShare: (_) async {},
          debugLog: const [],
        ),
      ),
    ));
    await tester.pump();

    await tester.tap(find.text('Open'));
    await tester.pump();

    final received = _allCards(bob.controller)
        .firstWhere((c) => c.name == 'doc.pdf' && c.status == TransferStatus.received);
    expect(openedCard, isNotNull);
    expect(openedCard!.name, 'doc.pdf');
    expect(openedCard!.receivedLocalPath, isNotNull);
    expect(openedCard!.receivedLocalPath, received.receivedLocalPath);

    await tester.runAsync(() async {
      await alice.dispose();
      await bob.dispose();
      await tempDir.delete(recursive: true);
    });
  });

  testWidgets('a failed send card shows a Retry action', (tester) async {
    late Directory tempDir;
    late _Peer alice;
    late _Peer bob;
    await tester.runAsync(() async {
      tempDir =
          await Directory.systemTemp.createTemp('flutter_pear-body-test-');
      final hub = FakeSwarmHub();
      final topic = PearCrypto.unsafeTopicFromString('body-failed-test');
      alice = await _setUpPeer(hub, 'alice', topic, tempDir);
      bob = await _setUpPeer(hub, 'bob', topic, tempDir);
      await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);

      final path = await _writeLocalFile(alice.dir, 'doc.pdf', 'payload');
      await alice.controller.send(PickedFile(path: path, name: 'doc.pdf'));
      // Sever alice's connection to bob before bob's ack can arrive -- same
      // disconnect pattern file_transfer_controller_test.dart uses.
      alice.worklet.disconnectFrom(bob.worklet);
      await _waitUntil(() => _allCards(alice.controller).any((c) =>
          c.name == 'doc.pdf' && c.status == TransferStatus.failed));
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FileDropBody(
          controller: alice.controller,
          sending: false,
          onPickAndSend: () {},
          onOpen: (_) async {},
          onShare: (_) async {},
          debugLog: const [],
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('doc.pdf'), findsOneWidget);
    expect(find.text('Failed -- not delivered'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.runAsync(() async {
      await alice.dispose();
      await bob.dispose();
      await tempDir.delete(recursive: true);
    });
  });

  test('no "Check for files" text anywhere in the example app source', () {
    final libDir = Directory('lib');
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final content = entity.readAsStringSync();
      expect(content.contains('Check for files'), isFalse,
          reason: '${entity.path} still contains the retired manual '
              '"Check for files" affordance -- receive is automatic now');
    }
  });
}
