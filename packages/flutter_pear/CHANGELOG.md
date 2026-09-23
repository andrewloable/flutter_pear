## 0.4.2

Dependency refresh plus an iOS packaging fix. No API change.

**pear-end JS dependencies bumped to current upstream patches** — all patch or
minor, no breaking API changes: `autobase` 7.28.1 → 7.28.2, `bare-fs` 4.7.3 →
4.8.1, `bare-path` 3.0.1 → 3.1.2, `bare-pipe` `^4.2.2` → 4.3.1 (the last
range-float pin, now exact like its siblings), `compact-encoding` 3.3.0 →
3.5.0, `corestore` 7.11.0 → 7.12.5, `hyperdrive` 13.3.2 → 13.3.4, `hyperswarm`
4.17.0 → 4.17.2, `protomux` 3.11.0 → 3.12.0, `streamx` 2.28.0 → 2.28.1, and
`hypercore` 11.33.5 → 11.36.1 transitively.

The two most valuable fixes here are both mobile-network behaviours this
plugin is squarely exposed to and cannot work around from the Dart side:
hyperswarm now forces a relay fallback on `CANNOT_HOLEPUNCH` (carrier NAT that
refuses to hole-punch), and properly re-checks `dht.online` across a network
change (wifi-to-cellular handoff). `autobase` 7.28.2 fixes `_teardown` freeing
the lock too early.

`corestore` 7.12.0 removed its implicit flush on `suspend()`. This does not
affect flutter_pear: the pear-end never calls `corestore.suspend()` at all —
suspension is handled natively at the Bare Kit worklet level — re-confirmed
against the bundle as it ships here.

**Fixed: the repacked BareKit iOS xcframework was a corrupt zip.** Xcode could
not resolve the SwiftPM binary target on 0.4.0 or 0.4.1, failing with `invalid
archive returned from <url> which is required by binary target 'BareKit'`
before any code compiled. The asset downloaded intact and its checksum matched
the pin — the archive itself was malformed. `bin/pack.dart`'s repack step
synthesized a zero-length root directory entry, which `package:archive`'s
`ZipEncoder` writes with a DEFLATE payload nothing can inflate; `unzip -t`
fails on exactly that one entry. It went unnoticed because `ditto` tolerates
it and the 0.4.0 Bare Kit bump was validated on Android only. The repack no
longer emits that entry, and a regression test now runs `unzip -t` over the
produced asset.

A corrected asset is published at the new release tag `barekit-v2.5.5-1`
(sha256 `bfbbe1f6…`), and 0.4.2 points at it. The original, corrupt
`barekit-v2.5.5` asset is deliberately left in place rather than overwritten.

> **iOS on 0.4.0 / 0.4.1 cannot be rescued — upgrade to 0.4.2.** Those
> releases are immutable on pub.dev and pin the corrupt asset's checksum, so
> no corrected archive could ever satisfy them. Leaving the old asset
> reachable keeps their failure identical rather than swapping it for a
> confusing checksum mismatch. Nothing is stranded by this: iOS never
> resolved at all on 0.4.0/0.4.1.

No `minSdk` change: Android still requires `minSdk = 29` in every consuming
app, as 0.4.0 introduced.

**Breaking for iOS and macOS consumers: the deployment-target floors are
raised to iOS 15.0 and macOS 12.0** (from iOS 13.0 and macOS 10.15.4).

The old floors were not merely untested, they were unbuildable. Xcode 27
refuses to target macOS below 12.0 outright — *"the macOS deployment target
'MACOSX_DEPLOYMENT_TARGET' is set to 10.15.4, but the range of supported
deployment target versions is 12.0 to 27.0.x"* — so a consumer following this
project's own README instruction to set 10.15.4 got a hard build failure.
Flutter's current templates ship `IPHONEOS_DEPLOYMENT_TARGET = 15.0` and
`MACOSX_DEPLOYMENT_TARGET = 12.0`, and `flutter build ios` auto-migrates older
projects up to 15.0 regardless of what this package claimed.

This is the same failure the 0.4.0 `minSdk` bump fixed on Android: a floor the
package advertised, nothing validated, and the toolchain would not honour.
Every iOS/macOS check now agrees on the real values — both podspecs, both
`Package.swift` files, `dart run flutter_pear:doctor`, the README, and
`COMPATIBILITY.md`.

**What you need to do:** an app created with a current Flutter already meets
both floors and needs no change. An older project carried forward may still
sit below them — `dart run flutter_pear:doctor --fix` raises the macOS target
for you, and `flutter build ios` raises the iOS one itself.


