## 0.4.3

Fixes a real message-loss bug on inbound connections. No API change.

**Fixed: a peer that dialed in was silently dropped for up to ~12 minutes.**
`pear-end` gates every connection event (`SWARM_CONNECTION`, `CONNECTION_DATA`,
`CONNECTION_CLOSE`, connection errors) on Hyperswarm's `info.topics` — but
Hyperswarm only populates that list when *this* side's own discovery query
finds the peer. A connection the *other* peer dialed in starts with
`info.topics = []`, so whoever joined a topic first — an always-on device a
phone reaches hours later, the ordinary case — got no `SWARM_CONNECTION` and
lost every message from that peer until its next scheduled discovery
refresh: Hyperswarm's `REFRESH_INTERVAL`, 10 minutes plus up to 2 of jitter.

Found on real hardware (a BladeWatch device): Hyperswarm connected every
time, zero frames were ever delivered.

The fix re-triggers discovery for every joined topic the moment an inbound
connection lands (retried at 0/1/3/7/15/30s while untagged), tagging exactly
the topics the peer itself announces — never a topic merely because this
side joined it, since the swarm also carries blind-pairing and replication
peers. Messages that arrive before tagging completes are held (capped at
1 MiB; a peer that outruns the bound gets its connection dropped rather than
its data silently lost) and released immediately after the first
`SWARM_CONNECTION`. No wire change — 0.4.3 peers interoperate with 0.4.2 and
earlier.

Covered by a new real-testnet test (two genuine worklets, no simulated
topic-tagging shortcut) that reproduces the production shape of the bug: one
side already on the topic, the other joins and speaks first. Verified to
fail against 0.4.2's `index.js` and to fail again with the held-message
buffer removed, so it actually exercises the fix rather than passing
vacuously.

No dependency, deployment-target, or native-addon change — this release
touches only `pear-end/index.js` and the bundle it produces.

