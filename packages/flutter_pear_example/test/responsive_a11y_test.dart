import 'dart:io';

import 'package:flutter/foundation.dart';
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
import 'package:flutter_pear_example/main.dart';
import 'package:flutter_pear_example/pairing_screens.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// Design review fix 8 / locked decision TD-D2 (final gate): a minimal-but-
/// real accessibility and responsive floor for the demo app -- NOT a
/// design-system project (full WCAG, Dynamic Type plumbing, and the
/// tablet/split-screen matrix are explicitly out of scope). Covers: no
/// overflow at 2x text scale on a small phone, tap-target/labeled-target
/// guidelines on the touched screens.

/// A small phone -- roughly an iPhone SE's logical size, deliberately
/// smaller than any device this app is likely to actually ship on, so a
/// passing test here has real margin.
const _smallPhoneLogicalSize = Size(320, 568);

/// Pumps [child] at [_smallPhoneLogicalSize] and [textScale] -- shared by
/// every large-text-pass case below.
Future<void> _pumpAtScale(
  WidgetTester tester,
  Widget child, {
  double textScale = 2.0,
}) async {
  tester.view.physicalSize = _smallPhoneLogicalSize * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData.fromView(tester.view)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child,
    ),
  );
}

/// One test peer -- same pattern as file_drop_screen_test.dart /
/// state_matrix_file_transfer_test.dart.
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
  final drive = await PearDrive.open(rpc, name: 'a11y-$label');
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

Future<String> _writeLocalFile(Directory dir, String name, String content) async {
  final file = File('${dir.path}/$name');
  await file.writeAsString(content);
  return file.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const qrChannel = MethodChannel('flutter_pear_example/qr_scanner');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(qrChannel, (call) async {
      if (call.method == 'checkCameraPermission') return 'granted';
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(qrChannel, null));

  group('large-text pass -- no overflow at 2x text scale on a small phone', () {
    testWidgets('home screen', (tester) async {
      await _pumpAtScale(tester, const ChatApp());
      expect(tester.takeException(), isNull);
    });

    testWidgets('JoinRoomScreen (Android ordering)', (tester) async {
      await _pumpAtScale(
          tester, const MaterialApp(home: JoinRoomScreen()));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('JoinRoomScreen (iOS paste-first ordering)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await _pumpAtScale(
            tester, const MaterialApp(home: JoinRoomScreen()));
        await tester.pump();
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('InviteCard (StartRoomScreen\'s invite display)',
        (tester) async {
      // Real usage (StartRoomScreen.build) always wraps this in a
      // SingleChildScrollView -- matched here, since a bare InviteCard
      // isn't scrollable on its own and a tall-content vertical "overflow"
      // in that scenario would just be a test-setup artifact, not a real
      // bug. What this test actually stress-tests is the QR's WIDTH at a
      // narrow, 2x-scaled viewport.
      await _pumpAtScale(
        tester,
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: InviteCard(
                code:
                    'dGhpcy1pcy1hLWRlbGliZXJhdGVseS1sb25nLWludml0ZS1jb2RlLXRvLXN0cmVzcy10ZXN0LXdyYXBwaW5nLWFuZC1lbGxpcHNpcy1oYW5kbGluZw==',
                pairing: false,
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('file-drop room (empty state)', (tester) async {
      late Directory tempDir;
      late _Peer alice;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('flutter_pear-a11y-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('a11y-empty');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
      });

      await _pumpAtScale(
        tester,
        MaterialApp(
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
        ),
      );
      expect(tester.takeException(), isNull);

      await tester.runAsync(() async {
        await alice.dispose();
        await tempDir.delete(recursive: true);
      });
    });

    testWidgets(
        'file-drop room with a long filename, connected peer, and a '
        'received card', (tester) async {
      late Directory tempDir;
      late _Peer alice;
      late _Peer bob;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('flutter_pear-a11y-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('a11y-longname');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        bob = await _setUpPeer(hub, 'bob', topic, tempDir);
        await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);

        const longName =
            'a-deliberately-extremely-long-filename-to-stress-test-ellipsis-handling-in-the-file-card-row.pdf';
        final path = await _writeLocalFile(alice.dir, longName, 'x' * 64);
        await alice.controller.send(PickedFile(path: path, name: longName));
        await _waitUntil(() => _allCards(bob.controller).any(
            (c) => c.name == longName && c.status == TransferStatus.received));
      });

      await _pumpAtScale(
        tester,
        MaterialApp(
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
        ),
      );
      expect(tester.takeException(), isNull);

      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await tempDir.delete(recursive: true);
      });
    });
  });

  group('touch targets + labeling guidelines', () {
    testWidgets('home screen meets tap-target and labeled-target guidelines',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const ChatApp());
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets(
        'JoinRoomScreen meets tap-target and labeled-target guidelines',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const MaterialApp(home: JoinRoomScreen()));
      await tester.pump();
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets(
        'InviteCard (copy/share icon buttons) meets tap-target and '
        'labeled-target guidelines', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: InviteCard(code: 'dGVzdA==', pairing: false),
        ),
      ));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });

    testWidgets(
        'a received card\'s Open/Share buttons meet tap-target and '
        'labeled-target guidelines', (tester) async {
      late Directory tempDir;
      late _Peer alice;
      late _Peer bob;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('flutter_pear-a11y-');
        final hub = FakeSwarmHub();
        final topic = PearCrypto.unsafeTopicFromString('a11y-guideline');
        alice = await _setUpPeer(hub, 'alice', topic, tempDir);
        bob = await _setUpPeer(hub, 'bob', topic, tempDir);
        await _waitUntil(() => alice.controller.connectedPeers.isNotEmpty);

        final path = await _writeLocalFile(alice.dir, 'photo.png', 'x' * 32);
        await alice.controller.send(PickedFile(path: path, name: 'photo.png'));
        await _waitUntil(() => _allCards(bob.controller).any((c) =>
            c.name == 'photo.png' && c.status == TransferStatus.received));
      });

      final handle = tester.ensureSemantics();
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

      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();

      await tester.runAsync(() async {
        await alice.dispose();
        await bob.dispose();
        await tempDir.delete(recursive: true);
      });
    });
  });
}
