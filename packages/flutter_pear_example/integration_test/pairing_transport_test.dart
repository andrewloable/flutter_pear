// Real device/emulator integration test for PearPairing (flutter_pear-g28):
// exercises the wrapper's REAL public Dart API (lib/src/pairing.dart) against
// the REAL pear-end worklet, over a REAL Hyperswarm/blind-pairing exchange,
// talking to a REAL desktop peer process -- tool/pairing-peer.js's `--role
// invite` mode, already validated process-to-process by
// tool/pairing-peer.check.js. Unlike pairing_test.dart's FakeSwarmHub-driven
// unit tests (which never leave flutter_pear_test's in-memory fake), every
// byte here crosses a real Bare worklet, a real Android platform channel,
// the real blind-pairing/Hyperswarm wire protocol, and a real network hop to
// a real Node process on the host machine.
//
// DIRECTION: the desktop peer is the INVITE side, this phone-side test is
// the ACCEPT side -- the reverse of lib/pairing_screens.dart's own demo
// convention (StartRoomScreen creates, JoinRoomScreen accepts), but the
// direction pairing-peer.check.js's own already-proven round trip validates
// BOTH roles of symmetrically, so either mapping is equally proven on the
// desktop-script side. This mapping is chosen for orchestration, not
// protocol, reasons, matching bee_transport_test.dart/drive_transport_test.
// dart's own established shape here: the desktop peer must already be
// running and have produced everything this test needs (here: the invite
// bytes themselves, not just a topic to join) before this test starts, since
// there is no path from device-side Dart to a HOST-machine process to spawn
// or drive it. Desktop-creates-first also sidesteps a real ordering
// requirement of blind pairing itself: the inviter's own discoveryKey
// announce needs a head start over the accepting side's join for that same
// discoveryKey to reliably resolve on the first (and, on this side, only)
// attempt -- see pairing-peer.js's own header comment's "REAL BUG FOUND"
// note for the general shape of this class of issue. Desktop-first
// naturally provides that head start (it's already announced and looping
// while this Flutter test is still cold-booting its own worklet).
//
// ALSO covers the distinct, HIGH-PRIORITY property flutter_pear-doi's own
// notes flagged as unverified outside the Dart fake and pairing-peer.check.js's
// desktop-to-desktop run: that PearConnection.write/.data (the raw app-data
// channel, routed through pear-end's own 'pear-connection-data' Protomux
// channel) still delivers bytes correctly over the SAME live connection
// BlindPairing's own Protomux usage just negotiated -- this is the first
// time that's proven with a REAL PHONE-side Bare worklet on one end, not
// just two desktop processes. Learning the peer's public key (needed for
// PearMethod.connectionWrite, which is keyed by peer hex, not by
// PearConnection identity alone the way write() itself is) requires this
// side to ALSO join an ordinary shared topic, exactly like pairing-peer.js's
// own "LEARNING THE PEER'S PUBLIC KEY" comment explains -- Hyperswarm shares
// ONE physical connection per remote public key across every topic that
// finds it, so this shared-topic join attaches to the exact same connection
// blind pairing's discoveryKey-based join already opened.
//
// The application-level ack/resend loop below is NOT optional decoration --
// it's the fix for a real bug pairing-peer.js's own header comment documents
// in detail ("SECOND REAL BUG FOUND"): a message delivered before the
// RECEIVING side's own local discovery of the sender via the shared topic
// completes is silently and PERMANENTLY dropped (pear-end's own
// CONNECTION_DATA forwarding is gated on that peer's info.topics already
// including the shared topic on the receiving side specifically -- a
// per-side, per-peer race with no inherent ordering, not something a single
// send-and-hope can rely on). A naive one-shot write here would be flaky in
// exactly the way that comment describes, not just a hypothetical.
//
// Run: two steps, since the desktop peer must produce the invite BEFORE this
// test can start (see this file's own DIRECTION note above):
//   1. node tool/pairing-peer.js --role invite --topic <topic> --timeout 150
//      (no --bootstrap -- real DHT; see that file's own "--bootstrap is
//      OPTIONAL" comment) and capture its printed `invite: <base64>` line.
//   2. flutter test integration_test/pairing_transport_test.dart -d <device> \
//        --dart-define=PEER_TOPIC=<topic matching step 1> \
//        --dart-define=PEER_INVITE=<base64 invite captured from step 1>
// Cross-check both sides paired the SAME key by comparing this test's own
// printed `pairing-transport: paired: <base64>` line against the desktop
// peer's `confirmed: <base64>` line -- mirrors pairing-peer.check.js's own
// `assert.equal(pairedKey, confirmedKey, ...)`, just compared externally
// across two independent process logs instead of one script's in-memory
// child-process stdout, since there's no other channel between a real phone
// and a host-machine process to compare them over directly.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Must match pairing-peer.js's own `hello from ${args.role} over the paired
// connection` content exactly -- this side plays the "accept" role, the
// desktop plays "invite" (see this file's header comment's DIRECTION note).
const _kOutgoingContent = 'hello from accept over the paired connection';
const _kExpectedIncoming = 'hello from invite over the paired connection';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'PearPairing completes a real invite/accept round trip with a real '
    'desktop peer, and the paired connection carries real chat-style '
    'app data alongside BlindPairing\'s own Protomux usage '
    '(flutter_pear-g28)',
    (tester) async {
      // Same derivation as PearCrypto.unsafeTopicFromString (SHA-256 of the
      // UTF-8 string) -- overridable via --dart-define, matching
      // bee_transport_test.dart/drive_transport_test.dart's own convention,
      // so host-side orchestration can pick a fresh, randomized name per
      // run. This topic is NOT the pairing channel itself (blind-pairing
      // uses its own internal discoveryKey, with no topic string of its
      // own) -- it exists solely so both sides can learn each other's
      // public key for PearMethod.connectionWrite (see this file's header
      // comment's "LEARNING THE PEER'S PUBLIC KEY" paragraph).
      const topicName = String.fromEnvironment('PEER_TOPIC',
          defaultValue: 'flutter-pear-pairing-transport-test');

      // No sensible default -- unlike topicName, an invite is single-use,
      // freshly generated content this test cannot derive on its own; it
      // must come from the desktop peer's own `invite: <base64>` stdout
      // line (see this file's header comment's run recipe). Failing fast
      // with a clear message beats a confusing PearErrorCode.invalidInvite
      // a few seconds into the test.
      const inviteBase64 = String.fromEnvironment('PEER_INVITE');
      expect(inviteBase64, isNotEmpty,
          reason: 'PEER_INVITE dart-define is required -- pass the base64 '
              'invite printed by `node tool/pairing-peer.js --role invite '
              '...` as --dart-define=PEER_INVITE=<value>. See this file\'s '
              'header comment for the full run recipe.');
      final invite = base64Decode(inviteBase64);

      final pear = await Pear.start().timeout(const Duration(seconds: 20));
      addTearDown(pear.dispose);

      // Real, public DHT discovery on both the blind-pairing handshake and
      // (below) the shared-topic join -- generous bound, matching the other
      // real-desktop-peer transport tests' own reasoning for why a purely
      // local-IPC test like ipc_transport_test.dart can afford a much
      // tighter one and this can't.
      final pairedKey = await pear.acceptInvite(
        invite,
        timeout: const Duration(seconds: 90),
      );
      // ignore: avoid_print
      print('pairing-transport: paired: ${base64Encode(pairedKey.bytes)}');

      final topic = PearCrypto.unsafeTopicFromString(topicName);
      final swarm = await pear.join(topic);
      addTearDown(swarm.leave);

      final connection =
          await swarm.connections.first.timeout(const Duration(seconds: 90));
      // ignore: avoid_print
      print('pairing-transport: connected to '
          '${connection.remotePublicKey.hex.substring(0, 8)}…');

      // The high-priority coexistence property under test (see this file's
      // header comment): CONNECTION_WRITE/CONNECTION_DATA over the SAME
      // connection BlindPairing's own Protomux channel just paired on,
      // sent only now that this side's own half of the pairing handshake
      // (acceptInvite's resolved Future, above) has fully flowed over the
      // wire -- a genuine "pair, THEN chat over the same pipe" sequence,
      // not two logically-unrelated channels that merely happen not to
      // race, mirroring pairing-peer.js's own SEQUENCING comment.
      final ackCompleter = Completer<void>();
      final incomingCompleter = Completer<String>();
      const ackForOutgoing = 'ack:$_kOutgoingContent';

      final dataSub = connection.data.listen((bytes) {
        final text = utf8.decode(bytes);
        if (text.startsWith('ack:')) {
          if (text == ackForOutgoing && !ackCompleter.isCompleted) {
            ackCompleter.complete();
          }
          return;
        }
        // Echoes EVERY non-ack delivery, including duplicates -- the
        // peer's own resend loop may not have observed an earlier ack yet.
        // Mirrors pairing-peer.js's own onAnyEvent auto-ack responder;
        // required for the same reason its resend loop is (see this file's
        // header comment's "SECOND REAL BUG" paragraph).
        unawaited(connection
            .write(Uint8List.fromList(utf8.encode('ack:$text')))
            .catchError((_) {}));
        if (!incomingCompleter.isCompleted) incomingCompleter.complete(text);
      });
      addTearDown(dataSub.cancel);

      // Resend loop: keeps sending until the PEER proves receipt (its own
      // ack comes back), not until this side is merely satisfied with
      // having sent once -- a single fire-and-forget write here would be
      // flaky in exactly the way pairing-peer.js's own header comment
      // documents (a message physically arriving before the receiver's own
      // shared-topic discovery of this connection completes is silently
      // and PERMANENTLY dropped, with nothing for a one-shot send to ever
      // recover).
      final resendDeadline = DateTime.now().add(const Duration(seconds: 60));
      while (!ackCompleter.isCompleted) {
        await connection
            .write(Uint8List.fromList(utf8.encode(_kOutgoingContent)));
        if (DateTime.now().isAfter(resendDeadline)) {
          throw TimeoutException(
              'timed out waiting for the desktop peer to ack connection.data '
              '-- see this file\'s header comment on why a single write is '
              'not expected to be reliable here');
        }
        await Future.any<void>([
          ackCompleter.future,
          Future<void>.delayed(const Duration(milliseconds: 1500)),
        ]);
      }

      final received = await incomingCompleter.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException(
            'the desktop peer never sent its own app-data message over the '
            'paired connection'),
      );
      // ignore: avoid_print
      print('pairing-transport: app-data: $received');
      expect(received, _kExpectedIncoming,
          reason: 'the raw app-data channel must deliver the desktop '
              'peer\'s content-exact bytes over the SAME connection '
              'BlindPairing just paired on');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
