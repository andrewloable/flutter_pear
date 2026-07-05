// Real device/emulator integration test for PearBase (flutter_pear-g28):
// exercises the wrapper's REAL public Dart API (lib/src/base.dart) against
// the REAL pear-end worklet, over a REAL Hyperswarm connection, talking to a
// REAL desktop peer process -- tool/peer.js's `--base` mode, already
// validated process-to-process by tool/peer.check.js's checkBaseRoundTrip.
// Unlike base_test.dart's FakeBareWorklet-driven unit tests (which never
// leave flutter_pear_test's in-memory fake), every byte here crosses a real
// Bare worklet, a real Android platform channel, the real
// Hyperswarm/Autobase wire protocol, and a real network hop to a real Node
// process on the host machine.
//
// Drives the exact TWO-WRITER CONVERGENCE property flutter_pear-doi's own
// notes call out for flutter_pear-2vz.8 (see peer.js's own `--base` header
// comment for the full handshake rationale this mirrors): this side and the
// desktop peer each put() a DIFFERENT key while mutually unaware of each
// other, then replicate, and both must converge on one identical view
// containing BOTH keys -- not just a single append round trip (already
// covered, in-process, by autobase-recipes.test.js).
//
// Autobase's bootstrap requirement makes this a real two-step handshake, not
// a symmetric single-key-swap like bee/drive_transport_test.dart's own
// key exchange: Autobase's second writer can't be constructed independently
// and merged in later -- its bootstrap key must be known BEFORE
// construction (confirmed against autobase's own source; see peer.js's
// header comment on `--base` mode for the full explanation). This
// phone-side test plays the HOST role (tool/peer.check.js's own
// checkBaseRoundTrip role names): it opens its base BY NAME (the sole
// initial writer, so PearBase.key and PearBase.writerKey are the identical
// hex string), announces its own writerKey over the connection FIRST, then
// waits to learn the desktop peer's own writerKey back so it can
// [PearBase.addWriter] it -- exactly runBase's
// `if (args.baseRole === 'host') { message.send(...) }` and its
// onHandshake's host branch. The desktop peer plays JOIN: it can't
// construct its own Autobase until it learns this side's writerKey, which is
// why the desktop peer must already be running -- and already listening on
// the shared topic -- before this test's own join() call, same as
// bee/drive_transport_test.dart's own ordering requirement.
//
// Only ONE side (host, this side) ever calls addWriter -- the join side
// never adds the host back, because the host is already the base's genesis
// writer from construction, before any peer even existed (confirmed against
// peer.js's own runBase: only the host branch of onHandshake calls
// `base.append(addWriterOp)`; the join branch only constructs its Autobase
// and announces its own key).
//
// This test cannot spawn or drive the desktop peer itself -- there is no
// path from device-side Dart to a HOST-machine process (same limit
// bee_transport_test.dart's own header comment describes). The desktop peer
// must already be running, in --base-role join, on the SAME topic, before
// this test's own join() call:
//   node tool/peer.js --topic <topic> --base --base-role join \
//     --base-put desktop-key=desktop-value \
//     --base-expect phone-key=phone-value --timeout <seconds>
//
// Run: flutter test integration_test/base_transport_test.dart -d <device> \
//   --dart-define=PEER_TOPIC=<topic matching the desktop peer's --topic>
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Must match, byte-for-byte, the desktop peer.js --base process's own
// --base-put/--base-expect flags (see this file's header comment for the
// exact command).
const _kOwnKey = 'phone-key';
const _kOwnValue = 'phone-value';
const _kPeerKey = 'desktop-key';
const _kPeerValue = 'desktop-value';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'PearBase converges two independent writers -- this side and a real '
    'desktop peer each put() a different key while mutually unaware, then '
    'both observe BOTH keys after replication (flutter_pear-g28)',
    (tester) async {
      // Same derivation as PearCrypto.unsafeTopicFromString (SHA-256 of the
      // UTF-8 string) -- overridable via --dart-define so the host-side
      // orchestration can pick a fresh, randomized topic per run. See
      // peer.js's own header comment: a FIXED topic on the real, public DHT
      // is a real, empirically-hit source of flakiness/collision.
      const topicName = String.fromEnvironment('PEER_TOPIC',
          defaultValue: 'flutter-pear-base-transport-test');

      final pear = await Pear.start().timeout(const Duration(seconds: 20));
      addTearDown(pear.dispose);

      // Opened BY NAME -- this side is the base's sole initial writer (the
      // HOST role, see this file's header comment), so PearBase.key and
      // PearBase.writerKey are the identical hex string here (both derived
      // from the same local writer core) -- matches runBase's host branch,
      // which creates `new Autobase(store, null, baseOpts)` before any
      // connection exists.
      final base = await pear.base(
          recipe: PearRecipe.lww, name: 'base-transport-test-host');
      // ignore: avoid_print
      print('base-transport: opened own base, writerKey '
          '${base.writerKey.hex}');

      final topic = PearCrypto.unsafeTopicFromString(topicName);
      final swarm = await pear.join(topic);
      addTearDown(swarm.leave);

      // Real, public DHT discovery -- the phone side has no bootstrap
      // override (pear-end's own `new Hyperswarm()` takes none, unlike
      // peer.js's --bootstrap), so this can't be routed onto
      // peer.check.js's private local testnet. Same generous bound as
      // bee/drive_transport_test.dart's own connection wait.
      final connection =
          await swarm.connections.first.timeout(const Duration(seconds: 90));
      // ignore: avoid_print
      print('base-transport: connected to '
          '${connection.remotePublicKey.hex.substring(0, 8)}…');

      // Host's base already exists -- chain replicate() onto the connection
      // right away, exactly matching runBase's
      // `if (args.baseRole === 'host') base.replicate(conn)` (called before
      // any handshake data is exchanged; the join side can only replicate
      // once its own Autobase is constructed, which needs this side's key
      // first).
      await base.replicate(connection);

      // Same 'pear-connection-data' channel bee/drive's own key-announcement
      // handshakes use, generalized by runBase into a two-step exchange: the
      // host announces its writerKey FIRST, unconditionally, the instant
      // it's connected -- exactly runBase's
      // `if (args.baseRole === 'host') { message.send(...) }`.
      await connection.write(utf8.encode(base.writerKey.hex));
      // ignore: avoid_print
      print('base-transport: announced own writerKey to peer');

      // The desktop join side can't construct its own Autobase (and so can't
      // send anything back) until it has received the line above -- this is
      // therefore the FIRST and ONLY payload this connection ever delivers
      // to the host, matching runBase's host branch of onHandshake
      // (`const joinerKeyHex = data.toString('utf8')`).
      final joinerKeyBytes =
          await connection.data.first.timeout(const Duration(seconds: 30));
      final joinerWriterKey = PearKey.fromHex(utf8.decode(joinerKeyBytes));
      // ignore: avoid_print
      print('base-transport: learned desktop writerKey '
          '${joinerWriterKey.hex}');

      // Admits the desktop peer as a second writer -- exactly runBase's
      // `await base.append(addWriterOp)` in the host branch of onHandshake.
      // Only the host ever calls addWriter (see this file's header comment
      // for why the join side never calls it back).
      await base.addWriter(joinerWriterKey);
      // ignore: avoid_print
      print('base-transport: admitted desktop peer as writer');

      // This side's own put -- the host is already writable from
      // construction (it's the base's genesis writer), so this is expected
      // to succeed on the very first try, unlike the join side's own put
      // (which reliably throws "Not writable" until this addWriter call
      // above has replicated back and been applied there -- see runBase's
      // own header comment for that race and its appendWhenWritable retry).
      // Retried defensively anyway, matching runBase's own choice to run
      // EVERY own-put through appendWhenWritable uniformly regardless of
      // role, rather than this test blindly trusting "host is always
      // immediately writable" as an assumption of its own.
      await _putWhenWritable(
        base,
        Uint8List.fromList(utf8.encode(_kOwnKey)),
        Uint8List.fromList(utf8.encode(_kOwnValue)),
        const Duration(seconds: 30),
      );
      // ignore: avoid_print
      print('base-transport: appended own put $_kOwnKey=$_kOwnValue');

      // Polls the SAME get() path PearBase's own public API exposes (not an
      // internal Autobase view) until the desktop peer's independent put --
      // appended while this side had no knowledge of it -- has replicated in
      // and linearized into this side's own merged view. Real proof of
      // replication + linearization, not just that this side's own append
      // landed locally -- mirrors peer.js's own waitForConverged.
      final peerResult = await _waitForConverged(
        base,
        Uint8List.fromList(utf8.encode(_kPeerKey)),
        const Duration(seconds: 60),
      );
      expect(peerResult.exists, isTrue,
          reason: "the desktop peer's independent put must converge into "
              "this side's own view via real replication");
      expect(utf8.decode(peerResult.value!), _kPeerValue);

      // This side's own put must also still be readable through the same
      // get() path post-convergence -- the two-writer convergence property
      // is BOTH keys visible together in one identical view, not just the
      // peer's.
      final ownResult = await base.get(Uint8List.fromList(utf8.encode(_kOwnKey)));
      expect(ownResult.exists, isTrue);
      expect(utf8.decode(ownResult.value!), _kOwnValue);

      // ignore: avoid_print
      print('base-transport: converged view contains both '
          '$_kOwnKey=$_kOwnValue and $_kPeerKey=$_kPeerValue');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

// See runBase's own header comment (in tool/peer.js) for why this retry is
// load-bearing on the join side, and this file's own inline comment above
// for why it's used here, defensively, on the host side too: base.put()
// reliably throws a PearStorageException wrapping Autobase's own
// `Error('Not writable')` until a freshly admitted writer's addWriter op has
// round-tripped and been applied -- mirrors peer.js's own
// appendWhenWritable.
Future<void> _putWhenWritable(
  PearBase base,
  Uint8List key,
  Uint8List value,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  for (;;) {
    try {
      await base.put(key, value);
      return;
    } on PearException catch (e) {
      if (!e.message.toLowerCase().contains('not writable')) rethrow;
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
            'timed out waiting to become a writable member of the base');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}

// Mirrors peer.js's own waitForConverged: polls PearBase.get (the same read
// path callers use, not an internal view) until the peer's key shows up in
// OUR OWN materialized view.
Future<PearBaseGetResult> _waitForConverged(
  PearBase base,
  Uint8List key,
  Duration timeout,
) async {
  final deadline = DateTime.now().add(timeout);
  for (;;) {
    final result = await base.get(key);
    if (result.exists) return result;
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
          "timed out waiting for the peer's key to converge into our own "
          'view');
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}
