# Example

This is the low-level worklet transport — most app code uses
[`package:flutter_pear`](https://pub.dev/packages/flutter_pear) instead,
which wraps this with the RPC contract, typed errors, and every
data-structure wrapper. See that package's example for a full two-phone
chat demo.

Direct usage of this package's low-level surface:

```dart
import 'package:flutter_pear_bare/flutter_pear_bare.dart';

final worklet = await BareWorklet.start();
worklet.incoming.listen((frame) => print('frame: $frame'));
worklet.onCrash.listen((crash) => print('crashed: ${crash.reason}'));
// ... later
await worklet.terminate();
```
