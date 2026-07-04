# flutter_pear

The full [Pear](https://pears.com/) peer-to-peer stack as a Dart-idiomatic Flutter plugin. Build serverless, end-to-end-encrypted P2P apps — discovery, encrypted connections, append-only logs, key/value stores, file drives, and multi-writer sync — without writing a line of Kotlin, Swift, or JavaScript.

*(a short demo GIF of two-phone chat goes here once the example app runs — tracked in E7.6)*

> **Android only right now** — iOS is its own v0.2 milestone (not started), not a gate on this release. Requires Flutter SDK ≥ 3.24 (bundles Dart ≥ 3.5).
>
> **Status: pre-1.0, not yet on pub.dev.** Read [What works today](#what-works-today) below before assuming anything here is vaporware — the worklet is real, not a stand-in, and most of the API is already implemented and tested.
>
> Something stuck? Check [Troubleshooting](packages/flutter_pear/docs/troubleshooting.md) — install-time failures (slow/silent downloads, blocked fetches, checksum/ABI mismatches, manifest-merge conflicts) all have a symptom-first fix there. Still stuck? [Open an issue](https://github.com/andrewloable/flutter_pear/issues).
>
> Unofficial. Not affiliated with [Holepunch](https://holepunch.to/).

## Why

Pear (Bare + Hyperswarm + the Hypercore family) is a complete toolkit for building apps with no servers and no central authority. Its native surface is JavaScript. `flutter_pear` puts a typed Dart API in front of it so a Flutter dev gets Pear's guarantees with Flutter's ergonomics: `Future`s for calls, broadcast `Stream`s for events, `Uint8List` for bytes.

The design principle: **all P2P logic runs in JavaScript inside a bundled [Bare](https://github.com/holepunchto/bare) worklet; your Dart code is a typed remote control.** You never see the JS.

## What works today

flutter_pear is under active, incremental development — here's the honest breakdown of what actually runs versus what's still ahead, so you can tell the difference before relying on any of it.

- **The Bare Kit worklet is real, not a stand-in.** `Pear.start()` boots an actual Bare runtime running the bundled `pear-end` JS — not a native echo. This has been code-reviewed and confirmed booting cleanly on an Android emulator with a live Hyperswarm join/relay round trip. What hasn't happened yet: the physical **two-device** proof (DHT discovery + Noise handshake + reconnect between two independent phones) — the project's go/no-go gate, deliberately run *first* in the final hardware-validation pass, once every epic's automated test suite (including everything below) is green. See [project_plan.md](project_plan.md) for the full milestone breakdown.
- **Every capability in the table below has a complete Dart wrapper and a complete, real `pear-end` JS implementation** — no stubs. Each is exhaustively unit/e2e-tested against `flutter_pear_test`'s in-memory fake (every happy path and every typed error path).
- **What hasn't happened yet for any of them: a real-hardware run.** Each wrapper has its own deferred "does the fake match the real worklet, and does two-device replication actually converge" test. All of these are tracked centrally and run right after the two-device worklet gate above passes — not scattered ad hoc.
- **This covers Android only.** iOS hasn't started (see the banner above) — it's its own v0.2 milestone, not a gate on this release. The two-device gate above is the Android v0.1 release's remaining blocker.
- **Not published to pub.dev yet.** `flutter pub add flutter_pear` (below) is the target install step for v0.1; today, point at this repo directly.

## Install

**Not yet on pub.dev.** Until v0.1 ships, point at the repo directly:

```yaml
dependencies:
  flutter_pear:
    git:
      url: https://github.com/andrewloable/flutter_pear
      path: packages/flutter_pear
      ref: <commit-sha>  # pin this -- without it you track the default branch's HEAD
```

Once published, this collapses to:

```bash
flutter pub add flutter_pear
```

Either way — native binaries and the P2P runtime resolve automatically via Gradle (no NDK, ABI, or Podfile edits).

Pre-1.0: **minor versions may break the API without notice.** Pin an exact version (or `ref:` commit, pre-publish) once you depend on this for real.

The first Android build downloads Bare Kit's native binaries (cached under each app's `build/flutter_pear_bare/bare-kit/`; delete that directory, or run `flutter clean`, to force a re-download).

Android only for now; iOS (Xcode + CocoaPods) is its own v0.2 milestone.

## Quick start — chat over Hyperswarm

Two phones that share a topic find each other over the internet and exchange end-to-end-encrypted messages, no server:

```dart snippet
import 'dart:convert';
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();

// A topic is a 32-byte rendezvous key both peers agree on out of band.
// unsafeTopicFromString is a GLOBAL, demo-only shortcut -- every device
// worldwide using the same string lands in the same room. Real apps
// derive a topic from a PearPairing invite instead (see the coverage
// table below).
final topic = PearCrypto.unsafeTopicFromString('my-secret-room');
final swarm = await pear.join(topic);

swarm.connections.listen((PearConnection conn) {
  conn.data.listen((bytes) {
    print('peer: ${utf8.decode(bytes)}');
  });
  conn.write(utf8.encode('hello from Flutter'));
});

// ... later
await swarm.leave();
await pear.dispose();
```

Expected output on each phone, once the other side's message arrives:

```
peer: hello from Flutter
```

Everything is `Future`s and `Stream`s; keys are a `PearKey` value type with hex helpers (z-base-32 is planned, not yet implemented).

## API coverage

| Capability | Dart class | Status |
|---|---|---|
| Bare worklet lifecycle | `BareWorklet` | Real worklet boots + runs, emulator-verified; two-device hardware proof pending |
| Discovery + encrypted connections (Hyperswarm) | `PearSwarm`, `PearConnection` | Implemented, fake-tested; hardware proof pending |
| Keypairs, topics, hashes | `PearCrypto` | SHA-256 topics/hashes implemented; real per-device keypairs not yet exposed (untracked, not gating v0.1 — `PearPairing` already covers real key exchange for invites) |
| Append-only logs (Corestore / Hypercore) | `PearStore`, `PearCore` | Implemented, fake-tested; hardware proof pending |
| Key/value store (Hyperbee) | `PearBee` | Implemented, fake-tested; hardware proof pending |
| File drive + mirror-to-disk (Hyperdrive) | `PearDrive` | Implemented, fake-tested; hardware proof pending |
| Multi-writer sync (Autobase, prebuilt recipes) | `PearBase` | Implemented, fake-tested; hardware proof pending |
| Invites / device linking (blind pairing) | `PearPairing` | Implemented, fake-tested; hardware proof pending |

"Hardware proof pending" means real-worklet/physical-device validation is deliberately deferred to one final pass (see [What works today](#what-works-today)) — the automated test suite for every row above is green today.

App lifecycle (suspend/resume) is auto-wired to `AppLifecycleState` and overridable — see [Background execution](#background-execution).

## Learn more

- [Concepts](packages/flutter_pear/docs/concepts.md) — topics vs. invites (read this before you ship `unsafeTopicFromString` anywhere real), the worklet model, replication, lifecycle.
- How-tos: [chat](packages/flutter_pear/docs/howto-chat.md), [file sync](packages/flutter_pear/docs/howto-filesync.md), [pairing](packages/flutter_pear/docs/howto-pairing.md) — complete, copy-pasteable walkthroughs with expected output.
- [Error catalog](packages/flutter_pear/ERRORS.md) — every error code's problem, cause, and fix.
- [Troubleshooting](packages/flutter_pear/docs/troubleshooting.md) — install-time failures (Gradle fetch, checksum, ABI, manifest merge) that runtime error codes can't catch.

## Testing your app

`flutter_pear_test` ships in-memory fakes for the full API — swarm, Corestore/Hypercore, Hyperbee, Hyperdrive, Autobase, and blind pairing — so you can unit-test your P2P logic without radios or real peers.

## Background execution

iOS and Android aggressively suspend background apps, which can drop swarm connections. `flutter_pear` wires suspend/resume to the app lifecycle by default; [`packages/flutter_pear/BACKGROUND_EXECUTION.md`](packages/flutter_pear/BACKGROUND_EXECUTION.md) covers what Android actually permits (foreground service, OS suspend timing) so you can set expectations correctly. iOS's own background limits are undocumented until the v0.2 iOS milestone starts.

## Development setup

This is a [melos](https://melos.invertase.dev/) monorepo. To work on it you need:

- **Flutter SDK ≥ 3.24** (bundles Dart ≥ 3.5)
- **Melos ≥ 6** — `dart pub global activate melos`
- **JDK 17 + Android SDK/NDK** to build the plugin and example (Android-only for now)
- **Node.js ≥ 18 + npm**, plus **bare-pack** (`npm i -g bare-pack`) *only* if you change the `pear-end/` worklet JS
- iOS (Xcode + CocoaPods) isn't needed yet — it's the separate v0.2 milestone

```bash
melos bootstrap        # link packages + pub get
melos run analyze
melos run test --no-select
```

The example's Android runner is checked in — no `flutter create` hydrate step. Two-device chat demo:

```bash
flutter devices                       # note the device IDs for both phones/emulators
cd packages/flutter_pear_example
flutter run -d <device-id-A>          # terminal 1 -- phone/emulator A
flutter run -d <device-id-B>          # terminal 2 -- phone/emulator B
```

No second phone handy? Two Android emulators work identically (Hyperswarm/DHT discovery doesn't care that both peers are virtual) — boot a second AVD alongside whichever one's already running and use its device ID the same way:

```bash
flutter emulators                          # list available AVDs
flutter emulators --launch <avd-id>        # boot a second, distinct AVD
```

Enter the same room name on both, tap **Join** — messages sent on one appear on the other, with the connection-state banner (discovering/connecting/connected/failed) visible the whole time.

**One-phone path:** only one physical/emulated Android device? `flutter_pear_example` ships a desktop CLI peer that joins the same room from your laptop instead of a second phone (an emulator's NAT often breaks UDP hole-punching a real second device wouldn't hit; this also doubles as a scriptable peer for CI):

```bash
cd packages/flutter_pear_example
dart run flutter_pear_example:peer --topic my-secret-room   # same room name as the phone
```

Type a line + Enter to send once it connects; incoming messages print as `peer: <message>`. Exits with a nonzero code if no peer connects within `--timeout <seconds>` (default 30), so it's usable as a CI assertion. It runs as a plain Node process (see `tool/peer.js`'s own doc for why), reusing the exact Hyperswarm version pear-end bundles for the worklet — no separate install beyond the Node.js already required for `pear-end/`.

**Doctor:** `dart run flutter_pear:doctor` (from `packages/flutter_pear`) runs runtime connectivity diagnostics — real Hyperswarm DHT bootstrap reachability, a NAT/firewall estimate, and a local two-process loopback self-test — printing a `[PASS]`/`[FAIL]`/`[INFO]` line per check and naming the blocker (with a docs anchor) on a UDP-blocked network instead of shrugging. It's desktop-side network diagnostics, not a real worklet boot: a plain `dart run` CLI has no Flutter engine to drive `BareWorklet`'s platform channels the way a real app does, so that check only runs if a `bare` CLI is on `PATH`, else it's reported as an explicit skip.

**Release packaging (E4.5):** `flutter build appbundle --release` and `flutter build apk --release --split-per-abi` both build and run correctly — verified on a real arm64-v8a Android emulator (release-mode R8/native-lib loading, not just debug). Both artifact types include a 32-bit `armeabi-v7a` variant by default that is **missing this plugin's native libraries entirely** (Flutter's own ABI splitting has no way to know a dependency only ships arm64-v8a/x86_64 binaries) — installing that specific variant on a device that reports `armeabi-v7a` support (a real 32-bit device, or an ARM-translation layer) fails fast with a clear error at worklet-start time instead of a cryptic native-loader crash; it is not a supported configuration. Always ship the `arm64-v8a`/`x86_64` splits (or let an app bundle's per-device delivery pick one of those).

## Contributing

Roadmap and design rationale live in [project_plan.md](project_plan.md). The low-level `flutter_pear_bare` core is deliberately small; the per-data-structure packages (`PearBee`, `PearDrive`, `PearBase`, …) are the best places to contribute.

## License

flutter_pear is **MIT** © 2026 Andrew Loable — see [LICENSE](LICENSE).

It bundles the Pear stack (Bare Kit + Hyper\* modules), which is **MIT /
Apache-2.0** — all permissive, no copyleft. Redistributed attributions ship in
`THIRD_PARTY_LICENSES` (generated at build time). See [LICENSING.md](LICENSING.md)
for the full dependency breakdown and obligations.
