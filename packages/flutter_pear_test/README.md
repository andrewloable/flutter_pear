# flutter_pear_test

In-memory fakes (fake swarm, fake worklet) for unit-testing
[flutter_pear](https://pub.dev/packages/flutter_pear) apps without radios or
real peers. See the [repository README](https://github.com/andrewloable/flutter_pear#readme)
for the overview.

> Pre-1.0, published on pub.dev. The in-memory fake swarm/worklet is implemented
> and exhaustively tested against every `flutter_pear` data-structure wrapper
> (`PearStore`/`PearCore`, `PearBee`, `PearDrive`, `PearPairing`, `PearBase`) —
> not a scaffold. What's still outstanding is the physical two-device hardware
> round trip, deliberately deferred to a final hardware-validation pass; this
> package's own fakes need no radios or real peers, so that gap doesn't affect
> using it.

The fake conforms to `flutter_pear`'s RPC schema (`PearMethod`/`PearEventName`/`PearErrorCode`
in `package:flutter_pear/src/schema.dart`) — it is a **conformance consumer**, never a
co-author: when the two disagree, the schema wins and the fake is fixed to match.
