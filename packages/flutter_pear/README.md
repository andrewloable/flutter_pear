# flutter_pear

The full [Pear](https://pears.com/) peer-to-peer stack as a Dart-idiomatic Flutter plugin. Build serverless, end-to-end-encrypted P2P apps — discovery, encrypted connections, append-only logs, key/value stores, file drives, and multi-writer sync — without writing a line of Kotlin, Swift, or JavaScript.

> **Platforms:** Android (stable, published) · iOS (new in 0.2.0, **SIMULATOR-VALIDATED** — see [iOS platform notes](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md) before shipping). Requires Flutter SDK ≥ 3.24 (bundles Dart ≥ 3.5).
>
> **Status: pre-1.0, published on pub.dev (v0.0.1).** The Bare Kit worklet is real (not a stand-in), and every data-structure wrapper (Corestore/Hypercore, Hyperbee, Hyperdrive, Autobase, blind pairing) is implemented and fake-tested end-to-end, with real-worklet validation on a real Android emulator and the iOS Simulator. Physical two-device hardware validation on both platforms is a documented follow-up, not a release gate. See the [full repository README](https://github.com/andrewloable/flutter_pear#readme) for the complete API coverage table.
>
> Something stuck? Check [Troubleshooting](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/troubleshooting.md). Still stuck? [Open an issue](https://github.com/andrewloable/flutter_pear/issues).
>
> Unofficial. Not affiliated with [Holepunch](https://holepunch.to/).

## Install

```bash
flutter pub add flutter_pear
```

Native binaries and the P2P runtime resolve automatically — Gradle on Android, SwiftPM (with a CocoaPods compat path) on iOS. No manual NDK, ABI, or Podfile edits on either platform.

Pre-1.0: **minor versions may break the API without notice.** Pin an exact version once you depend on this for real.

**Time to hello world (TTHW):** P50 ≤ 5 minutes / P90 ≤ 10 minutes of active work, zero `flutter_pear`-specific build-wiring steps beyond one copy-paste `Info.plist` block on iOS — "hello world" means the first Android-to-iOS message, not just a successful build.

## Quick start — chat over Hyperswarm

Two phones that share a topic find each other over the internet and exchange end-to-end-encrypted messages, no server:

```dart snippet
import 'dart:convert';
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();

// A topic is a 32-byte rendezvous key both peers agree on out of band.
// unsafeTopicFromString is a GLOBAL, demo-only shortcut -- every device
// worldwide using the same string lands in the same room. Real apps
// derive a topic from a PearPairing invite instead.
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

## Enable iOS on an existing Android app

Already on `flutter_pear` 0.1.x, Android-only? Five steps get you to iOS:

1. `flutter create --platforms=ios .` — plain Flutter, nothing `flutter_pear`-specific.
2. `flutter pub add flutter_pear:^0.2.0` — explicit, not a bare `flutter pub upgrade`: that command cannot cross the already-published `^0.0.1` caret. If you previously pinned `flutter_pear_bare` directly in your own `pubspec.yaml`, bump it the same way; if `pub add` reports a stale lock conflict, delete `pubspec.lock` and re-resolve.
3. Paste this into `ios/Runner/Info.plist` (copied from [iOS platform notes](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md#local-network-permission--the-top-sim-invisible-risk) — see that page for why, and for the full symptom table if you skip this step):
   ```xml
   <key>NSLocalNetworkUsageDescription</key>
   <string>flutter_pear demos connect directly to your other devices over the local network to exchange chat messages and files.</string>
   ```
   Adjust the description to your own app's actual local-network use — Apple requires it be accurate, not necessarily this exact wording.
4. `flutter run` on an iOS Simulator.
5. Exchange your first message with an Android peer — same `Pear.start()`/`join()` code as above, no platform branching required for the happy path.

**Received-file locations** (if your app uses `PearDrive`/file transfer) differ by platform, matching what `flutter_pear_example`'s own file-drop demo does: **iOS** saves into a `Documents` subtree (`path_provider`'s `getApplicationDocumentsDirectory()`), visible in the Files app; **Android** saves into the app's private files directory (`Context.getFilesDir()/received/`), not independently visible — open or share it through your app's own affordance (a `FileProvider` content URI + `ACTION_VIEW`, in the example app's case). Neither location is where the worklet's own protocol storage lives — see [Storage roots](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md#storage-roots-deliberately-non-configurable) for that.

## First-build download UX

Native binaries fetch once, then cache:

- **Android:** downloads Bare Kit's native binaries, cached under each app's `build/flutter_pear_bare/bare-kit/`; delete that directory, or run `flutter clean`, to force a re-download.
- **iOS (SwiftPM, the default):** downloads the repacked `BareKit.xcframework` (~107 MB), cached under `~/Library/Caches/org.swift.swiftpm`; delete that directory, or run `flutter clean`, to force a re-download.
- **iOS (CocoaPods compat path):** downloads the same artifact into `ios/Pods/flutter_pear_bare/barekit_cache/<version>/`; delete `ios/Pods/` and re-run `pod install` to force a re-download.

Both platforms fetch from the same upstream [holepunchto/bare-kit](https://github.com/holepunchto/bare-kit) release; iOS's SwiftPM/CocoaPods binary-target mechanisms need a single ready-made `BareKit.xcframework` zip rather than Android's raw ~354 MB multi-platform `prebuilds.zip`, so `flutter_pear` republishes just that one framework, repacked and checksum-pinned — see [`barekit-pin.json`](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear_bare/barekit-pin.json) for the exact pin chain.

**Download-size disclosure** (accept-and-disclose, standing decision — pub.dev downloads every dependency's committed files regardless of your target platform, [flutter/flutter#130210](https://github.com/flutter/flutter/issues/130210)): `flutter_pear_bare`'s committed iOS addon `.xcframework`s (bundled for every consumer, Android-only included) add **~21 MB** to that package's own tracked content — measured directly (`git ls-files` + `du`), not a pub.dev-computed archive size. The example app's iOS build produces a `Runner.app` of **~59.7 MB** (measured on the simulator archive) — this is an absolute number, not a delta: v0.1 had no iOS build at all to diff against.

## Learn more

- [Concepts](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/concepts.md) — topics vs. invites, the worklet model, replication, lifecycle.
- How-tos: [chat](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/howto-chat.md), [file sync](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/howto-filesync.md), [pairing](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/howto-pairing.md).
- [iOS platform notes](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md) — background execution, the Local Network permission, storage roots.
- [Background execution (Android)](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/BACKGROUND_EXECUTION.md) — what Android actually permits.
- [Error catalog](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/ERRORS.md) — every error code's problem, cause, and fix.
- [Troubleshooting](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/troubleshooting.md) — install-time failures that runtime error codes can't catch.
- [Full repository README](https://github.com/andrewloable/flutter_pear#readme) — API coverage table, testing your app, development setup, contributing.

## License

flutter_pear is **MIT** © 2026 Andrew Loable — see [LICENSE](https://github.com/andrewloable/flutter_pear/blob/main/LICENSE).

It bundles the Pear stack (Bare Kit + Hyper\* modules), which is **MIT /
Apache-2.0** — all permissive, no copyleft. Redistributed attributions ship in
`THIRD_PARTY_LICENSES` (generated at build time). See [LICENSING.md](https://github.com/andrewloable/flutter_pear/blob/main/LICENSING.md)
for the full dependency breakdown and obligations.
