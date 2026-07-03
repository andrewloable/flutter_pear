# flutter_pear_test

In-memory fakes (fake swarm, fake worklet) for unit-testing [flutter_pear](../flutter_pear)
apps without radios or real peers. See the [repository README](../../README.md) for the
overview.

> Early / pre-release. Scaffolded, no fakes implemented yet.

The fake conforms to `flutter_pear`'s RPC schema (`PearMethod`/`PearEventName`/`PearErrorCode`
in `package:flutter_pear/src/schema.dart`) — it is a **conformance consumer**, never a
co-author: when the two disagree, the schema wins and the fake is fixed to match.
