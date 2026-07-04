# E6.5 — Reconnect and message-delivery contract

**Pinned open question, resolved:** what does flutter_pear actually guarantee
about a dropped peer connection — after a network switch (wifi → mobile
data), a brief backgrounding, a peer going to sleep, or a peer's process
dying and restarting?

## The decision

**Connection objects are EPHEMERAL.** A `PearConnection` represents one
physical connection, not a durable session:

- When a connection drops, that `PearConnection`'s `data` stream closes
  (`onDone` fires) and any further `write()` on it fails with a typed
  `PearConnectionException` (`PearErrorCode.connectionClosed`) — it never
  silently starts working again, even after the SAME peer reconnects (see
  the note on `write()`'s implementation below for why that needed an
  explicit local check, not just relying on the worklet's own response).
- `PearSwarm.state` reflects the drop as `PearSwarmState.reconnecting` (if
  this was the last peer connected on this topic — a different peer staying
  connected keeps the swarm `connected`).
- When the peer reconnects — Hyperswarm's own DHT-based discovery
  re-announces and re-connects automatically; flutter_pear adds no extra
  reconnect logic of its own — a **brand-new** `PearConnection` object
  arrives on `PearSwarm.connections`, and `state` returns to `connected`.
  The old, already-closed `PearConnection` is never reused or "revived."

**NO message-delivery guarantee at the swarm/connection layer.**
`PearConnection.write()`/`.data` are a raw, unbuffered duplex byte pipe over
one physical connection — nothing here queues, retries, or replays a byte
that was in flight when the connection dropped. If you need
delivery/ordering guarantees across a reconnect (message wasn't lost, or
arrives in a defined order even after a peer was offline), that's
Hypercore/Autobase replication's job (E5.2–E5.8), not the swarm layer's — a
Hypercore log naturally re-syncs whatever the offline side missed once
replication resumes, because it's append-only and self-describing; a raw
`PearConnection.write()` byte has no such memory.

## What Hyperswarm already gives us (unchanged, no flutter_pear code needed)

Hyperswarm's own DHT-based peer discovery is inherently resilient to
network changes: it keeps trying to find and connect to peers on a joined
topic for as long as the topic stays joined, regardless of *why* a previous
connection ended. flutter_pear doesn't need to detect "was this a network
switch vs. a peer sleeping vs. a peer process restarting" — from
Hyperswarm's perspective (and therefore ours) these all look the same:
connection ends, discovery keeps running, a new connection arrives if/when
the peer is reachable again.

## What flutter_pear adds

- `PearSwarmState.reconnecting`/`.connected` transitions around every
  drop/reconnect (already shipped as part of E2.7's connection-state stream,
  X8) — an honest, typed signal an app can render, instead of a silently
  stuck connection.
- The ephemeral-`PearConnection`-object contract above, made explicit and
  tested (this ticket) rather than left as an unstated implementation detail.

## Tests

`packages/flutter_pear/test/swarm_test.dart`:

- "the full reconnect cycle" — exercises the complete lifecycle against
  `flutter_pear_test`'s conformance-tested `FakeBareWorklet`/`FakeSwarmHub`:
  `connected` → (`disconnectFrom`) → `reconnecting` (the dropped
  `PearConnection`'s `data` stream closes; `write()` on it now fails with
  `connectionClosed`) → (`FakeSwarmHub.join` again, standing in for
  Hyperswarm's automatic re-discovery) → `connected` again, with a **new**,
  distinct `PearConnection` object for the same remote peer — whose
  `write()` works normally, while the OLD object's `write()` still fails
  even now that the peer has a live connection again.
- "a peer already connected via one shared topic still gets connected on a
  SECOND shared topic" — a peer pair connects on topic1, then both also
  join topic2; topic2 must independently reach `connected` too (Hyperswarm
  shares one physical connection across every topic that finds it, so a
  peer already connected on topic1 must still get a fresh
  `SWARM_CONNECTION`/`CONNECTED` for topic2).

Fixed several real conformance gaps in `FakeBareWorklet` while writing
these tests (the fake must match pear-end/index.js's actual behavior, not
the other way around — see its own doc comment):

1. `disconnectFrom` never emitted `PearSwarmState.reconnecting` when the
   last connected peer for a still-joined topic dropped — pear-end's real
   `conn.on('close', ...)` handler does
   (`if (t.connectedPeers.size === 0) sendState(topicHex, RECONNECTING)`).
2. `_connectTo`'s "is this a genuinely new connection" check was scoped
   per-PEER, not per-(peer, topic) like pear-end's real `announce()`
   (`t.connectedPeers`, a Set scoped to that one topic) — gating the
   `connected` state transition on that same peer-only flag (needed so a
   redundant `FakeSwarmHub.join()` call for an already-connected pair
   doesn't emit a spurious extra `connected`) would otherwise have
   permanently suppressed the transition for any SECOND topic a
   peer pair shares, since the fake would already consider that peer
   "known" from the first topic. Fixed by keying the check off whether
   THIS topic specifically was already recorded for that peer.
3. `disconnectFrom`'s `connectionClose` event fired unconditionally per
   topic, while the `reconnecting` state was (correctly) gated on the topic
   still being joined — an asymmetry versus pear-end's real handler, which
   gates both on the exact same check. Fixed by gating both together.
4. `PearConnection.write()` was keyed purely by the remote peer's public
   key (matching the REAL worklet's own `connectionChannels`/`connections`
   maps, also peer-hex-keyed) — meaning a stale `PearConnection` reference
   held past a drop would silently start delivering again once the SAME
   peer reconnected (the peer-hex key now resolves to the new connection).
   This is a real, previously-undocumented gap in the ACTUAL implementation
   (not just the fake): fixed by adding a local `_closed` flag to
   `PearConnection` itself, checked before ever making the RPC call — the
   Dart object now refuses on its own, regardless of what the worklet
   would have said.

## What's deferred

The device leg — wifi → mobile-data switch and an airplane-mode blip against
a real Hyperswarm topic, confirming the old connection closes, a new one
arrives, and `state` transitions match this contract exactly, plus
documenting the real observed timings — is tracked centrally in
`flutter_pear-doi`, per this project's standing "automated tests first,
hardware last" decision. The contract itself does not depend on those
timings (it's deliberately timing-agnostic — an app can only observe
`reconnecting`/`connected`, not "how long a reconnect took" as an API
guarantee), so this decision isn't blocked on that pass.

## Cross-references

- `PearConnection`, `PearSwarm.connections`, `PearSwarm.state`
  (`lib/src/swarm.dart`) — carries this contract in its dartdoc.
- `BACKGROUND_EXECUTION.md` (E6.4) — the background-execution reality this
  contract composes with (a backgrounded-then-suspended swarm's connections
  are dropped for the SAME reason described here, just triggered by
  `Pear.suspend` instead of an external network change).
- Logged in `~/.gstack/projects/andrewloable-flutter_pear/decisions.jsonl`
  (kind: `decide`) alongside this project's other pinned-question
  resolutions.
