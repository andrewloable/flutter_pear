# How-to: pairing with invites

`unsafeTopicFromString` is fine for a demo where you control both devices,
but a real app needs to introduce two devices that have never met — that's
what `PearPairing` is for. See [concepts.md](concepts.md#topics-vs-invites)
for why this matters before you ship a shared-string topic to real users.

One device creates an invite and shares it (a QR code, a short code, a deep
link — `flutter_pear` doesn't care how the bytes get to the other device).
The other device accepts it. Both ends end up with the same 32-byte key,
privately, without either one having picked or leaked a guessable string.

## Device A: create the invite

```dart snippet
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();

final invite = await pear.createInvite();
invite.candidates.listen((candidate) async {
  // Decide what this pairing session shares once confirmed -- here, a
  // fresh topic key for the two devices to chat on next.
  final sharedTopic = PearCrypto.unsafeTopicFromString('paired-room');
  await candidate.confirm(sharedTopic);
  final swarm = await pear.join(sharedTopic);
  print('paired -- joined shared topic ${swarm.topic.hex}');
});

// Encode invite.invite as a QR code (or short code, or send it over any
// channel your app already has) and show it to the other device.
final inviteBytes = invite.invite;
print('invite ready, ${inviteBytes.length} bytes');

// ... later, once you're done accepting pairing requests
await invite.revoke();
```

Expected output: the invite line as soon as it's created, the paired line
once a candidate actually confirms (i.e. once device B accepts it below):

```
invite ready, ... bytes
paired -- joined shared topic <64-hex-char topic key>
```

## Device B: accept the invite

```dart snippet
import 'dart:typed_data';
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();

// Stand-in for whatever your app's QR scanner / paste box / deep-link
// handler decoded back into bytes -- this is device A's invite.invite.
final Uint8List scannedInviteBytes = Uint8List(0);

final sharedTopic = await pear.acceptInvite(scannedInviteBytes);
final swarm = await pear.join(sharedTopic);
print('paired -- joined shared topic ${swarm.topic.hex}');
```

Expected output once device A's `candidate.confirm(...)` runs:

```
paired -- joined shared topic <64-hex-char topic key>
```

## What can go wrong

`acceptInvite` throws a typed `PearException` rather than hanging if the
invite bytes are undecodable, the invite already expired (`createInvite`'s
optional `ttl`), or nobody confirms before its own bounded timeout — see
[../ERRORS.md](../ERRORS.md) for `INVALID_INVITE`, `INVITE_EXPIRED`, and
`PAIRING_TIMEOUT`.
