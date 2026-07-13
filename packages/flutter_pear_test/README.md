# flutter_pear_test

In-memory fakes (fake swarm, fake worklet) for unit-testing
[flutter_pear](https://pub.dev/packages/flutter_pear) apps without radios or
real peers. See the [repository README](https://github.com/andrewloable/flutter_pear#readme)
for the overview.

> Pre-1.0, published on pub.dev. The in-memory fake swarm/worklet is implemented
> and exhaustively tested against every `flutter_pear` data-structure wrapper
> (`PearStore`/`PearCore`, `PearBee`, `PearDrive`, `PearPairing`, `PearBase`) —
> not a scaffold.
>
> **This package is platform-agnostic by construction.** It's pure Dart with no
> native code, no radios, and no real peers, so it behaves identically whether
> your app targets Android, iOS, macOS, Linux, or Windows — and it runs in a
> plain `flutter test` with no device, emulator, or `bare` runtime attached.

The fake conforms to `flutter_pear`'s RPC schema (`PearMethod`/`PearEventName`/`PearErrorCode`
in `package:flutter_pear/src/schema.dart`) — it is a **conformance consumer**, never a
co-author: when the two disagree, the schema wins and the fake is fixed to match.
