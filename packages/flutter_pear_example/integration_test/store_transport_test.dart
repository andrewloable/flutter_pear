// Real device/emulator integration test for PearStore (flutter_pear-g28):
// exercises the wrapper's REAL public Dart API (lib/src/store.dart) against
// the REAL pear-end worklet, over a REAL Hyperswarm connection, talking to a
// REAL desktop peer process -- tool/peer.js's `--store` mode, already
// validated process-to-process by tool/peer.check.js's checkStoreRoundTrip.
// Unlike store_test.dart's FakeBareWorklet-driven unit tests (which never
// leave flutter_pear_test's in-memory fake), every byte here crosses a real
// Bare worklet, a real Android platform channel, the real
// Hyperswarm/Hypercore wire protocol, and a real network hop to a real Node
// process on the host machine. This closes the one gap flutter_pear-g28's own
// scope missed: PearBee/PearDrive/PearPairing/PearBase all got a real-device
// leg, but PearStore/Hypercore -- the simplest wrapper of the four
// data-structure wrappers, and the one flutter_pear-doi's own 2vz.2 note
// explicitly calls out ("the desktop Hypercore-replicate counterpart") --
// did not, even though its desktop counterpart already existed and was
// already proven (checkStoreRoundTrip).
//
// Mirrors checkStoreRoundTrip's own ALREADY-PROVEN direction exactly, rather
// than inventing an untested one (see peer.js's own header comment on
// --store mode): the desktop peer -- given a list of `--append` values,
// exactly like checkStoreRoundTrip's own sender -- is the side that APPENDS,
// before it ever joins the swarm. This phone-side test is the RECEIVER
// (checkStoreRoundTrip's own role name): it learns the desktop's store key
// over the 'pear-connection-data' Protomux channel (the same handshake
// bee/drive_transport_test.dart's own key-announcement uses), opens that
// core BY KEY, replicates it, and reads every entry back in order -- the
// same `core.get(i)` read-back checkStoreRoundTrip's own receiver role uses,
// just through PearStore's Dart API instead of a raw Hypercore. The desktop
// peer for this test is run WITHOUT `--expect-count` -- unlike
// checkStoreRoundTrip's own two-sided invocation (which spawns a SEPARATE
// receiver process with `--expect-count` to read ITS peer's, i.e. the
// sender's, entries back), there is no second desktop process here to read
// this side back from, and this phone-side test never opens or announces a
// store of its own -- same asymmetric shape as bee_transport_test.dart /
// drive_transport_test.dart's own phone-never-writes convention. A desktop
// process started with `--append` alone simply appends, announces its key,
// replicates, and then idles until killed (see peer.js's own runStore: the
// only path that calls `finish(0)` and exits is gated on `args.expectCount
// !== undefined`), which is exactly the behavior this test's host-side
// orchestration relies on.
//
// PearCore.get() does NOT wait-by-default the way the raw Hypercore
// `core.get(i)` peer.js/checkStoreRoundTrip use does (confirmed against
// pear-end/index.js's own Method.CORE_GET handler: it checks `p.index >=
// core.length` and throws INDEX_OUT_OF_RANGE BEFORE ever calling the
// underlying `core.get(p.index)`, rather than letting a real Hypercore block
// until the index arrives) -- store.dart's own doc comment on
// [PearCore.get] documents this explicitly, and store_test.dart's own "at or
// past length throws" fake test locks it in as intentional, not an oversight
// to route around here. So this test cannot just call get(i) in a loop and
// rely on it blocking for replication the way peer.js's desktop-side
// `--expect-count` loop does -- it must first wait for [PearCore.length] to
// reach the expected count (via [PearCore.updates], read synchronously
// alongside the initial length check with no `await` between them, so no
// event can land in the gap -- same reasoning as [PearCore.length]'s own doc
// comment on why a late listener can't rely on a broadcast stream replaying
// history) before reading each block back.
//
// This test cannot spawn or drive the desktop peer itself -- there is no
// path from device-side Dart to a HOST-machine process (same limit
// bee_transport_test.dart's own header comment describes). The desktop peer
// must already be running, on the SAME topic, with entries matching this
// file's `_kEntries` constant exactly (byte-for-byte, in order), before this
// test's own join() call:
//   node tool/peer.js --store --topic <topic> --timeout <seconds> \
//     --append 'first entry' \
//     --append 'second entry — with an em dash' \
//     --append 'third: 🎉 non-ascii and repeat-looking' \
//     --append 'third: 🎉 non-ascii and repeat-looking'
//
// Run: flutter test integration_test/store_transport_test.dart -d <device> \
//   --dart-define=PEER_TOPIC=<topic matching the desktop peer's --topic>
import 'dart:async';
import 'dart:convert';

