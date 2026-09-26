## Unreleased

**Added: an opt-in persistent swarm identity for long-lived peers.** No
breaking change; without the option every worklet start still draws a fresh
random key pair, which is right for a phone or desktop app.

A host that starts the worklet itself can pass `--persistent-identity` in the
worklet's argv after the storage dir. `pear-end` then derives its Hyperswarm
key pair from a 32-byte seed in the storage dir, `swarm-identity.seed`. The
seed is written once at mode 0600, via a temp file and rename, and a seed of
the wrong length is replaced. It is a secret: whoever holds it IS that peer.

Found by BladeWatch. A car head unit's peer restarted as a stranger every
time, which caused two problems:
- A dial-only phone's existing swarm redialed the dead key forever and never
  reached the car again. The swarm went on "connecting" for minutes, while a
  new swarm found the car in about 2 s.
- Every restart left a dead announcer on the DHT for its 20-minute record
  lifetime, and every later dialer timed out on it: 5 announcers after 5
  restarts, 4 of them dead, about 9 s per failed dial.

With the option, a restart mid-download was back on Pear in 3.2 s.

**Fixed: every desktop platform's native addons shipped in every app,
regardless of which platform it was built for.** `flutter_pear`'s pubspec.yaml
declared the macOS, Linux, and Windows worklet bundles as plain Flutter
assets, which are not per-platform -- an Android release APK carried all
three desktop hosts as dead weight (measured: 50MB in a real build), and each
desktop app carried the other two platforms' addons alongside its own.

Each desktop host's bundle + offloaded native addons now live inside
`flutter_pear_bare`'s own per-platform plugin folder instead, bundled only by
that platform's own native build: SwiftPM `resources`/CocoaPods
`resource_bundles` on macOS (both darwin hosts travel together -- a universal
binary decides which one it actually reads at OS launch, not at build time),
CMake `install(...)` on Linux and Windows. An Android release APK now
contains zero `assets/desktop` entries; a macOS/Linux/Windows build contains
only its own host(s). Verified end to end on real hardware for all three
desktop platforms (a real build, correct file placement, a worklet boot, and
a full P2P round trip over the public DHT), not by analogy.

No API change. `flutter build ios`/`android` need nothing from app
developers; a Linux or Windows consumer whose own build tooling somehow
referenced the old `assets/desktop/<host>/` path directly (nothing in this
repo did) would need to update it.

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

