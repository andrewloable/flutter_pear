# Troubleshooting: install-time failures

Runtime error codes (see [../ERRORS.md](../ERRORS.md)) and the doctor tool
can only diagnose a worklet that's already running. The failures below all
happen BEFORE that — during the Gradle build itself, the first time
`flutter_pear_bare` fetches and links its native binaries. Symptom-first:
find the text closest to what you're actually seeing.

Anchors below are explicit `<a id="...">` tags, matching
[../ERRORS.md](../ERRORS.md)'s own convention, so a link into this page
from a Gradle error message stays stable regardless of Markdown renderer.

<a id="bare-runtime-missing"></a>
## Desktop: `PearException(BARE_RUNTIME_MISSING)` from `Pear.start()`

Unlike everything else on this page, this is a RUNTIME failure (it comes
from `Pear.start()`, not from Gradle/Xcode) -- included here anyway because
it's the single most common first failure a desktop (macOS/Linux/Windows)
developer hits. Full problem/cause/fix:
[ERRORS.md#BARE_RUNTIME_MISSING](../ERRORS.md#BARE_RUNTIME_MISSING).

Short version: macOS, Linux, and Windows all fetch their own `bare`
runtime automatically on first launch (checksum-verified, then cached --
flutter_pear-8f6), so you should not need to install anything by hand. If
you still hit this, either that first-launch fetch failed (check your
network and try again) or `bare` genuinely isn't reachable any other way
-- `npm i -g bare` remains a manual fallback either way.

<a id="slow-first-build"></a>
## The first build is slow, or looks stuck

```
flutter_pear_bare: downloading Bare Kit v2.3.0 (... MB)...
```

(or `(size unknown)...` if a best-effort size lookup itself failed — that
alone isn't a problem, just missing information, not a missing download.)

This is expected, not stuck — the first build of any app depending on
`flutter_pear_bare` downloads Bare Kit's prebuilt native binaries (a
one-time, checksum-verified fetch of several hundred MB) before Gradle can
finish. Every build after this one reuses the cached copy and skips
straight past this line. If it's genuinely hung (no size estimate, no
progress, minutes with zero output), see
["fetch failed"](#fetch-failed) below — a silent hang usually means the
request is stuck at the network layer, not that Gradle froze.

The cache lives at `<app>/build/flutter_pear_bare/bare-kit/<version>/` —
delete that directory (or run `flutter clean`) to force a clean
re-download; bumping the plugin's own pinned Bare Kit version invalidates
it automatically.

<a id="fetch-failed"></a>
## `flutter_pear_bare: failed to download Bare Kit v2.3.0 after 2 attempts`

```
flutter_pear_bare: failed to download Bare Kit v2.3.0 after 2 attempts.
  URL: https://github.com/holepunchto/bare-kit/releases/download/v2.3.0/prebuilds.zip
  Error: <network exception message>

Manual fallback: download that URL yourself (e.g. in a browser) and place
the file at exactly:
  <app>/build/flutter_pear_bare/bare-kit/2.3.0/prebuilds.zip
then re-run the build -- it will be checksum-verified (sha256:...) and
used as-is, no further download attempted.
```

The build retries once automatically, then fails loudly with this message
rather than hanging. The most common cause is a corporate proxy or
firewall blocking direct GitHub Releases downloads. Two ways out:

1. **Manual fallback (fastest):** follow the message's own instructions —
   download the URL through whatever path already works for you (browser,
   proxy-aware `curl`, a colleague's machine), place it at the exact path
   given, and rebuild. It's checksum-verified before use, so a
   wrong/corrupted file is caught, not silently accepted.
2. **Point at a mirror:** pass `-PbareKitDownloadUrlOverride=<url>` to
   Gradle to fetch from an internal mirror instead of GitHub directly —
   useful if your organization already mirrors GitHub Releases artifacts.
   The build logs loudly when this override is active, on purpose, so it
   can't linger unnoticed in a shared `gradle.properties`.

<a id="checksum-mismatch"></a>
## `Checksum mismatch for <file>: expected sha256:..., got sha256:...`

The downloaded (or cached) `prebuilds.zip` doesn't match the pinned
checksum — either a download got corrupted mid-transfer, or a proxy/mirror
served something other than the real release asset. This check runs on
EVERY build, not just right after a fresh download, so a file that gets
tampered with or corrupted between builds is still caught.

**Fix:** delete the file named in the error and rebuild — the next run
re-downloads from scratch and re-verifies. If it mismatches again from a
fresh download, you're likely behind a proxy that's rewriting the
response; use the `bareKitDownloadUrlOverride` mirror path from
["fetch failed"](#fetch-failed) instead of retrying the same blocked path.

<a id="abi-mismatch"></a>
## `flutter_pear_bare failed to load its native binaries`

```
flutter_pear_bare failed to load its native binaries (<UnsatisfiedLinkError/LinkageError message>).
flutter_pear_bare only ships native code for arm64-v8a/x86_64 -- this
usually means the installed app/split is missing them (e.g. an
armeabi-v7a split from `flutter build apk --split-per-abi`, which ships
by default alongside the arm64-v8a/x86_64 ones, or a device whose
supported ABIs (...) flutter_pear_bare doesn't cover). Reinstall the
arm64-v8a or x86_64 variant.
```

This surfaces at worklet-start time (not build time) as a clear,
actionable error instead of a cryptic native-loader crash. It means the
APK/app-bundle variant actually installed on this device doesn't contain
`flutter_pear_bare`'s native libraries for that device's CPU.
`flutter_pear_bare` deliberately ships **only** `arm64-v8a` and `x86_64` —
there's no supported 32-bit (`armeabi-v7a`/`x86`) build, because Bare
Kit's own prebuild requires API 31+ hardware, which has no meaningful
32-bit-only population.

**Fix:** `flutter build apk --split-per-abi` produces a separate
`armeabi-v7a` APK alongside the `arm64-v8a`/`x86_64` ones by default — make
sure you're installing one of the latter two, not the 32-bit split. An app
bundle (`flutter build appbundle`) handles this correctly on its own via
per-device delivery; nothing to change there.

<a id="manifest-merge"></a>
## Manifest merger failed: `android:fullBackupContent` / `android:dataExtractionRules` already present

```
Manifest merger failed : Attribute application@dataExtractionRules value=(...)
from AndroidManifest.xml:N:N-N
is also present at [:flutter_pear_bare] AndroidManifest.xml:N:N-N value=(@xml/flutter_pear_data_extraction_rules).
Suggestion: add 'tools:replace="android:dataExtractionRules"' to <application>
element at AndroidManifest.xml:N:N-N to override.
```

(`[:flutter_pear_bare]` — the leading colon is how the manifest merger
labels a local Gradle project dependency, which is how Flutter plugins are
included, as opposed to `[group:artifact:version]` for a real Maven
coordinate.)

`flutter_pear_bare` sets `android:fullBackupContent` and
`android:dataExtractionRules` on `<application>` so its Corestore/Hypercore
storage (identity keys, replicated data) is excluded from Android backup
and device transfer by default — no manual step needed for apps that don't
already set these attributes themselves. If your app's own
`AndroidManifest.xml` ALSO sets either one, Gradle's manifest merger
refuses to silently pick a side; it fails the build with the message
above instead.

**Fix:** add `tools:replace` to your own `<application>` tag naming
whichever attribute(s) collided (comma-separated if both do), and make
sure your own backup/extraction rules XML also excludes
`flutter_pear`'s storage paths (`pear-corestore`/`pear-bulk` — see the
plugin's own rules files for the exact directory names) if you want that
exclusion to still apply:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:tools="http://schemas.android.com/tools">
    <application
        android:fullBackupContent="@xml/your_own_backup_rules"
        android:dataExtractionRules="@xml/your_own_extraction_rules"
        tools:replace="android:fullBackupContent,android:dataExtractionRules">
    </application>
</manifest>
```

## iOS (v0.2)

The CocoaPods compat podspec (`flutter_pear_bare.podspec`, the legacy path
for SPM-disabled projects/older Flutter) runs its own preflight check
(`ios/tool/preflight.sh`, flutter_pear-ovt.3.7) on every build, right
before the fetched BareKit and committed addon xcframeworks are used --
the four sections below are its possible failures. The primary Swift
Package Manager path (`Package.swift`) has no equivalent build-time
preflight: SwiftPM enforces a `binaryTarget`'s checksum at package
*resolution* time, before any build plan (and therefore any custom hook)
can run at all (confirmed by testing, flutter_pear-ovt.1.11's
FEAS-PREFLIGHT-ORDERING finding) -- so for the SPM path, the section below
maps SwiftPM's own raw errors to their fixes instead.

**Which path am I on?** Run `dart run flutter_pear:doctor` from your app --
its iOS section prints `SwiftPM path detected (default -- no ios/Podfile)`
or `CocoaPods compat path detected (ios/Podfile present)` as its first
line, so you always know which half of this section applies before reading
further. The errors below are grouped accordingly: preflight failures
happen only **on CocoaPods** (the branded messages just below); raw SwiftPM
errors happen only **on SPM** (see ["SwiftPM raw
errors"](#ios-spm-errors) further down). SwiftPM is the default as of
Flutter 3.44+ (`flutter_pear-ovt.1`'s own PREREQ-EVIDENCE finding) -- below
that floor, plugin resolution falls back to a path this plugin hasn't been
validated against; `flutter_pear:doctor` flags this too.

<a id="ios-addon-missing"></a>
### `<addon>.xcframework is missing from .../addons`

```
error: flutter_pear preflight found 1 problem(s) before compile/link:
  - sodium-native.5.1.0.xcframework is missing from .../flutter_pear_bare/ios/addons -- run `dart run flutter_pear:pack` to regenerate the committed addon xcframeworks, or check out a complete copy of this repo.
```

One of `flutter_pear_bare`'s 12 committed addon xcframeworks (pear-end's
own linked native addons, e.g. Hyperswarm's transitive `sodium-native`,
`udx-native`, etc. -- see the root `CLAUDE.md`'s toolchain table) isn't
where the podspec expects it. These are checked into the repo and never
fetched at consumer build time, so this almost always means a shallow or
partial checkout (a sparse `git clone`, an export that dropped binary
files, a `.gitattributes`/LFS misconfiguration) rather than anything a
consumer app did.

**Fix:** check out a complete copy of `flutter_pear` (make sure
`packages/flutter_pear_bare/ios/addons/*.xcframework` all exist and aren't
empty), or, if you're a `flutter_pear` maintainer regenerating them, run
`dart run flutter_pear:pack`.

<a id="ios-sim-slice-missing"></a>
### `<addon>.xcframework is missing its ios-arm64-simulator slice`

```
error: flutter_pear preflight found 1 problem(s) before compile/link:
  - bare-fs.4.7.3.xcframework is missing its ios-arm64-simulator slice. flutter_pear_bare ships arm64-only simulator slices by design (D21) -- an Intel-Mac x86_64 simulator isn't a supported target, so this isn't that. If you're on an Apple Silicon Mac and still see this, bare-fs.4.7.3.xcframework itself is corrupt or incomplete: run `dart run flutter_pear:pack` to regenerate it.
```

**This is not an Intel-Mac problem to work around** -- v0.2 deliberately
ships arm64-only iOS Simulator slices for the 12 addon xcframeworks (an
Intel Mac's x86_64 simulator was never a supported target; see the compat
podspec's own `VALID_ARCHS`/`EXCLUDED_ARCHS` handling). If you're on an
Apple Silicon Mac and still see this, the named xcframework itself is
missing its `ios-arm64-simulator/` subdirectory -- the same shallow/partial
checkout causes as ["addon missing"](#ios-addon-missing) above apply.

**Fix:** same as above -- check out a complete copy of the repo, or run
`dart run flutter_pear:pack` if you're regenerating the addons yourself.

<a id="ios-barekit-not-fetched"></a>
### `BareKit vX.Y.Z has not been fetched yet`

```
error: flutter_pear preflight found 1 problem(s) before compile/link:
  - BareKit v2.3.0 has not been fetched yet (expected .../barekit_cache/2.3.0/BareKit.xcframework.zip, from https://...). This step normally runs after the podspec's own fetch script_phase -- re-run the build so that step can complete; if it keeps failing, download the URL yourself and place it at exactly that path.
```

Preflight runs immediately after the podspec's own BareKit-fetch
script_phase, in the same build step -- seeing this almost always means
that fetch step itself failed or was skipped, not a preflight-specific
problem. Scroll up in the build log for a
`flutter_pear_bare: failed to download BareKit ...` or
`flutter_pear_bare: barekit-pin.json's repackedUrl ... is still a
PENDING-UPLOAD placeholder` message right before this one -- that's the
real failure; this preflight message is just naming its downstream effect.

**Fix:** resolve whatever the earlier fetch-step message says, then
rebuild. If you only see this preflight message with no earlier fetch
error above it (e.g. you ran `ios/tool/preflight.sh` standalone), point
its `FLUTTER_PEAR_BAREKIT_CACHE_DIR` env var at wherever a real build's
fetch step would have populated instead.

<a id="ios-barekit-cache-corrupt"></a>
### `BareKit vX.Y.Z's cached zip ... no longer matches barekit-pin.json's pinned checksum`

```
error: flutter_pear preflight found 1 problem(s) before compile/link:
  - BareKit v2.3.0's cached zip at .../BareKit.xcframework.zip no longer matches barekit-pin.json's pinned checksum (expected sha256:..., got sha256:...) -- it was corrupted or tampered with after the original fetch.
```

Unlike the fetch step's own checksum check (which only runs right after a
fresh download), preflight re-verifies the **cached** zip on every single
build -- catching corruption or tampering that happened between builds,
not just during the download itself.

**Fix:** delete the cache directory named in the error and rebuild -- the
next run re-fetches from scratch and re-verifies, same remedy as the
fetch step's own [checksum mismatch](#checksum-mismatch) case.

<a id="ios-deployment-target-too-low"></a>
### Deployment target below BareKit's minimum

```
error: flutter_pear preflight found 1 problem(s) before compile/link:
  - This app's iOS Deployment Target (12.0) is below flutter_pear's minimum (13.0) -- raise it in Xcode (Runner target > General > Deployment Info), or in your Podfile's platform :ios line.
```

`BareKit.xcframework`'s own `Info.plist` only ships slices down to iOS 13 --
targeting anything lower fails to link, not at preflight-detection time but
later during the real link step, with a far less obvious linker error. This
preflight catches it early and names the fix directly. `dart run
flutter_pear:doctor`'s iOS section runs this exact comparison too (against
`Package.swift`'s own real minimum, not a hardcoded guess), so it's worth
running before a full build if you suspect this.

**Fix:** raise your app's iOS Deployment Target to 13.0 or higher --
Xcode's Runner target > General > Minimum Deployments on the SPM path, or
your `ios/Podfile`'s `platform :ios, 'X.Y'` line on the CocoaPods path.

<a id="ios-barekit-vendoring"></a>
### Fetching BareKit behind a proxy, mirror, or air-gapped network

Both packaging paths fetch the SAME repacked `BareKit.xcframework` asset
(`barekit-pin.json`'s `repackedUrl`, checksum-pinned) but have different
override mechanisms -- neither skips the checksum check, so a mirror must
serve byte-identical content:

- **On SPM:** set the `FLUTTER_PEAR_BAREKIT_URL` environment variable to an
  internal HTTPS mirror URL before building (`Package.swift`'s generated
  `let bareKitURL = ProcessInfo.processInfo.environment[...] ?? "<pinned
  URL>"` reads it). `Package.swift`'s baked-in checksum is still enforced
  against whatever that URL actually serves -- a mirror hosting different
  content fails the same way a corrupted upload would (see ["checksum of
  downloaded artifact"](#ios-spm-errors) below). There is no local-file
  override on this path -- SwiftPM's `url:`-based `binaryTarget` always
  fetches over the network; a genuinely air-gapped build needs a
  pre-warmed `~/Library/Caches/org.swift.swiftpm` (populate it once on a
  networked machine, then copy that cache directory to the air-gapped one)
  rather than an env var.
- **On CocoaPods:** there is no env var -- the compat podspec's
  `script_phase` always reads `repackedUrl` straight from
  `barekit-pin.json`. To vendor the asset yourself (proxy, mirror, or
  air-gapped), fetch it by hand and place the extracted
  `BareKit.xcframework` directly at
  `ios/Pods/flutter_pear_bare/barekit_cache/<version>/BareKit.xcframework`
  (matching `barekit-pin.json`'s `bareKitVersion`) *before* running `pod
  install`/building -- the `script_phase`'s own existence check (`if [ -f
  "$FRAMEWORK_DIR/Info.plist" ]`) skips its fetch entirely once that path
  is already populated.

<a id="ios-xcode-cloud"></a>
### Xcode Cloud

SwiftPM `url:`-based `binaryTarget`s have a known Xcode Cloud cache-
collision failure ([flutter/flutter#187710](https://github.com/flutter/flutter/issues/187710)):
Xcode Cloud's build cache can serve a stale resolved package graph across
builds, which for a `url:` binary target manifests as the SAME
checksum-mismatch or 404-style errors documented under ["SwiftPM raw
errors"](#ios-spm-errors) below, even though nothing in this repo's own
pin actually changed. SwiftPM resolution also requires real network access
during the build -- an Xcode Cloud workflow with restricted/no network
egress fails at resolution, not at a later, more obviously
network-related step.

**Fix:** if you hit unexplained checksum/404 errors specifically on Xcode
Cloud (not reproducible in a local build), clear the workflow's package
cache and retry; if that's not available to you, or network egress is the
real constraint, fall back to the CocoaPods compat path (its
`script_phase` fetch is a normal build step, not a package-resolution-time
one, so it isn't subject to this specific SPM/Xcode-Cloud interaction).

<a id="ios-spm-errors"></a>
### SwiftPM raw errors (`Package.swift`, no preflight possible)

SwiftPM validates and resolves every `binaryTarget` before your build plan
even exists, so none of these can be intercepted with a friendlier
message the way the CocoaPods leg's preflight above can -- match the
verbatim text you're seeing against the cases below instead.

**`invalid URL scheme for binary target 'BareKit'; valid schemes are:
'https'`** -- `barekit-pin.json`'s `repackedUrl` is still the
`PENDING-UPLOAD` placeholder text (flutter_pear-ovt.2.3's intentional
upload-skip state, e.g. before this project's first real BareKit release
build), or someone hand-edited `Package.swift` (never do this -- it's
generated by `dart run flutter_pear:pack`, see its own `DO NOT EDIT BY
HAND` header) with a non-`https` URL. **Fix:** wait for a real release
build, where `repackedUrl` is a real, published `https://` URL, or (repo
maintainers only) run `dart run flutter_pear:pack --repack-barekit`
(uploading enabled) to publish one now.

**`checksum of downloaded artifact of binary target 'BareKit' (...) does
not match checksum specified by the manifest (...)`** -- the published
BareKit artifact at the pinned URL doesn't match `Package.swift`'s baked-in
checksum (a corrupted upload, a mirror/proxy serving something else, or a
stale local SwiftPM cache holding an older artifact under the same URL).
**Fix:** run `rm -rf ~/Library/Caches/org.swift.swiftpm` (SwiftPM's
resolution cache) and `flutter clean`, then rebuild; if it still mismatches
from a genuinely fresh download, this is a repo-maintainer-side pinning bug
(the checksum in a landed `Package.swift` doesn't match its own
`repackedUrl`'s real content) -- file an issue rather than working around
it locally.

**`failed downloading '...' : badResponseStatusCode(...)`** (or any other
network/HTTP failure resolving BareKit's `url:`) -- the pinned URL isn't
reachable from this machine (network outage, corporate firewall/proxy
blocking the host, or the URL itself is stale/removed). **Fix:** confirm
the URL from `Package.swift`'s `BareKit` `binaryTarget` (or the
`FLUTTER_PEAR_BAREKIT_URL` environment-variable override, if you've set
one for local testing) is reachable from this machine by hand (`curl -I
<url>`); there's no SwiftPM-side mirror override today (unlike the
CocoaPods leg's manual-fallback path) -- route around the network problem
itself (VPN, proxy config, etc.) instead.

**`no library for this platform was found in .../<addon>.xcframework`**
(building for the iOS Simulator) -- see
["sim slice missing"](#ios-sim-slice-missing) above; the exact same
arm64-only-simulator-by-design explanation and fix apply here, just
surfaced as Xcode's own raw xcframework-slice error instead of a
`flutter_pear`-branded preflight message (SwiftPM has no build-tool-plugin
mechanism wired in for this today -- see this file's note on
flutter_pear-ovt.3.7's docs-only choice for the SPM leg, in its own issue
notes, for why).

**A build keeps using an old `BareKit.xcframework` version/checksum after
`flutter pub upgrade`, with no error at all** -- a known SwiftPM
binary-artifact cache-resolution footgun
([flutter/flutter#186054](https://github.com/flutter/flutter/issues/186054)):
SwiftPM can resolve a `url:`-based `binaryTarget` from its own on-disk
cache without re-checking whether the URL's pinned checksum changed,
particularly across a plain `flutter pub upgrade` that doesn't also touch
`Package.swift`'s own timestamp in a way Xcode notices. **Fix:** run `rm
-rf ~/Library/Caches/org.swift.swiftpm` and `flutter clean`, then rebuild --
same remedy as the checksum-mismatch case above, worth trying first
whenever a BareKit-related build behaves like it's ignoring a real pin
change.

<a id="emulator-nat"></a>
## Two emulators (or an emulator + a real device) won't connect

Two Android emulators on the SAME machine are *expected* to connect to
each other the same way two real devices do — Hyperswarm/DHT discovery
doesn't care that both peers are virtual — but the full
device/emulator/desktop-peer combination matrix under real-world network
conditions hasn't actually been verified yet (tracked separately,
`flutter_pear-u8y.6`; an emulator's virtual NIC sits behind the host
machine's own network stack, which can behave differently from a real
device's radio when the host itself is on a restrictive corporate network
or VPN). Don't read this section as "verified working" for any specific
combination — it isn't, yet.

If a specific combination doesn't connect for you: check
[Background execution](../BACKGROUND_EXECUTION.md) and the
[chat how-to](howto-chat.md)'s connection-state guidance first (a `failed`
state with a typed reason, e.g. `E_UDP_BLOCKED`, usually means the network
itself is the blocker, not the emulator) — then please file an issue with
the exact combination and state transitions you saw.

<a id="background-disconnects"></a>
## The connection drops as soon as the app is backgrounded

Expected, to a degree: [Background execution](../BACKGROUND_EXECUTION.md)
(E6.4) documents exactly what Android permits once an app is backgrounded
— `flutter_pear` auto-suspends the worklet after a short linger window and
resumes it on foreground, but neither this library nor any other can keep
a swarm alive indefinitely once the OS decides to reclaim a backgrounded
app's resources. If connections drop faster than that document describes,
that's a bug worth reporting — if they drop roughly in line with it,
that's the documented, OS-imposed limit, not a build/install problem at
all.

## A file never arrived after `mirrorToDisk`, with no exception thrown

`PearDrive.mirrorToDisk` mirrors an untrusted peer's ENTIRE drive to a
local directory — since the peer isn't trusted, the worklet rejects
(instead of writing) two kinds of hostile entries rather than failing the
whole call:

- **`symlink-rejected`** — the source drive contained a symlink entry.
  Rejected unconditionally, regardless of what it points to: symlinks are
  never legitimately needed for a drive-to-disk mirror, and honoring one
  from an untrusted peer is exactly the zip-slip vector this guards
  against (a symlink planted at one path, then a later entry routed
  through it, escaping the mirror directory).
- **`path-escape`** — the entry's own resolved destination path wasn't
  strictly inside the mirror directory.

Neither reason can come from your own writes — only from a peer's drive
you're mirroring. To see what happened:

```dart
final sub = drive.mirrorWarnings.listen((w) {
  print('mirrorToDisk rejected ${w.path}: ${w.reason}');
});
final result = await drive.mirrorToDisk(localDir);
print('${result.rejected} entr${result.rejected == 1 ? 'y' : 'ies'} rejected');
await sub.cancel();
```

`result.rejected` is the authoritative count even if you subscribe to
`mirrorWarnings` too late to catch every individual event — check it first
if a file's mere absence, without an exception, is your only symptom.
