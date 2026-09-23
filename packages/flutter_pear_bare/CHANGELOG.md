## 0.4.2

The repacked BareKit iOS xcframework published for Bare Kit 2.5.5 was a corrupt
zip, so Xcode could not resolve this package's SwiftPM binary target at all on
0.4.0 or 0.4.1 (`invalid archive returned from <url> which is required by
binary target 'BareKit'`). The asset downloaded intact and matched its pinned
checksum; the archive itself was malformed, by a zero-length root directory
entry the repack step emitted with an un-inflatable DEFLATE payload. The
generator no longer emits it.

The committed native addons under `android/src/main/jniLibs/` and `ios/addons/`
were regenerated against the bumped pear-end dependencies: `bare-os` is no
longer linked, `bare-path` now is, and `bare-fs`, `bare-pipe`,
`fs-native-extensions` and `rocksdb-native` moved up a version.

`barekit-pin.json` and the generated `Package.swift` now point at a new
release tag, `barekit-v2.5.5-1`, carrying a verified-valid asset; the original
corrupt `barekit-v2.5.5` asset is left untouched. `build.gradle` gained
`bareKitAssetRevision`, which supplies that tag suffix so a later repack
reproduces the same tag instead of drifting back to the broken asset.

> **iOS on 0.4.0 / 0.4.1 cannot be rescued — upgrade to 0.4.2.** Those
> releases pin the corrupt asset's checksum and are immutable on pub.dev.

Android is unchanged: still `minSdk = 29`, still Bare Kit 2.5.5,
still `arm64-v8a` + `x86_64` only.

**Breaking: deployment-target floors raised to iOS 15.0 and macOS 12.0** (from
iOS 13.0 and macOS 10.15.4), in both podspecs and both `Package.swift` files.
Xcode 27 cannot target macOS below 12.0 at all, so the previous macOS floor was
unbuildable rather than merely unverified. The macOS `Package.swift` comment
explaining the old 10.15.4 pin (`FileHandle.write(contentsOf:)`, which is
`@available(macOS 10.15.4+)`) is kept — that API sits comfortably below the new
floor and needs no availability guard.


