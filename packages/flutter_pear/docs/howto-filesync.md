# How-to: file sync with PearDrive

Share a folder of files with a peer, keyed by virtual path — `PearDrive`
moves bytes by **local file path**, never in-memory, so a multi-hundred-MB
transfer can't blow up memory the way pushing raw bytes through JSON would.

This assumes you've already joined a topic and have a `PearConnection` —
see [howto-chat.md](howto-chat.md) if you haven't.

```dart snippet
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();
final topic = PearCrypto.unsafeTopicFromString('file-sync-demo');
final swarm = await pear.join(topic);
final drive = await pear.drive(name: 'shared-files');

// Replicate this drive with every peer that connects -- both sides call
// this the same way, order doesn't matter, and it's safe to call again on
// a fresh connection after a reconnect.
swarm.connections.listen((PearConnection conn) {
  drive.replicate(conn);
});

// Add a local file to the drive under a virtual path.
await drive.put('/notes.txt', '/local/path/to/notes.txt');

// Once a peer has replicated their side, pull one of their files to disk.
if (await drive.exists('/shared/photo.jpg')) {
  await drive.get('/shared/photo.jpg', '/local/path/to/downloaded-photo.jpg');
}

// List everything currently in the drive.
await for (final path in drive.list()) {
  print('drive has: $path');
}

// ... later
await drive.close();
await swarm.leave();
await pear.dispose();
```

Expected output (paths will differ based on what's actually in the drive):

```
drive has: /notes.txt
drive has: /shared/photo.jpg
```

## Syncing an entire local folder

`drive.mirrorToDisk(localDir)` mirrors the ENTIRE drive to a local
directory in one call — only changed files actually copy, so calling it
repeatedly (e.g. on every replication update) is cheap:

```dart
final result = await drive.mirrorToDisk('/local/path/to/synced-folder');
print('added ${result.added}, changed ${result.changed}, removed ${result.removed}');
```

Like every other Pear data structure, a drive works fully offline — `put`,
`get`, and `list` all succeed against your own local copy whether or not a
peer is currently connected. See [concepts.md](concepts.md#replication-mental-model)
for the general replication model this follows.
