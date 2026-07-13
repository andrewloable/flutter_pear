# Desktop dev setup (Windows & Linux)

This page is for developers building `flutter_pear` apps **on** a Windows or
Linux machine — the *host* you develop on, not a *runtime target* your app
runs on. That's a different question from whether flutter_pear apps can
*run* on desktop at all — macOS, Linux, and Windows all now can (see [macOS
platform notes](macos.md), [Linux platform notes](linux.md), and [Windows
platform notes](windows.md); a real, in-app Hyperswarm round trip is only
confirmed on macOS so far — see [What's not yet supported](#whats-not-yet-supported)
below for the honest gap on the other two). This page is scoped narrowly:
does the existing Android-target workflow work smoothly from a non-macOS
machine, and if so, how do you set it up.

**Short answer, evidence-backed:** yes, already. Every claim below was
verified by reading this repo's own source, not assumed:

- The Android BareKit fetch (`flutter_pear_bare/android/build.gradle`) is
  **pure Gradle** — no `exec`, `commandLine`, or shell-out of any kind. It
  downloads and links Bare Kit's native binaries the same way on Windows,
  Linux, or macOS.
- `dart run flutter_pear:doctor`'s toolchain/environment checks (build
  target support, packaging path, entitlements, committed-asset integrity,
  ...) are **pure Dart** and run even without Node installed. Its runtime
  *connectivity* checks (DHT reachability, NAT estimate, the loopback
  self-test) still spawn a real `node` process — `node` remains a hard
  prerequisite for THAT part (flutter_pear-ewf), same as it always was; what
  changed is that those checks now actually run for every installed copy of
  flutter_pear instead of throwing a module-resolution error for anyone who
  installed from pub.dev instead of this repo. Neither half depends on a
  POSIX shell — see [Verifying your setup](#verifying-your-setup).
- This package's own consumer-facing docs (this file included) contain no
  `export PATH`, `chmod`, or shebang-only steps presented as something you
  must run.

The pieces that genuinely need a POSIX shell or macOS today are all
**maintainer-only** tooling — rebuilding the `pear-end` bundle
(`dart run flutter_pear:pack`) and this repo's by-hand release gates. A
consumer building an app that *depends on* `flutter_pear` never touches any
of that.

## Capability table

| Host you're developing on | Android build | iOS build |
|---|---|---|
| macOS | Available | Available (needs Xcode) |
| Linux | Available | Not available |
| Windows | Available | Not available |

iOS unavailable on Linux/Windows is **Apple's own platform constraint** —
Xcode only runs on macOS, and there is no way around that from
`flutter_pear` or from Flutter itself. It is not a `flutter_pear`
limitation, and there is no workaround to request.

## Windows setup

1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install/windows) and confirm `flutter doctor` is clean for Android.
2. Install Android Studio (or just the Android SDK/NDK via `sdkmanager`) — the same prerequisite any Flutter Android app needs, nothing `flutter_pear`-specific.
3. In your app's directory (PowerShell or cmd.exe):
   ```powershell
   flutter pub add flutter_pear
   ```
