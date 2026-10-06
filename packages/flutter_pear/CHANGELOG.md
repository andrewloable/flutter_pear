## 0.4.9

**Added: an owner relay, for two peers that hole punching cannot connect.** No
breaking change; nothing changes unless an app calls the new method.
`Pear.setRelayKey(relayKey)` routes this peer's connections through a blind
relay (holepunchto/blind-relay) that its owner runs on a public server, when
no direct connection is possible: both peers behind randomizing NATs, such as
a device on carrier CGNAT and a phone on mobile data. hyperdht does not even
try to punch between two randomizing NATs (`HOLEPUNCH_DOUBLE_RANDOMIZED_NATS`).

- **One key, set on both peers and on the relay.** The relay key is 12
  digits; spaces and dashes are ignored (`Pear.normalizeRelayKey` validates
  input). The relay accepts only peers that derived its member key from it,
  so a peer without the key is refused. `setRelayKey(null)` turns it off.
  It returns the relay's public key while on (not secret: the relay's own
  log prints it, so an owner can compare), and null when off.
- **The derivation is a protocol.** salt = BLAKE2b-128 of
  `flutter_pear relay v1 salt`; root = Argon2id13 of the 12 digits, opslimit
  2, memlimit 64 MiB, 32 bytes; seed(role) = BLAKE2b-256 of
  `flutter_pear relay v1 <role>` followed by root; Ed25519 key pairs for
  `server` (the relay) and `member` (every peer). Test vector: key
  `4821-0937-5562` gives server `7d040c71...2a027d` and member
  `9c84075c...278e82b` (full keys in `pear-end/test/relay-key.test.js`).
- **Where it applies.** hyperdht opens relay connections with the DHT's
  `defaultKeyPair`, so that is what the member key pair replaces; the swarm's
  own key pair, `--persistent-identity` included, never changes. WHEN to relay
  stays Hyperswarm's policy: only while this peer's NAT randomizes, or after a
  hole punch failed. Direct connections are never relayed.
- New RPC `relay.set` (`PearMethod.relaySet`) and error code
  `INVALID_RELAY_KEY` (`PearErrorCode.invalidRelayKey`); a malformed key
  changes nothing. The key is never logged, echoed or stored by pear-end.
- Argon2id runs through sodium's async call, off the worklet's event loop.
  `pear-end` now requires `sodium-universal` directly, pinned at 5.0.1 (the
  version it already bundled).

Found by BladeWatch (BladeWatch-a7mu): a car on its built-in SIM could not be
reached from a phone on mobile data at all. BladeWatch's `relay/` folder holds
the reference relay server.

Requires `flutter_pear_bare` 0.4.9 (`>=0.4.9 <0.4.10`).

**Requires Flutter 3.44 / Dart 3.12** (was 3.24 / 3.5), because
`flutter_pear_bare` moved to Flutter's built-in Kotlin. pub keeps apps on
older Flutter on 0.4.8. `flutter_pear:doctor` drops its iOS/macOS
"Flutter too old for SwiftPM" check, which that floor makes unreachable.

## 0.4.8

**Added: Android TVs and other 32-bit ARM (`armeabi-v7a`) devices.** No
breaking change and no API change. A flutter_pear app now installs and runs
on devices whose userspace is 32-bit only, such as many Android TVs and
set-top boxes. Up to 0.4.7 it either failed to install there
(`INSTALL_FAILED_NO_MATCHING_ABIS`) or failed at worklet start. The native
libraries live in `flutter_pear_bare` 0.4.8; see its changelog for the
device this was found on, the API 29 check, and the APK size cost.

`pear-end.bundle` is byte-for-byte unchanged: it resolves its native addons
per platform (`android`), not per CPU architecture, so the same bundle
loads the 32-bit addons. `dart run flutter_pear:pack` now also links
`pear-end`'s addons for `armeabi-v7a`.

Requires `flutter_pear_bare` 0.4.8 (`>=0.4.8 <0.4.9`).

## 0.4.7

**Added: why a connection closed.** No breaking change. `pear-end`'s
`connection.close` event now carries `stats`, and `PearConnection.closeStats`
exposes them once the connection's `data` stream is done:

- `error` -- null for a clean close by either side, else the error's code
  (`ETIMEDOUT`) or its message with anything address- or key-shaped masked;
- `ageMs`, `bytesIn`, `bytesOut`;
- `rtt` and `rtoCount` -- UDX's smoothed round-trip time and retransmission
  timeouts, sampled as the stream ended -- and `retransmits`;
- `ipv6` -- the remote address family, never the address.

One object per close and nothing per packet, so it is always on; whether to
log it is the host's call. The `connection-error` diagnostic's message is
masked the same way. Found by BladeWatch (rdtj.34): Pear drops over mobile
data could not be told apart -- UDX timeouts under load, or a carrier NAT
mapping expiring. `closeStats` is null from an older `pear-end`.

## 0.4.6

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

**Changed: `flutter_pear` now requires `flutter_pear_bare` 0.4.6
(`>=0.4.6 <0.4.7`), not `^0.4.1`.** The desktop bundle now ships inside `flutter_pear_bare`, and
`Pear.start()` checks the bundle's version hash for an exact match, so any other
`flutter_pear_bare` version fails on desktop with `bundleVersionMismatch` (or,
before 0.4.6, has no desktop bundle at all). Pub resolves this for you; the
two packages have always been released together anyway.

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

