## 0.4.9

**Added: the owner relay in the fake.** `FakeBareWorklet` answers
`PearMethod.relaySet` with the same validation as `pear-end` (12 digits,
spaces and dashes ignored, `PearErrorCode.invalidRelayKey` otherwise, a
malformed key changes nothing), and `FakeBareWorklet.relayKey` exposes the key
the last successful call applied, or null while off, so app tests can assert
what `Pear.setRelayKey` sent. The fake relays nothing: every fake peer already
reaches every other directly.

**Requires `flutter_pear` 0.4.9.** The constraint was still `^0.4.1`, which
let pub pick `flutter_pear` 0.4.8 (no `relaySet`) and fail to compile.
Also requires Flutter 3.44 / Dart 3.12 (was 3.24 / 3.5), with
`flutter_pear_bare`'s move to built-in Kotlin.

## 0.4.8

No code or behaviour change to this package. Version bump to stay in
lockstep with `flutter_pear` and `flutter_pear_bare` 0.4.8, which add 32-bit
ARM (`armeabi-v7a`) Android support for Android TVs -- native libraries only,
which the in-memory fake this package provides never loads.

## 0.4.7

No code or behaviour change to this package. Version bump to stay in
lockstep with `flutter_pear` and `flutter_pear_bare` 0.4.7. `flutter_pear`
adds `PearConnection.closeStats`, reporting why a connection closed (error,
age, bytes, RTT) -- entirely inside `pear-end` and the real `PearConnection`
wrapper, so the in-memory fake this package provides is untouched.

## 0.4.6

No code or behaviour change to this package. Version bump to stay in
lockstep with `flutter_pear` and `flutter_pear_bare` 0.4.6. Their changes are an
opt-in persistent swarm identity inside `pear-end`, desktop bundles moving
into `flutter_pear_bare`, and a Windows `terminate()` hang fix. None of them
touches the in-memory fake.

## 0.4.5

The in-memory hub honours `join(announce:, acceptUnannounced:)`: two worklets
connect only if at least one announces and each side can attribute the
connection (by the other's announcement, or by accepting unannounced), as with
real Hyperswarm + pear-end. Where pear-end would leave a dial-only peer holding
a silent connection, the fake makes none.

## 0.4.4

The in-memory fake now answers `dht.status` like the real worklet does: an
in-memory hub is always reachable, so it always reports
`{online: true, firewalled: false}`. Version bump to stay in lockstep with
`flutter_pear` 0.4.4.

