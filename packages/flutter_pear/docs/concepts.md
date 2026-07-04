# Concepts

The ideas behind `flutter_pear`'s API — read this once, before the how-tos,
and the rest of the API stops feeling like magic. No protocol internals;
just the mental model you need to use it correctly.

## Topics vs. invites

Every swarm join starts from a 32-byte **topic** — a rendezvous key both
peers agree on out of band so Hyperswarm's DHT can introduce them. How you
get that topic is the one decision most likely to bite you.

- **`PearCrypto.unsafeTopicFromString(name)`** hashes a human-chosen string
  into a topic. It's deterministic: **every device on earth that calls this
  with the same string lands in the same swarm.** There's no way to scope
  it to just the peers you intend, and it's called `unsafe` for exactly
  that reason — the name itself is the warning, so it can't be missed even
  by someone who skips the docs. Fine for a two-device demo where you
  control both ends and the "room name" is thrown away after. Never fine
  for anything a real user picks or shares, because you cannot un-leak a
  topic once it's guessable.
- **`PearPairing` invites** are the real answer. One device creates an
  invite (`pear.createInvite()`), shares it out of band (a QR code, a short
  code read aloud, a deep link — `flutter_pear` doesn't care which), and the
  other device accepts it (`pear.acceptInvite(bytes)`). The invite is
  scoped to that one pairing session; the confirmed key it produces is
  private to the two devices that actually paired, not a string anyone
  could type in and join. This is how a real app hands out one room to one
  specific relationship instead of the whole internet.

Rule of thumb: if a human is going to type the same string into two
phones, you're in `unsafeTopicFromString` demo territory. If the two
devices haven't met before and need to be introduced by *your app*, use a
`PearPairing` invite. See [howto-pairing.md](howto-pairing.md) for the full
walkthrough.

## The worklet model

All P2P logic — Hyperswarm, Corestore, Hyperbee, Hyperdrive, Autobase,
blind-pairing — runs inside a bundled [Bare](https://github.com/holepunchto/bare)
JS runtime called the *worklet*, not in Dart. `flutter_pear`'s Dart classes
(`PearSwarm`, `PearStore`, `PearBee`, …) are typed remote controls: every
call crosses a binary IPC bridge to the worklet, which does the actual
protocol work and reports back.

This is why you never write JavaScript: the worklet ships prebuilt inside
the plugin, and `Pear.start()` boots it for you. It's also why errors
"travel" — a JS exception in the worklet gets serialized into a typed Dart
`PearException` rather than silently vanishing on the other side of the
bridge (see [../ERRORS.md](../ERRORS.md)).

## Replication mental model

Every Pear data structure (`PearCore`, `PearBee`, `PearDrive`, `PearBase`)
is local-first: it works fully offline, and syncing with a peer is a
separate, explicit step. The pattern is always the same regardless of
which data structure you're using:

1. Both peers join the same topic and get a `PearConnection` to each other
   (see [howto-chat.md](howto-chat.md)).
2. Both peers call `.replicate(connection)` on the SAME data structure
   (same name/key) — order doesn't matter, and it's a no-op-safe call to
   make on every new connection.
3. From then on, writes on either side flow to the other automatically,
   over that one connection, for as long as it stays open.

Replication only moves data — it never blocks a local read or write.
`PearCore.append`/`PearBee.put`/`PearDrive.put` all succeed immediately
against your own local copy whether or not a peer is currently connected.

## Lifecycle and background basics

`flutter_pear` wires worklet suspend/resume to `AppLifecycleState`
automatically, with a short linger window so a quick app-switch doesn't
tear down an active swarm. What suspending actually buys you — and what
neither this library nor any other can promise once the OS decides to kill
a backgrounded app — is platform-specific and documented in full in
[../BACKGROUND_EXECUTION.md](../BACKGROUND_EXECUTION.md). Read that before
you build anything that assumes a swarm survives long in the background.
