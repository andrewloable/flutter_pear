# flutter_pear_example

Two-peer chat over Hyperswarm, no server — the clone-and-run proof for
`flutter_pear` (Android only for now). The `android/` runner is checked in;
no `flutter create` hydrate step.

## Run (two devices)

```bash
flutter devices               # note the device IDs for both phones/emulators
flutter run -d <device-id-A>  # terminal 1
flutter run -d <device-id-B>  # terminal 2
```

No second phone handy? Two Android emulators work fine — `flutter emulators` lists available AVDs, `flutter emulators --launch <avd-id>` boots a second, distinct one alongside whichever is already running; use its device ID exactly like a real device.

Enter the same room name on both devices and tap **Join**. Messages sent on
one appear on the other; the banner at the top honestly shows the swarm's
connection state (discovering/connecting/connected/reconnecting/failed —
with the reason on failure).

The room name is a demo-only shortcut (`PearCrypto.unsafeTopicFromString`) —
anyone worldwide using the same text lands in the same room. Real apps
derive a topic from a `PearPairing` invite instead.

## One-phone path: the desktop CLI peer

Only one phone/emulator? `bin/peer.dart` joins the same room from your
laptop instead of a second device:

```bash
dart run flutter_pear_example:peer --topic my-secret-room
```

Type a line + Enter to send once it connects; incoming messages print as
`peer: <message>`. `--timeout <seconds>` (default 30) bounds the wait for a
first connection — the process exits nonzero if nobody connects in time, so
it doubles as a scriptable CI peer. Topic mode only for now; an invite-based
mode was attempted and pulled before shipping (see `tool/peer.js`'s own doc
comment for why) — the phone side has no invite-creation UI yet either
(that's E7.2), so nothing regresses by shipping topic mode alone.

The actual Hyperswarm/Protomux logic lives in `tool/peer.js`, run as a plain
Node process — see that file's own doc comment for why this is Node, not a
Bare worklet, and how it stays wire-compatible with the mobile worklet. A
runnable check lives at `tool/peer.check.js` (`node tool/peer.check.js`): a
real two-process round trip over the same topic, plus the
nonzero-exit-on-timeout contract.
