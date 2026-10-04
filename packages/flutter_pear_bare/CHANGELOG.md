## 0.4.8

**Added: 32-bit ARM (`armeabi-v7a`) on Android, for Android TVs and set-top
boxes.** No breaking change and nothing to configure. Bare Kit's
`armeabi-v7a` runtime and `armeabi-v7a` builds of all 13 of `pear-end`'s
native addons now ship next to `arm64-v8a` and `x86_64`, so this plugin
covers exactly the three ABIs Flutter itself builds.

Many TVs and boxes run Android 10 or later on a 32-bit-only userspace. Found
on a Sony BRAVIA 4K VH21 (Android TV 12, API 31), whose
`ro.product.cpu.abilist` is `armeabi-v7a,armeabi` with no 64-bit ABI: an
app built against 0.4.7 for the 64-bit ABIs only failed to install with
`INSTALL_FAILED_NO_MATCHING_ABIS`. Up to 0.4.7, the `armeabi-v7a` APK
Flutter builds by default also had no flutter_pear libraries in it, so it
installed and then failed at worklet start.

The `minSdk 29` floor holds for the new ABI: the 32-bit `libbare-kit.so`
from the same pinned Bare Kit 2.5.5 is built against API 29, and every symbol
it and the 13 addons import resolves at API 29. Bare Kit's version and
checksum are unchanged, as are the `arm64-v8a` and `x86_64` libraries. 32-bit
`x86` is still not shipped; Flutter no longer builds it either.

Cost: an `armeabi-v7a` APK now carries the 32-bit Bare Kit runtime (about
52 MB uncompressed) plus the addons; in this repo's example app that split
grew from 16.8 MB to 74.7 MB, and the universal APK by the same 57.9 MB. The
`arm64-v8a` and `x86_64` APKs are byte-for-byte the same size as before.

An app that sets the Gradle property `disable-abi-filtering=true` stops
Flutter applying its default ABI list, and must list `armeabi-v7a` in its
own `ndk.abiFilters` to ship it.

## 0.4.7

No code or behaviour change to this package. Version bump to stay in
lockstep with `flutter_pear` 0.4.7, which adds `PearConnection.closeStats`
entirely inside `pear-end/index.js` and its bundle -- the committed desktop
bundle copies in this package are regenerated for that same reason, but
`flutter_pear_bare`'s own native plugin code was not touched.

## 0.4.6

**Fixed: `BareWorklet.terminate()` hung forever on Windows**, freezing the
app's UI thread with it. It also hung on window close. The Windows host closed
the worklet's stdout pipe before killing the process. On Windows, closing a
handle that another thread is blocked reading does not unblock that read the
way POSIX `close()` does: it waits for the read to finish, and an idle worklet
never writes. The host now kills the process tree first, and the reader thread
closes its own pipe once the read fails. Verified on real Windows 11 hardware:
start/terminate cycles complete in milliseconds with no `bare.exe` left
running, and the cross-platform chat round trip passes.

**Changed: each desktop platform's worklet bundle and native addons now ship
from this package's own platform folder** (SwiftPM/CocoaPods resources on
macOS, CMake `install` on Linux and Windows), instead of as `flutter_pear`
Flutter assets that every app bundled. See `flutter_pear`'s changelog.

## 0.4.5

No code or behaviour change to this package. Version bump to stay in
lockstep with `flutter_pear` 0.4.5, which adds `join(announce:,
acceptUnannounced:)` entirely inside `pear-end/index.js` and the Dart
`PearSwarm`/`Pear` API surface. `flutter_pear_bare`'s native plugin code was
not touched.

## 0.4.4

No code or behaviour change to this package. Version bump to stay in
lockstep with `flutter_pear` 0.4.4, which adds a `dht.status` RPC method and
lowers a held-message cap -- both entirely inside `pear-end/index.js` and its
bundle. `flutter_pear_bare`'s native plugin code was not touched.

