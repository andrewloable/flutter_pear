## Unreleased

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

