// Real device/emulator integration test for PearBee (flutter_pear-g28):
// exercises the wrapper's REAL public Dart API (lib/src/bee.dart) against
// the REAL pear-end worklet, over a REAL Hyperswarm connection, talking to
// a REAL desktop peer process -- tool/peer.js's `--bee` mode, already
// validated process-to-process by tool/peer.check.js's checkBeeRoundTrip.
// Unlike bee_test.dart's FakeBareWorklet-driven unit tests (which never
// leave flutter_pear_test's in-memory fake), every byte here crosses a
// real Bare worklet, a real Android platform channel, the real
// Hyperswarm/Hyperbee wire protocol, and a real network hop to a real Node
// process on the host machine.
//
// Mirrors checkBeeRoundTrip's own ALREADY-PROVEN direction exactly, rather
// than inventing an untested one (see peer.js's own header comment on
// --bee mode): the desktop peer -- driven by a single `key=value` stdin
// line, exactly like checkBeeRoundTrip's own `a.send('hello=from-A')` --
// is the side that PUTS. This phone-side test is the side that opens the
// desktop's bee BY KEY (never by name -- this side never holds its writer
// key, same as bee_test.dart's own "two peers replicate a bee" fake test),
// watches it, and observes the put arriving via real replication.
//
// This test cannot spawn or drive the desktop peer itself -- there is no
// path from device-side Dart to a HOST-machine process. The desktop peer
// must already be running, on the SAME topic, before this test's own
// join() call:
//   node tool/peer.js --bee --topic <topic> --timeout <seconds>
// and must be fed exactly one stdin line -- `$_kKey=$_kValue` below --
// but ONLY after this test's own log shows the `bee-transport:
// READY_FOR_PUT` marker printed just below. That ordering is load-bearing,
// not cosmetic: sending the put before this side's watch() is armed risks
// the value arriving folded into the WATCHER'S OWN baseline snapshot
// during initial replication sync, which would never fire a visible
// "change" at all -- see peer.js's own header comment on the identical
// race, hit from the other direction, which is why --bee mode drives puts
// from live stdin lines rather than a preloaded CLI list in the first
// place.
//
// Run: flutter test integration_test/bee_transport_test.dart -d <device> \
//   --dart-define=PEER_TOPIC=<topic matching the desktop peer's --topic>
import 'dart:async';
import 'dart:convert';

import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Must match the literal stdin line the desktop peer.js --bee process is
// fed by this test's host-side caller (see this file's header comment).
const _kKey = 'phone-observed';
const _kValue = 'from-desktop-peer';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    "PearBee observes a real desktop peer's put() over a real Hyperswarm "
    'connection (flutter_pear-g28)',
    (tester) async {
      // Same derivation as PearCrypto.unsafeTopicFromString (SHA-256 of the
      // UTF-8 string) -- overridable via --dart-define so the host-side
      // orchestration can pick a fresh, randomized topic per run. See
      // peer.js's own header comment: a FIXED topic on the real, public
      // DHT is a real, empirically-hit source of flakiness/collision.
      const topicName = String.fromEnvironment('PEER_TOPIC',
          defaultValue: 'flutter-pear-bee-transport-test');

      final pear = await Pear.start().timeout(const Duration(seconds: 20));
      addTearDown(pear.dispose);

      final topic = PearCrypto.unsafeTopicFromString(topicName);
      final swarm = await pear.join(topic);
      addTearDown(swarm.leave);

      // Real, public DHT discovery -- the phone side has no bootstrap
      // override (pear-end's own `new Hyperswarm()` takes none, unlike
      // peer.js's --bootstrap), so this can't be routed onto
      // peer.check.js's private local testnet. A generous bound, not the
      // tight one ipc_transport_test.dart uses for a purely local IPC
      // round trip -- see peer.check.js's own header comment for how
      // flaky real-DHT discovery has empirically been measured to be even
      // between two DESKTOP processes, let alone a real device.
      final connection =
          await swarm.connections.first.timeout(const Duration(seconds: 90));
      // ignore: avoid_print
      print('bee-transport: connected to '
          '${connection.remotePublicKey.hex.substring(0, 8)}…');

      // The desktop peer.js --bee process announces its OWN bee key over
      // this SAME 'pear-connection-data' Protomux channel PearConnection.
      // data surfaces -- unconditionally, the instant it connects (see
      // peer.js's runBee: `message.send(...)` fires right after
      // `channel.open()`, before it even waits to learn a peer key back)
      // -- so this is the very first payload this connection ever
      // delivers. Subscribing here, in the same synchronous continuation
      // as the `connections.first` await above resolving, matches
      // PearSwarm.state's own documented ordering guarantee: a worklet
      // event for THIS peer that arrived after 'swarmConnection' can only
      // be processed as a later platform-channel task, never ahead of the
      // synchronous code that follows this await.
      final keyBytes =
          await connection.data.first.timeout(const Duration(seconds: 15));
      final desktopBeeKey = PearKey.fromHex(utf8.decode(keyBytes));
      // ignore: avoid_print
      print('bee-transport: learned desktop bee key ${desktopBeeKey.hex}');

      // Opened BY KEY, not by name -- this side never owns the writer key
      // for this bee, exactly matching bee_test.dart's own "two peers
      // replicate a bee" fake test (the watching side always attaches by
      // key).
      final bee = await pear.bee(key: desktopBeeKey);

      final watchFired = Completer<void>();
      final sub = bee.watch().listen((_) {
        if (!watchFired.isCompleted) watchFired.complete();
      });
      addTearDown(sub.cancel);

      // Both sides must call replicate() for data to flow (see bee.dart's
      // own doc + bee_test.dart's "replicate() called by only ONE side
      // never syncs data" test) -- the desktop side already began
      // replicating ITS OWN bee core the instant it connected (peer.js's
      // runBee calls `bee.core.replicate(conn)` unconditionally, before
      // any key exchange), so this call is this side's half of that pair.
      await bee.replicate(connection);

      // The marker the host-side orchestration waits for before feeding
      // the desktop peer its stdin put -- see this file's header comment
      // for why this ordering (watch armed strictly before the put
      // happens) is load-bearing.
      // ignore: avoid_print
      print('bee-transport: READY_FOR_PUT');

      await watchFired.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException(
            "desktop peer's put never replicated in / watch() never fired"),
      );

      // Re-read through the ordinary get() path (not the watcher's own
      // internal diff), same as peer.js's own runBee re-reads through
      // createReadStream() on a watch fire -- proves the value is
      // genuinely durable and queryable post-replication, not just an
      // artifact of the watch signal itself.
      final value = await bee.get(utf8.encode(_kKey));
      expect(value, isNotNull,
          reason: "the desktop peer's put must be readable via get() "
              'after replication, not just visible to watch()');
      expect(utf8.decode(value!), _kValue);
      // ignore: avoid_print
      print('bee-transport: observed real cross-runtime put $_kKey=$_kValue');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
