## 0.4.5

**Added: `join(topic, acceptUnannounced: true)` and `join(topic, announce: false)`
-- for a phone that dials an always-on device.** No breaking API change;
both default to today's behaviour.

- **`acceptUnannounced`, on the device.** A connection another peer dialed
  in could only be used once this side's discovery found the dialer's
  announcement (the 0.4.3 fix retries for about a minute). From a phone
  behind a slow or randomizing NAT that race was often lost and the
  connection sat open but silent -- found by BladeWatch, 5 of 8 routes from a
  phone hotspot. With the option, an inbound connection is attributed to the
  topic at once, as long as exactly one joined topic has the option.
- **`announce: false`, on the phone.** It dials peers that announce but is
  never announced itself, so it no longer leaves a record on the topic that
  outlives the session by the DHT's 20-minute record lifetime (BladeWatch saw
  7 announcers of which 1 answered, each dead one costing every later dialer
  a failing dial of 5-10 s). Usable ONLY against a peer that joined with
  `acceptUnannounced`: nothing else can attribute the connection.

The flags travel as optional `server: false` / `acceptUnannounced: true` on
`swarm.join`; absent means today's behaviour, so older callers and bundles are
unaffected. A repeat join keeps its first options.

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

