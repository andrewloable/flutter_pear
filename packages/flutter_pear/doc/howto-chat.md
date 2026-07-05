# How-to: chat over Hyperswarm

Join a topic and exchange bytes with whoever else joins it — the same flow
the example app and the top-level README's quick start use, expanded with
the connection-state stream so you can show the user what's actually
happening instead of a spinner that never explains itself.

See [concepts.md](concepts.md#topics-vs-invites) first if you haven't —
this uses `unsafeTopicFromString`, which is demo-only.

```dart snippet
import 'dart:convert';
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();
final topic = PearCrypto.unsafeTopicFromString('my-chat-room');
final swarm = await pear.join(topic);

// currentState is readable the instant join() returns -- a plain broadcast
// Stream can't replay a past transition to a listener that subscribes late,
// so read this first, then keep listening to `state` for what happens next.
print('state: ${swarm.currentState.state}');
swarm.state.listen((status) {
  final reason = status.error != null ? ' (${status.error})' : '';
  print('state: ${status.state}$reason');
});

swarm.connections.listen((PearConnection conn) {
  conn.data.listen((bytes) => print('peer: ${utf8.decode(bytes)}'));
  conn.write(utf8.encode('hello from Flutter'));
});

// ... later, e.g. when the chat screen closes
await swarm.leave();
await pear.dispose();
```

Expected output on each phone, once the other side joins and the first
message arrives:

```
state: PearSwarmState.discovering
state: PearSwarmState.connecting
state: PearSwarmState.connected
peer: hello from Flutter
```

## If it never reaches `connected`

`state` eventually emits `PearSwarmState.failed` with a typed reason rather
than hanging forever — a hostile network (UDP blocked by a firewall, a
carrier NAT that can't hole-punch) is a real, expected outcome, not a bug.
Show `status.error` to the user; see [../ERRORS.md](../ERRORS.md) for what
each reason code means and how to react to it.
