## 0.4.4

Two small, related additions to `pear-end`. No breaking API change.

**Added: `dht.status` reports DHT reachability.** A peer that only waits to
be found — an always-on device such as a car head unit — previously had no
way to tell whether anyone could currently find it: its swarm state stays
`discovering` whether or not the DHT is actually online. The worklet now
answers `{ online, firewalled }`, reading straight off Hyperswarm's own
`swarm.dht.online`/`swarm.dht.firewalled`. There is no typed Dart
convenience API for it yet — this ships the RPC method
(`PearMethod.dhtStatus`) for callers that need the raw signal now; a typed
`Pear.networkStatus()` can follow if apps want one.

**Lowered the 0.4.3 held-message cap from 1 MiB to 256 KiB per untagged
connection.** 0.4.3's inbound-connection message hold (see 0.4.3's own entry
below) bounds each connection individually, but Hyperswarm's default 64-peer
cap meant anyone who knew a topic could make a worklet hold up to 64 MiB
total before tagging. A real peer's first flight is a few KB. The new cap
brings that worst case down to 16 MiB. Found by a security review of the
0.4.3 change's new network surface.

