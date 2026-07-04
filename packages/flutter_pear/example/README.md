# Example

A full runnable two-phone chat demo lives at
[`packages/flutter_pear_example`](../../flutter_pear_example) in this repo (a
separate Flutter app, since `flutter_pear` itself is a plugin, not an app).

Minimal usage — join a topic and exchange bytes with whoever else joins it:

```dart
import 'dart:convert';
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();
final topic = PearCrypto.unsafeTopicFromString('my-secret-room');
final swarm = await pear.join(topic);

swarm.connections.listen((PearConnection conn) {
  conn.data.listen((bytes) => print('peer: ${utf8.decode(bytes)}'));
  conn.write(utf8.encode('hello from Flutter'));
});
```

See the repository [README](../../../README.md)'s quick start for the full
walkthrough and expected output.
