# Troubleshooting: install-time failures

Runtime error codes (see [../ERRORS.md](../ERRORS.md)) and the doctor tool
can only diagnose a worklet that's already running. The failures below all
happen BEFORE that — during the Gradle build itself, the first time
`flutter_pear_bare` fetches and links its native binaries. Symptom-first:
find the text closest to what you're actually seeing.

Anchors below are explicit `<a id="...">` tags, matching
[../ERRORS.md](../ERRORS.md)'s own convention, so a link into this page
from a Gradle error message stays stable regardless of Markdown renderer.

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
