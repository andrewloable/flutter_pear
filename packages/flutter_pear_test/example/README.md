# Example

In-memory fakes for unit-testing app code built on
[`package:flutter_pear`](https://pub.dev/packages/flutter_pear) — no radios,
no real peers, no worklet.

```dart
import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_pear/src/rpc.dart';
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';

final hub = FakeSwarmHub();
final rpcA = PearRpc(FakeBareWorklet(hub: hub));
final rpcB = PearRpc(FakeBareWorklet(hub: hub));
await rpcA.call(PearMethod.attachInfo);
await rpcB.call(PearMethod.attachInfo);

final topic = PearCrypto.unsafeTopicFromString('test-topic');
final swarmA = await PearSwarm.join(rpcA, topic);
final swarmB = await PearSwarm.join(rpcB, topic);
// swarmA/swarmB now see each other via swarmA.connections/swarmB.connections.
```