import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Must match, byte-for-byte and in order, the desktop peer.js --store
// process's own --append values (see this file's header comment for the
// exact command). Deliberately includes multi-byte UTF-8 (an em dash and an
// emoji) and a duplicate-looking-but-distinct entry, the same set
// checkStoreRoundTrip itself uses -- base64-decoding arbitrary bytes off the
// wire, not just plain ASCII, is the actual property under test.
const _kEntries = [
  'first entry',
  'second entry — with an em dash',
  'third: 🎉 non-ascii and repeat-looking',
  'third: 🎉 non-ascii and repeat-looking',
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    "PearStore reads back a real desktop peer's appended Hypercore entries "
    'over a real Hyperswarm connection, byte-exact and in order '
    '(flutter_pear-g28)',
    (tester) async {
      // Same derivation as PearCrypto.unsafeTopicFromString (SHA-256 of the
      // UTF-8 string) -- overridable via --dart-define so the host-side
      // orchestration can pick a fresh, randomized topic per run. See
      // peer.js's own header comment: a FIXED topic on the real, public DHT
      // is a real, empirically-hit source of flakiness/collision.
      const topicName = String.fromEnvironment('PEER_TOPIC',
          defaultValue: 'flutter-pear-store-transport-test');

      final pear = await Pear.start().timeout(const Duration(seconds: 20));
      addTearDown(pear.dispose);

      final topic = PearCrypto.unsafeTopicFromString(topicName);
      final swarm = await pear.join(topic);
      addTearDown(swarm.leave);

      // Real, public DHT discovery -- the phone side has no bootstrap
      // override (pear-end's own `new Hyperswarm()` takes none, unlike
      // peer.js's --bootstrap), so this can't be routed onto
      // peer.check.js's private local testnet. Same generous bound as
      // bee/drive_transport_test.dart's own connection wait, for the same
      // reason.
      final connection =
          await swarm.connections.first.timeout(const Duration(seconds: 90));
      // ignore: avoid_print
      print('store-transport: connected to '
          '${connection.remotePublicKey.hex.substring(0, 8)}…');

      // The desktop peer.js --store process announces its OWN core key over
      // this SAME 'pear-connection-data' Protomux channel PearConnection.
      // data surfaces -- unconditionally, the instant it connects (see
      // peer.js's runStore: `message.send(...)` fires right after
      // `channel.open()`, before it even waits to learn a peer key back) --
      // so this is the very first payload this connection ever delivers.
      // Subscribing here, in the same synchronous continuation as the
      // `connections.first` await above resolving, matches PearSwarm.state's
      // own documented ordering guarantee.
      final keyBytes =
          await connection.data.first.timeout(const Duration(seconds: 15));
      final desktopStoreKey = PearKey.fromHex(utf8.decode(keyBytes));
      // ignore: avoid_print
      print('store-transport: learned desktop store key '
          '${desktopStoreKey.hex}');

      // Opened BY KEY, not by name -- this side never owns the writer key
      // for this core, exactly matching store_test.dart's own "two peers
      // replicate a core" fake test (the reading side always attaches by
      // key).
      final core = await pear.store.get(key: desktopStoreKey);

      // Both sides must call replicate() for data to flow (see store.dart's
      // own doc + store_test.dart's own "replicate() called by only ONE
      // side never syncs data" test) -- the desktop side already began
      // replicating ITS OWN core the instant it connected (peer.js's
      // runStore calls `core.replicate(conn)` unconditionally, before any
      // key exchange), so this call is this side's half of that pair.
      await core.replicate(connection);

      // ignore: avoid_print
      print('store-transport: READY (waiting for ${_kEntries.length} '
          'entries to replicate in)');

      // PearCore.get() does not wait-by-default (see this file's header
      // comment) -- length must reach the expected count first.
      await _waitForLength(
        core,
        _kEntries.length,
        const Duration(seconds: 60),
      );

      // Re-read every entry through the ordinary get() path, in order --
      // proves the desktop peer's --append list is genuinely durable and
      // queryable post-replication, byte-exact, matching checkStoreRoundTrip's
      // own `assert.deepEqual(receivedEntries, entries, ...)`.
      for (var i = 0; i < _kEntries.length; i++) {
        final block = await core.get(i);
        expect(
          utf8.decode(block),
          _kEntries[i],
          reason: 'entry $i must be byte-exact and in order with the '
              "desktop peer's --append value",
        );
      }
      // ignore: avoid_print
      print('store-transport: observed real cross-runtime entries, '
          'byte-exact and in order');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

// Polls via [PearCore.updates] (matching base_transport_test.dart's own
// polling helpers for a different property) until at least [expected]
// blocks have replicated in. The initial length check and the stream
// subscription happen back-to-back with no `await` between them so no
// update landing in that gap can be missed -- see this file's header
// comment and [PearCore.length]'s own doc comment for why that ordering is
// load-bearing, not cosmetic.
Future<void> _waitForLength(
  PearCore core,
  int expected,
  Duration timeout,
) async {
  if (core.length >= expected) return;
  final completer = Completer<void>();
  final sub = core.updates.listen((length) {
    if (length >= expected && !completer.isCompleted) {
      completer.complete();
    }
  });
  try {
    await completer.future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException(
          "timed out waiting for the desktop peer's $expected appended "
          'entries to replicate in (length=${core.length})'),
    );
  } finally {
    await sub.cancel();
  }
}
