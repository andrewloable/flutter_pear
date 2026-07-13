# flutter_pear_example

Two-peer chat over Hyperswarm, no server — the clone-and-run proof for
`flutter_pear`. Runs on all five platforms: **Android, iOS, macOS, Linux,
Windows.** Every runner is checked in; no `flutter create` hydrate step.

## Run (two peers)

```bash
flutter devices               # phones, emulators, and desktop all list here
flutter run -d <device-id-A>  # terminal 1 -- e.g. a phone
flutter run -d <device-id-B>  # terminal 2 -- e.g. macos / linux / windows
```

Enter the same room name on both and tap **Join**. Messages sent on
one appear on the other; the banner at the top honestly shows the swarm's
connection state (discovering/connecting/connected/reconnecting/failed —
with the reason on failure).

> **⚠️ Use two genuinely separate machines — not two processes on one.**
> Two peers behind the same NAT (two emulators on one host, or a desktop app
> and a CLI peer on the same laptop) reliably fail to connect: many routers
> won't loop a device's own traffic back to a sibling behind the same NAT
> (**NAT hairpinning**), which breaks the UDP hole-punching Hyperswarm's DHT
> discovery depends on. This is a router behavior, not a `flutter_pear` bug —
> `dart run flutter_pear:doctor`'s loopback self-test fails the same way with
> zero `flutter_pear` code involved. Run `doctor` first if a connection sits
> at `discovering` forever.
>
> **On desktop**, the app also needs the `bare` runtime on `PATH`
> (`npm i -g bare`) — it's spawned as a subprocess, not bundled.
>
> **On a phone**, keep the screen on during the first connect. A real DHT
> lookup can take 30s+, and a screen-lock suspends the worklet by design —
> resetting that side back to `discovering` each time, which looks exactly
> like a hang.

The room name is a demo-only shortcut (`PearCrypto.unsafeTopicFromString`) —
anyone worldwide using the same text lands in the same room. Real apps
derive a topic from a `PearPairing` invite instead.

## The headless CLI peer

`bin/peer.dart` joins a room with no Flutter app at all — useful as the other
end of a test, and as a scriptable CI peer:

```bash
dart run flutter_pear_example:peer --topic my-secret-room
```

Type a line + Enter to send once it connects; incoming messages print as
`peer: <message>`. `--timeout <seconds>` (default 30) bounds the wait for a
first connection — the process exits nonzero if nobody connects in time, so
it doubles as a CI assertion. Topic mode only; an invite-based mode was
attempted and pulled before shipping (see `tool/peer.js`'s own doc comment
for why), and the app has no invite-creation UI yet either, so nothing
regresses by shipping topic mode alone.

**Run it from a different machine than the app under test** — same NAT-hairpinning
trap as above. Pointing it at an app on the same machine may connect, but a
failure there tells you nothing about your code.

The actual Hyperswarm/Protomux logic lives in `tool/peer.js`, run as a plain
Node process — see that file's own doc comment for why this is Node, not a
Bare worklet, and how it stays wire-compatible with the mobile worklet. A
runnable check lives at `tool/peer.check.js` (`node tool/peer.check.js`): a
real two-process round trip over the same topic, plus the
nonzero-exit-on-timeout contract.
