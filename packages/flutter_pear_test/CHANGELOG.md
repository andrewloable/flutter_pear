## 0.3.1

Version bump only, in lockstep with `flutter_pear`/`flutter_pear_bare`'s
0.3.1 (all three desktop platforms now auto-fetch their own `bare` runtime,
plus `doctor` CLI fixes — see those packages' own CHANGELOGs). The native
`bare_runtime_missing` platform error this release adds is surfaced through
`flutter_pear`'s existing `PearException(BARE_RUNTIME_MISSING)` translation,
which this package's fake does not need to reproduce (it never spawns a
real subprocess). No code changes here.

## 0.3.0

Version bump only, in lockstep with `flutter_pear`/`flutter_pear_bare`'s
0.3.0 (macOS/Linux/Windows desktop support — see those packages' own
CHANGELOGs). No new fake-side API surface was needed: `Pear.platformInfo`'s
desktop-specific values are pure Dart, `defaultTargetPlatform`-based, same
as 0.2.0's Android/iOS handling. No code changes here.

## 0.2.1

Docs-only patch: this package's own README had relative links that break on
pub.dev (`../flutter_pear`, `../../README.md`) — made absolute. No code
changes.

## 0.2.0

Version bump only, in lockstep with `flutter_pear`/`flutter_pear_bare`'s
0.2.0 (all three published packages always move together — see
`COMPATIBILITY.md`'s versioning policy). No new fake-side API surface was
needed for `Pear.platformInfo`: it's a pure Dart, `defaultTargetPlatform`-based
release constant with no worklet round trip at all, so it works identically
whether tested against the real worklet or `FakeBareWorklet` — see this
package's own library doc comment for the exact test pattern (drive it via
`debugDefaultTargetPlatformOverride`, no fake-worklet involvement needed).
The existing drive-mirror warning event parity (symlink/deep-path
rejection) already covered iOS's hostile-drive-mirroring test needs with no
fake changes required either.

## 0.2.0-dev.1

Prerelease of 0.2.0 above, published first so the upgrade fixtures could
validate against real hosted pub.dev archives before the stable release.

## 0.0.1

- In-memory fake swarm/worklet, conforming to `flutter_pear`'s RPC schema
  (`PearMethod`/`PearEventName`/`PearErrorCode`) and exhaustively tested
  against every `flutter_pear` data-structure wrapper (`PearStore`/`PearCore`,
  `PearBee`, `PearDrive`, `PearPairing`, `PearBase`) — no radios or real peers
  required.