4. `flutter run` on an Android emulator or device. The first build downloads Bare Kit's native binaries via the plain Gradle task above — no manual NDK/ABI edits, no shell script to run yourself.
5. Confirm your host is recognized correctly:
   ```powershell
   dart run flutter_pear:doctor
   ```
   See [Verifying your setup](#verifying-your-setup) for what to expect.

## Linux setup

1. Install the [Flutter SDK](https://docs.flutter.dev/get-started/install/linux) and confirm `flutter doctor` is clean for Android.
2. Install Android Studio (or the Android SDK/NDK via `sdkmanager`).
3. In your app's directory:
   ```bash
   flutter pub add flutter_pear
   ```
4. `flutter run` on an Android emulator or device. Same pure-Gradle fetch as Windows — nothing platform-specific about it.
5. Confirm your host is recognized correctly:
   ```bash
   dart run flutter_pear:doctor
   ```

## Verifying your setup

`dart run flutter_pear:doctor` prints a host-capability line first, before
anything else, naming exactly what your machine can and can't build. This
is the real output of `checkHostCapability` against a faked `linux` host
(see `test/doctor_host_checks_test.dart` for the source of truth — no
literal Linux/Windows machine was available while writing this page, so
this is the function's real output, not a hand-typed guess):

```
[INFO] Host: Linux -> Android build available; iOS build unavailable (requires macOS + Xcode -- an Apple platform constraint, not a flutter_pear limitation). See https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/desktop-dev.md for the full dev setup guide.
```

(substitute `Windows` for `Linux` on a Windows host). If you see a `[FAIL]`
line anywhere else in the output, that's a real, fixable problem — see
[Troubleshooting](troubleshooting.md) for install-time failures, or
[../ERRORS.md](../ERRORS.md) for runtime error codes.

## What's not yet supported

**Flutter apps that *run* on Windows/macOS/Linux desktop** (as opposed to
developing an Android/iOS app *from* one of those hosts, which the rest of
this page covers) is a separate, larger effort tracked under the
`flutter_pear-aar` epic. All three desktop hosts now have real, working
native code, same embedding shape (a subprocess-spawned `bare` runtime,
relayed raw binary IPC — no BareKit equivalent exists for desktop):

- **macOS** (`flutter_pear-71g`/`flutter_pear-6yz`/`flutter_pear-iqp`/
  `flutter_pear-b6g`) is the most complete: `flutter_pear_example` has a
  real `macos/` runner, and a live, in-app Hyperswarm chat round trip is
  confirmed working end-to-end against real peers. See [macOS platform
  notes](macos.md).
- **Linux** (`flutter_pear-65g`/`flutter_pear-ymz`) has a real, compiled,
  lifecycle-tested-on-real-hardware native host, a real committed desktop
  bundle, a real `flutter_pear_example` `linux/` runner, and a confirmed
  live Hyperswarm join through the real Dart API — `PearSwarm.join()`
  reached `PearSwarmState.connected` against a real macOS peer, watched
  directly, not just inferred from the underlying plumbing. See [Linux
  platform notes](linux.md) for the exact detail (including the one
  remaining nuance: the chat message payload itself wasn't confirmed
  received in that same run, a timing artifact of an ad-hoc cross-machine
  test, not a protocol defect).
- **Windows** (`flutter_pear-pfp`/`flutter_pear-m6s`) has a real, compiled,
  lifecycle-tested-on-real-hardware native host, a real committed desktop
  bundle, a real `flutter_pear_example` `windows/` runner, and a confirmed
  live Hyperswarm join through the real Dart API — `PearSwarm.join()`
  reached `PearSwarmState.connected` against a real macOS peer, watched
  directly. Getting a real display attached to this dev environment's
  SSH-only Windows box (Windows 11 Home has no RDP) needed a Scheduled
  Task launched into the machine's own logged-in console session — a
  testing-environment workaround, not something an end user ever hits. See
  [Windows platform notes](windows.md) for the exact detail (including the
  same chat-message-payload nuance Linux's page documents, and the one
  remaining gap: the `release_gate.sh` `windows-smoke` leg wasn't
  independently re-run end-to-end through `flutter run` this session).

All three desktop platforms now have a real, on-hardware confirmed
Hyperswarm join through `flutter_pear_example`'s own Dart API — none of
this needs to be taken on faith from the underlying plugin-host plumbing
alone anymore. If your use case needs one of the remaining nuances above
closed sooner, [open an
issue](https://github.com/andrewloable/flutter_pear/issues) so real demand
can inform when that work gets picked up.

## See also

- [Troubleshooting](troubleshooting.md) — install-time failures (slow/silent downloads, blocked fetches, checksum/ABI mismatches).
- [iOS platform notes](ios.md) — what's different once you *do* have a Mac and are targeting iOS.
- [macOS platform notes](macos.md) — what's different once you're targeting macOS as a flutter_pear *runtime* (not just a dev host).
- [Linux platform notes](linux.md) — same, for Linux as a *runtime* target.
- [Windows platform notes](windows.md) — same, for Windows as a *runtime* target.
- [Error catalog](../ERRORS.md) — every runtime error code's problem, cause, and fix.
