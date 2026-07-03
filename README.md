# flutter_pear

The full [Pear](https://pears.com/) peer-to-peer stack as a Dart-idiomatic Flutter plugin. Build serverless, end-to-end-encrypted P2P apps — discovery, encrypted connections, append-only logs, key/value stores, file drives, and multi-writer sync — without writing a line of Kotlin, Swift, or JavaScript.

> **Status: early / pre-release.** The API below is the target design, not yet shipped — see [project_plan.md](project_plan.md) for the roadmap and milestones. Not ready for production use.
>
> Unofficial. Not affiliated with [Holepunch](https://holepunch.to/).

## Why

Pear (Bare + Hyperswarm + the Hypercore family) is a complete toolkit for building apps with no servers and no central authority. Its native surface is JavaScript. `flutter_pear` puts a typed Dart API in front of it so a Flutter dev gets Pear's guarantees with Flutter's ergonomics: `Future`s for calls, broadcast `Stream`s for events, `Uint8List` for bytes.

The design principle: **all P2P logic runs in JavaScript inside a bundled [Bare](https://github.com/holepunchto/bare) worklet; your Dart code is a typed remote control.** You never see the JS.

## Install

```bash
flutter pub add flutter_pear
```

One line — native binaries and the P2P runtime resolve automatically via Gradle and CocoaPods. No NDK, ABI, or Podfile edits.

Mobile first (iOS + Android); desktop later.

## Quick start — encrypted chat (target API)

Two phones that share a topic find each other over the internet and exchange end-to-end-encrypted messages, no server:

```dart
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();

// A topic is a 32-byte rendezvous key both peers agree on out of band.
final topic = PearCrypto.topicFromString('my-secret-room');
final swarm = await pear.join(topic);

swarm.connections.listen((PearConnection conn) {
  conn.data.listen((bytes) {
    print('peer: ${utf8.decode(bytes)}');
  });
  conn.write(utf8.encode('hello from Flutter'));
});

// ... later
await swarm.leave(topic);
await pear.dispose();
```

Everything is `Future`s and `Stream`s; keys are a `PearKey` value type with hex/z32 helpers.

## API coverage

| Capability | Dart class | Target version |
|---|---|---|
| Bare worklet lifecycle | `BareWorklet` | 0.1 |
| Discovery + encrypted connections (Hyperswarm) | `PearSwarm`, `PearConnection` | 0.1 |
| Keypairs, topics, hashes | `PearCrypto` | 0.1 |
| Append-only logs (Corestore / Hypercore) | `PearStore`, `PearCore` | 0.2 |
| Key/value store (Hyperbee) | `PearBee` | 0.3 |
| File drive + mirror-to-disk (Hyperdrive) | `PearDrive` | 0.3 |
| Multi-writer (Autobase) | `PearBase` | 0.4 |
| Invites / device linking (blind pairing) | `PearPairing` | 0.4 |

App lifecycle (suspend/resume) is auto-wired to `AppLifecycleState` and overridable.

## Testing your app

`flutter_pear_test` ships in-memory fakes (fake swarm, fake core) so you can unit-test your P2P logic without radios or real peers.

## Background execution

iOS and Android aggressively suspend background apps, which can drop swarm connections. `flutter_pear` wires suspend/resume to the app lifecycle by default; the docs cover what each platform actually permits (Android foreground service, iOS limits) so you can set expectations correctly.

## Development setup

This is a [melos](https://melos.invertase.dev/) monorepo. To work on it you need:

- **Flutter SDK ≥ 3.24** (bundles Dart ≥ 3.5)
- **Melos ≥ 6** — `dart pub global activate melos`
- **JDK 17 + Android SDK/NDK** to build the plugin and example (Android-only for now)
- **Node.js ≥ 18 + npm**, plus **bare-pack** (`npm i -g bare-pack`) *only* if you change the `pear-end/` worklet JS
- iOS (Xcode + CocoaPods) isn't needed yet — it lands in M1

```bash
melos bootstrap        # link packages + pub get
melos run analyze
melos run test
```

Example runners aren't committed; hydrate once with `cd packages/flutter_pear_example && flutter create --platforms=android .`, then `flutter run` on an Android device.

## Contributing

Roadmap and design rationale live in [project_plan.md](project_plan.md). The low-level `flutter_pear_bare` core is deliberately small; the per-data-structure packages (`PearBee`, `PearDrive`, `PearBase`, …) are the best places to contribute.

## License

flutter_pear is **MIT** © 2026 Andrew Loable — see [LICENSE](LICENSE).

It bundles the Pear stack (Bare Kit + Hyper\* modules), which is **MIT /
Apache-2.0** — all permissive, no copyleft. Redistributed attributions ship in
`THIRD_PARTY_LICENSES` (generated at build time). See [LICENSING.md](LICENSING.md)
for the full dependency breakdown and obligations.
