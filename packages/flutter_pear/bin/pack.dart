// `dart run flutter_pear:pack` — rebuild the bundled pear-end and refresh the
// third-party license manifest.
//
//   1. Wraps bare-pack to build pear-end/index.js → assets/pear-end.bundle,
//      so app devs never install Bare tooling by hand.
//   2. Collects every bundled module's LICENSE/NOTICE into THIRD_PARTY_LICENSES
//      (+ NOTICE), satisfying Apache-2.0 §4 attribution for the shipped bundle.
//
// ponytail: shell out to bare-pack; don't reimplement bundling.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;

/// Asset path (relative to the `flutter_pear` package root) that
/// [buildBundle] writes to and that the package's `pubspec.yaml` declares as
/// a Flutter asset. `flutter_pear_bare`'s Android worklet loader reads it
/// back via `FlutterAssets.getAssetFilePathBySubpath('assets/pear-end.bundle',
/// 'flutter_pear')` — this string is the contract between the two packages.
const bundleAssetPath = 'assets/pear-end.bundle';

Future<void> main(List<String> args) async {
  // Not File.fromUri(Platform.script).parent.parent: `dart run` executes a
  // cached kernel snapshot under .dart_tool/pub/bin/, so Platform.script
  // doesn't point at bin/pack.dart on disk. Run from the package root (as
  // documented: `dart run flutter_pear:pack` from packages/flutter_pear).
  final pkgRoot = Directory.current.path;

  // --version-only: just (re)write the gitignored pear-end/version.js that
  // index.js unconditionally requires -- skips bare-pack, so CI can call
  // this without installing it just to run the pear-end JS test suite.
  if (args.contains('--version-only')) {
    writeBundleVersion(pkgRoot, computeBundleVersion(pkgRoot));
    return;
  }

  // Snapshotted BEFORE any artifact write below, so checkArtifactSizes can
  // print a genuine before/after growth delta at the end (eng-review 1A).
  final beforeArtifactSizes = _snapshotArtifactSizes(pkgRoot);

  final code = await buildBundle(pkgRoot);
  if (code != 0) exit(code);
  final linkCode = await linkNativeAddons(pkgRoot);
  if (linkCode != 0) exit(linkCode);
  final linkIosCode = await linkNativeAddonsIos(pkgRoot);
  if (linkIosCode != 0) exit(linkIosCode);
  final repackCode = await repackBareKit(
    pkgRoot,
    force: args.contains('--repack-barekit'),
    upload: !args.contains('--no-upload'),
  );
  if (repackCode != 0) exit(repackCode);
  final packageSwiftCode = await generatePackageSwift(pkgRoot);
  if (packageSwiftCode != 0) exit(packageSwiftCode);
  try {
    await collectThirdPartyLicenses(pkgRoot);
  } on LicenseViolationException catch (e) {
    stderr.writeln('license check failed: $e');
    exit(1);
  }

  final sizeCode =
      await checkArtifactSizes(pkgRoot, beforeSizes: beforeArtifactSizes);
  if (sizeCode != 0) exit(sizeCode);
}

/// ABIs this repo ships native addons for, mapped to the `bare-link`
/// `--host` value that produces each one -- keep the ABI names in sync
/// with `flutter_pear_bare/android/build.gradle`'s `bareKitAbis` (same
/// deliberate arm64-v8a/x86_64-only exclusion of 32-bit documented there;
/// enforced by a test in pack_test.dart, not just this comment). Explicit
/// hosts, not `--preset android`, which also links (and wastes time
/// linking) `armeabi-v7a`/`x86` -- output this repo has never shipped.
const nativeAddonAbis = {
  'arm64-v8a': 'android-arm64',
  'x86_64': 'android-x64',
};

/// Runs `bare-link` against pear-end's resolved `node_modules` and commits
/// the resulting per-ABI `.so` files into `flutter_pear_bare`'s own
/// `android/src/main/jniLibs/<abi>/` -- a committed, versioned artifact
/// exactly like [bundleAssetPath], regenerated here rather than resolved at
/// a consumer's build time.
///
/// flutter_pear-k2y: the previous approach was a Gradle `Exec` task that
/// located `pear-end/node_modules` via a path relative to the CONSUMING
/// APP's own `android/` directory -- which only ever resolved correctly
/// for `flutter_pear_example`, because it happens to live inside this same
/// monorepo, sibling to `packages/flutter_pear`. Any real external
/// consumer's app lives elsewhere entirely; the task's own `onlyIf` guard
/// then silently skipped it (no error), shipping an APK missing every
/// native addon -- confirmed via a real "outside this repo" consumer app,
/// which crashed with `AddonError: ADDON_NOT_FOUND` / SIGABRT the instant
/// `Pear.start()` tried to load `udx-native`. Committing the already-
/// prebuilt `.so` files here instead means a consumer's Gradle build never
/// needs to find `pear-end/node_modules` at all -- Android's standard
/// `src/main/jniLibs/<abi>/` convention picks them up with zero custom
/// task wiring, the same way any native-code Flutter plugin ships one.
///
/// Verifies every ABI produced at least one `.so` in a scratch directory
/// BEFORE touching the committed `jniLibs/<abi>/` at all -- a review of
/// this fix's first draft caught that wiping the destination unconditionally,
/// then merely `continue`-ing past an ABI `bare-link` happened to produce
/// nothing for, would silently ship an APK missing that ABI's addons and
/// still report success: the exact silent-breakage failure mode this fix
/// exists to eliminate, just relocated from consumer build time to
/// maintainer pack time. A short-of-every-ABI run now fails loud and
/// leaves the previously-committed `.so` files untouched.
///
/// Also prunes any ABI subdirectory under `jniLibs/` that isn't in
/// [nativeAddonAbis] -- if a future maintainer drops an ABI from that map,
/// its stale `.so` files must not linger and keep shipping in every APK
/// forever (mirrors `fetchBareKit`'s own ABI-pruning behavior on the Bare
/// Kit runtime side, in `build.gradle`).
///
/// Returns 0 on success (every ABI populated), a nonzero code if
/// `bare-link` itself failed or produced no `.so` for some ABI, or 0
/// without doing anything if `pear-end/node_modules` is missing (run `npm
/// install` first) -- matching [collectThirdPartyLicenses]'s established
/// skip-with-a-note behavior for the same precondition.
Future<int> linkNativeAddons(String pkgRoot) async {
  final pearEndDir = '$pkgRoot/pear-end';
  if (!Directory('$pearEndDir/node_modules').existsSync()) {
    stderr.writeln('skip linkNativeAddons: $pearEndDir/node_modules missing — '
        'run `npm install` in pear-end/ first.');
    return 0;
  }

  final tmpOut = Directory.systemTemp.createTempSync('fp_pack_addons');
  try {
    final result = await Process.run(
      'bare-link',
      [
        for (final host in nativeAddonAbis.values) ...['--host', host],
        '--out',
        tmpOut.path,
      ],
      workingDirectory: pearEndDir,
    );
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      stderr.writeln('bare-link failed. Install it: npm i -g bare-link');
      return result.exitCode;
    }

    final soFilesByAbi = <String, List<File>>{};
    for (final abi in nativeAddonAbis.keys) {
      final src = Directory('${tmpOut.path}/$abi');
      final files = src.existsSync()
          ? src.listSync().whereType<File>().where((f) {
              return _basename(f).endsWith('.so');
            }).toList()
          : const <File>[];
      if (files.isEmpty) {
        stderr.writeln(
            'linkNativeAddons: bare-link produced no .so files for $abi -- '
            'leaving the previously-committed jniLibs/$abi/ untouched '
            'rather than wiping it based on an empty result.');
        return 1;
      }
      soFilesByAbi[abi] = files;
    }

    final jniLibsRoot =
        Directory('$pkgRoot/../flutter_pear_bare/android/src/main/jniLibs');
    // Prune ABI directories no longer in nativeAddonAbis before writing the
    // current set, so a shrunk ABI list doesn't leave orphaned .so files.
    if (jniLibsRoot.existsSync()) {
      for (final abiDir in jniLibsRoot.listSync().whereType<Directory>()) {
        if (!nativeAddonAbis.containsKey(_basename(abiDir))) {
          abiDir.deleteSync(recursive: true);
        }
      }
    }
    for (final entry in soFilesByAbi.entries) {
      final dst = Directory('${jniLibsRoot.path}/${entry.key}');
      // Wiped, not merged: this directory holds nothing but pear-end's
      // linked addons, so a dependency drop must remove its stale .so
      // rather than have it linger -- safe now that every ABI is already
      // confirmed non-empty above.
      if (dst.existsSync()) dst.deleteSync(recursive: true);
      dst.createSync(recursive: true);
      for (final f in entry.value) {
        f.copySync('${dst.path}/${_basename(f)}');
      }
    }
    stdout.writeln(
        'wrote ${jniLibsRoot.path}/{${nativeAddonAbis.keys.join(',')}}/*.so');
    return 0;
  } finally {
    tmpOut.deleteSync(recursive: true);
  }
}

/// `bare-link --host` values for the committed iOS addon xcframeworks --
/// device arm64 (`ios-arm64`) plus simulator arm64 (`ios-arm64-simulator`)
/// ONLY (decision D21: no `x86_64` simulator slice; Intel Mac devs get docs
/// in a later task). Verified (flutter_pear-ovt.1.5) that `bare-link`
/// natively emits ready xcframeworks for these two hosts in one invocation
/// -- no manual harvesting/`xcodebuild -create-xcframework` fallback
/// needed. A documented top-level const, not inlined, so tests can assert
/// it without running bare-link.
const iosAddonHosts = ['ios-arm64', 'ios-arm64-simulator'];

/// Runs `bare-link` against pear-end's resolved `node_modules` for
/// [iosAddonHosts] and commits the resulting per-addon `.xcframework`
/// bundles into `flutter_pear_bare`'s own `ios/addons/` -- the iOS
/// counterpart to [linkNativeAddons]'s committed Android `jniLibs`, same
/// flutter_pear-k2y decision (native addons are committed maintainer-time
/// artifacts, never resolved at a consumer's build time).
///
/// Verifies at least one xcframework was produced AND every xcframework's
/// `Info.plist` lists BOTH required slices in `AvailableLibraries` BEFORE
/// touching the committed `ios/addons/` directory at all -- same
/// fail-loud-before-wiping contract as [linkNativeAddons].
///
/// Returns 0 on success, a nonzero code if `bare-link` itself failed or
/// produced a short/malformed result, or 0 without doing anything if
/// `pear-end/node_modules` is missing (matching [linkNativeAddons]'s and
/// [collectThirdPartyLicenses]'s established skip-with-a-note behavior).
Future<int> linkNativeAddonsIos(String pkgRoot) async {
  final pearEndDir = '$pkgRoot/pear-end';
  if (!Directory('$pearEndDir/node_modules').existsSync()) {
    stderr.writeln(
        'skip linkNativeAddonsIos: $pearEndDir/node_modules missing — '
        'run `npm install` in pear-end/ first.');
    return 0;
  }

  final tmpOut = Directory.systemTemp.createTempSync('fp_pack_addons_ios');
  try {
    final result = await Process.run(
      'bare-link',
      [
        for (final host in iosAddonHosts) ...['--host', host],
        '--out', tmpOut.path,
      ],
      workingDirectory: pearEndDir,
    );
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      stderr.writeln('bare-link failed. Install it: npm i -g bare-link');
      return result.exitCode;
    }

    final xcframeworks = tmpOut
        .listSync()
        .whereType<Directory>()
        .where((d) => _basename(d).endsWith('.xcframework'))
        .toList();
    if (xcframeworks.isEmpty) {
      stderr.writeln('linkNativeAddonsIos: bare-link produced no '
          '.xcframework bundles -- leaving the previously-committed '
          'ios/addons/ untouched rather than wiping it based on an empty '
          'result.');
      return 1;
    }
    for (final xcfw in xcframeworks) {
      final plist = File('${xcfw.path}/Info.plist');
      if (!plist.existsSync()) {
        stderr.writeln('linkNativeAddonsIos: ${_basename(xcfw)} has no '
            'Info.plist -- leaving the previously-committed ios/addons/ '
            'untouched.');
        return 1;
      }
      final plistText = plist.readAsStringSync();
      final missing = iosAddonHosts
          .where((h) => !plistText.contains('<string>$h</string>'))
          .toList();
      if (missing.isNotEmpty) {
        stderr.writeln('linkNativeAddonsIos: ${_basename(xcfw)}\'s '
            'Info.plist is missing slice(s) ${missing.join(', ')} -- '
            'leaving the previously-committed ios/addons/ untouched.');
        return 1;
      }
    }

    final addonsRoot = Directory('$pkgRoot/../flutter_pear_bare/ios/addons');
    final currentNames = xcframeworks.map(_basename).toSet();
    // Prune addons no longer produced (a dependency drop) before writing
    // the current set, mirroring linkNativeAddons's ABI-pruning behavior --
    // safe now that every xcframework is already confirmed well-formed
    // above.
    if (addonsRoot.existsSync()) {
      for (final entry in addonsRoot.listSync().whereType<Directory>()) {
        if (!currentNames.contains(_basename(entry))) {
          entry.deleteSync(recursive: true);
        }
      }
    } else {
      addonsRoot.createSync(recursive: true);
    }
    for (final xcfw in xcframeworks) {
      final dst = Directory('${addonsRoot.path}/${_basename(xcfw)}');
      if (dst.existsSync()) dst.deleteSync(recursive: true);
      _copyDirectorySync(xcfw, dst);
    }
    stdout.writeln(
        'wrote ${addonsRoot.path}/*.xcframework (${xcframeworks.length} addons)');
    return 0;
  } finally {
    tmpOut.deleteSync(recursive: true);
  }
}

/// Recursively copies [src] to [dst] (`dart:io` has no built-in equivalent
/// of a shell `cp -R`) -- used for xcframework bundles, whose nested
/// per-slice `.framework/` directories a flat file-by-file copy (adequate
/// for the Android `.so` case in [linkNativeAddons]) can't handle.
void _copyDirectorySync(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  for (final entity in src.listSync()) {
    final name = _basename(entity);
    if (entity is Directory) {
      _copyDirectorySync(entity, Directory('${dst.path}/$name'));
    } else if (entity is File) {
      entity.copySync('${dst.path}/$name');
    } else if (entity is Link) {
      Link('${dst.path}/$name').createSync(entity.targetSync());
    }
  }
}

/// Thrown when `flutter_pear_bare/android/build.gradle`'s BareKit pin
/// (single source of truth, DX2 finding 50 -- Android and iOS must provably
/// share the same `bareKitVersion`) can't be read.
class BareKitPinException implements Exception {
  BareKitPinException(this.message);
  final String message;
  @override
  String toString() => 'BareKitPinException: $message';
}

/// The two facts [repackBareKit] reads out of `build.gradle` before doing
/// anything else: the pinned Bare Kit release version, and the SHA256
/// [verifySha256]-checks the FULL upstream `prebuilds.zip` against at
/// Android build time. Both must match what `barekit-pin.json` records, or
/// Android and iOS would silently pin different Bare Kit releases.
typedef BareKitGradlePin = ({String version, String upstreamSha256});

/// Parses [BareKitGradlePin] out of `flutter_pear_bare/android/build.gradle`
/// -- same regex approach as [_addBareKitStaticEntry]'s `bareKitVersion`
/// read, extended to also require `bareKitSha256`. Throws
/// [BareKitPinException] if either is missing, rather than silently
/// repacking against an unpinned or stale version.
BareKitGradlePin readBareKitGradlePin(String pkgRoot) {
  final gradleFile = File('$pkgRoot/../flutter_pear_bare/android/build.gradle');
  if (!gradleFile.existsSync()) {
    throw BareKitPinException('${gradleFile.path} not found');
  }
  final text = gradleFile.readAsStringSync();
  final versionMatch =
      RegExp(r'''bareKitVersion\s*=\s*["']([^"']+)["']''').firstMatch(text);
  if (versionMatch == null) {
    throw BareKitPinException(
        'could not find bareKitVersion in ${gradleFile.path}');
  }
  final shaMatch = RegExp(r'''bareKitSha256\s*=\s*["']([0-9a-fA-F]{64})["']''')
      .firstMatch(text);
  if (shaMatch == null) {
    throw BareKitPinException(
        'could not find a 64-hex-char bareKitSha256 in ${gradleFile.path}');
  }
  return (
    version: versionMatch.group(1)!,
    upstreamSha256: shaMatch.group(1)!.toLowerCase(),
  );
}

/// Default [repackBareKit] `download` implementation: a plain HTTP(S) GET
/// to [dest]. Real network I/O, factored out so tests can inject a fake
/// instead (DO step 7: keep network out of unit tests).
Future<void> _httpDownload(String url, File dest) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw BareKitPinException(
          'GET $url returned HTTP ${response.statusCode}');
    }
    await response.pipe(dest.openWrite());
  } finally {
    client.close(force: true);
  }
}

/// True if a HEAD request to [url] succeeds (2xx) -- used by
/// [repackBareKit]'s idempotence check to confirm a previously-recorded
/// `repackedUrl` still actually resolves before trusting it enough to skip
/// a fresh repack.
Future<bool> _urlHeadOk(String url) async {
  final client = HttpClient();
  try {
    final request = await client.headUrl(Uri.parse(url));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode >= 200 && response.statusCode < 300;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Default [repackBareKit] `upload` implementation: `gh release create`
/// (idempotent -- `--target` is fine to omit; ignores an "already exists"
/// failure) followed by `gh release upload`, deriving owner/repo from
/// `gh repo view` so this works from any clone/fork. Returns the resulting
/// `releases/download` URL. Real `gh` I/O, factored out so tests can inject
/// a fake instead (DO step 7).
Future<String> _ghUpload(String version, File zip) async {
  final tag = 'barekit-v$version';
  final assetName = 'BareKit-$version-ios.xcframework.zip';

  final createResult = await Process.run(
      'gh', ['release', 'create', tag, '--title', tag, '--notes', 'Repacked BareKit.xcframework for SPM (flutter_pear-ovt.2.3).']);
  // "release already exists" is expected and fine on a re-repack of the
  // same version; any OTHER failure is not.
  if (createResult.exitCode != 0 &&
      !'${createResult.stderr}'.contains('already exists')) {
    throw BareKitPinException(
        'gh release create $tag failed: ${createResult.stderr}');
  }

  final uploadResult = await Process.run('gh', [
    'release', 'upload', tag, '${zip.path}#$assetName',
    '--clobber',
  ]);
  if (uploadResult.exitCode != 0) {
    throw BareKitPinException(
        'gh release upload failed: ${uploadResult.stderr}');
  }

  final viewResult =
      await Process.run('gh', ['repo', 'view', '--json', 'nameWithOwner']);
  if (viewResult.exitCode != 0) {
    throw BareKitPinException(
        'gh repo view failed: ${viewResult.stderr}');
  }
  final nameWithOwner =
      (jsonDecode(viewResult.stdout as String) as Map)['nameWithOwner'] as String;
  return 'https://github.com/$nameWithOwner/releases/download/$tag/$assetName';
}

/// Repacks upstream `holepunchto/bare-kit`'s release `prebuilds.zip` (one
/// ~354MB multi-platform archive) down to just `BareKit.xcframework` at
/// archive root -- the layout SPM's `url:`/`checksum:` binaryTarget
/// requires, and a ~90%+ size cut per consumer (plan decision 31, Eng2
/// finding 1). Writes the committed two-link checksum chain
/// `flutter_pear_bare/barekit-pin.json`: [BareKitGradlePin]'s version and
/// upstream checksum (link 1, already Android's own pin) plus the repacked
/// asset's own URL and checksum (link 2) -- an auditable "maintainer
/// re-packed this, here's proof against upstream's own release" chain, not
/// a from-scratch build.
///
/// Idempotent by default: if `barekit-pin.json` already records the current
/// [BareKitGradlePin.version] and its `repackedUrl` still resolves (a live
/// HEAD request), this returns 0 without downloading anything. [force]
/// (`--repack-barekit`) skips that check and always re-runs the full
/// pipeline.
///
/// [upload] controls whether the repacked zip is actually published
/// (`gh release create`/`upload`, via [uploadFn]) -- when `false`
/// (`--repack-barekit --no-upload`), every other step still runs for real
/// (download, upstream checksum verify, extract, re-zip, compute
/// `repackedSha256`) and the pin is still written, but `repackedUrl` is
/// left as an explicit `PENDING-UPLOAD:` sentinel instead of a real link,
/// so a maintainer can verify the pipeline without publishing a release
/// asset. A later plain re-run (no flags) does NOT silently attempt the
/// real upload just because that sentinel URL fails the idempotence
/// check's HEAD request above -- it fails loud instead, requiring
/// `--repack-barekit` (uploading enabled) to explicitly opt into actually
/// publishing. (This exact gap -- an ordinary re-run silently cascading
/// into a real `gh release create`/`upload` -- caused an unintended public
/// release during this feature's own development; the check above closes
/// it rather than just documenting it as a footgun.)
///
/// [downloadFn]/[uploadFn] are the impure boundary (real network/`gh`
/// calls) -- injectable so tests exercise every pure step (pin parsing,
/// checksum verification, extraction, re-zip, JSON shape) without touching
/// the network (DO step 7).
Future<int> repackBareKit(
  String pkgRoot, {
  bool force = false,
  bool upload = true,
  Future<void> Function(String url, File dest) downloadFn = _httpDownload,
  Future<String> Function(String version, File zip) uploadFn = _ghUpload,
}) async {
  final BareKitGradlePin pin;
  try {
    pin = readBareKitGradlePin(pkgRoot);
  } on BareKitPinException catch (e) {
    stderr.writeln('repackBareKit: $e');
    return 1;
  }

  final pinFile = File('$pkgRoot/../flutter_pear_bare/barekit-pin.json');
  if (pinFile.existsSync()) {
    Map<String, dynamic>? existing;
    try {
      existing = jsonDecode(pinFile.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      existing = null;
    }
    final existingUrl = existing?['repackedUrl'] as String?;
    final sameVersion = existing != null && existing['bareKitVersion'] == pin.version;

    if (!force && sameVersion && existingUrl != null &&
        !existingUrl.startsWith('PENDING-UPLOAD') &&
        await _urlHeadOk(existingUrl)) {
      stdout.writeln('barekit-pin.json already up to date for '
          '${pin.version} (repackedUrl resolves) -- skipping repack. Use '
          '--repack-barekit to force.');
      return 0;
    }

    // A PENDING-UPLOAD sentinel means an earlier run deliberately verified
    // the pipeline (--no-upload) but never actually published -- an
    // ordinary re-run must NOT silently escalate into a real upload just
    // because the idempotence check above correctly fails against a
    // placeholder URL (this exact gap caused a real, unintended
    // `gh release create`/`upload` earlier in flutter_pear-ovt.2.3's own
    // development). Uploading now requires the caller to explicitly pass
    // --repack-barekit, the same flag that forces everything else.
    if (upload && !force && sameVersion &&
        existingUrl != null && existingUrl.startsWith('PENDING-UPLOAD')) {
      stderr.writeln('repackBareKit: barekit-pin.json for ${pin.version} is '
          'still PENDING-UPLOAD from an earlier --no-upload run -- refusing '
          'to silently attempt a real upload. Re-run with --repack-barekit '
          '(uploading enabled) to actually publish it now.');
      return 1;
    }
  }

  final upstreamUrl = 'https://github.com/holepunchto/bare-kit/releases/'
      'download/v${pin.version}/prebuilds.zip';
  final tmp = Directory.systemTemp.createTempSync('fp_pack_barekit_repack');
  try {
    final zipFile = File('${tmp.path}/prebuilds.zip');
    stdout.writeln('downloading $upstreamUrl ...');
    await downloadFn(upstreamUrl, zipFile);

    final actualSha =
        sha256.convert(await zipFile.readAsBytes()).toString();
    if (actualSha != pin.upstreamSha256) {
      stderr.writeln(
          'repackBareKit: upstream checksum mismatch for $upstreamUrl -- '
          'expected ${pin.upstreamSha256}, got $actualSha. Aborting before '
          'any upload.');
      return 1;
    }

    // Upstream ships BareKit.xcframework under apple/ alongside other
    // platforms' prebuilds (flutter_pear-ovt.1.2's spike finding) -- only
    // that one subtree is needed, not the full ~354MB archive.
    final extractDir = Directory('${tmp.path}/extracted')
      ..createSync(recursive: true);
    final unzipResult = await Process.run('unzip', [
      '-q', zipFile.path, 'apple/BareKit.xcframework/*',
      '-d', extractDir.path,
    ]);
    if (unzipResult.exitCode != 0) {
      stderr.writeln('repackBareKit: unzip failed: ${unzipResult.stderr}');
      return unzipResult.exitCode;
    }
    final xcfwSrc = Directory('${extractDir.path}/apple/BareKit.xcframework');
    if (!xcfwSrc.existsSync()) {
      stderr.writeln('repackBareKit: apple/BareKit.xcframework/ not found '
          'in $upstreamUrl -- upstream\'s archive layout may have changed.');
      return 1;
    }

    final repackDir = Directory('${tmp.path}/repack')..createSync();
    _copyDirectorySync(xcfwSrc, Directory('${repackDir.path}/BareKit.xcframework'));

    final repackedZip =
        File('${tmp.path}/BareKit-${pin.version}-ios.xcframework.zip');
    final zipResult = await Process.run(
      'zip',
      ['-qr', repackedZip.path, 'BareKit.xcframework'],
      workingDirectory: repackDir.path,
    );
    if (zipResult.exitCode != 0) {
      stderr.writeln('repackBareKit: zip failed: ${zipResult.stderr}');
      return zipResult.exitCode;
    }

    final repackedSha256 =
        sha256.convert(await repackedZip.readAsBytes()).toString();

    String repackedUrl;
    if (upload) {
      stdout.writeln('uploading ${repackedZip.path} via gh release ...');
      repackedUrl = await uploadFn(pin.version, repackedZip);
    } else {
      repackedUrl = 'PENDING-UPLOAD: run `dart run flutter_pear:pack '
          '--repack-barekit` (uploading enabled) to publish the repacked '
          'BareKit-${pin.version}-ios.xcframework.zip and fill this in';
    }

    final pinJson = {
      'bareKitVersion': pin.version,
      'upstreamUrl': upstreamUrl,
      'upstreamSha256': pin.upstreamSha256,
      'repackedUrl': repackedUrl,
      'repackedSha256': repackedSha256,
      'generatedBy': 'dart run flutter_pear:pack --repack-barekit',
    };
    pinFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(pinJson)}\n');
    stdout.writeln('wrote ${pinFile.path}');
    return 0;
  } finally {
    tmp.deleteSync(recursive: true);
  }
}

/// Thrown when [generatePackageSwift] can't find a well-formed
/// `barekit-pin.json` or a non-empty `ios/addons/` to generate from.
class PackageSwiftException implements Exception {
  PackageSwiftException(this.message);
  final String message;
  @override
  String toString() => 'PackageSwiftException: $message';
}

/// Path (relative to `flutter_pear_bare`) [generatePackageSwift] writes to
/// -- the REAL Flutter SPM plugin package (flutter_pear-ovt.3.1), not the
/// pack epic's original standalone `ios/Package.swift` "BareKitShim"
/// (flutter_pear-ovt.2.4, superseded by this task and no longer written by
/// :pack at all). `addons/` inside this same directory is a committed
/// symlink to the sibling `ios/addons/` [linkNativeAddonsIos] populates --
/// see FlutterPearBarePlugin.swift's own Package.swift header comment for
/// why a `../`-relative path doesn't work here (Flutter's SPM plugin
/// assembly symlinks this whole package directory into its own ephemeral
/// tree, and a `..` resolves lexically against THAT outer symlink instead
/// of following it first).
const packageSwiftRelativePath = 'ios/flutter_pear_bare/Package.swift';

/// Derives a Swift-identifier-safe target name from an addon xcframework's
/// directory name (e.g. `bare-fs.4.7.3.xcframework` -> `AddonBareFs`) --
/// strips `.xcframework` and the trailing dotted version, then PascalCases
/// the remaining kebab-case package name with an `Addon` prefix. Same
/// convention the throwaway SPM shim spike used (flutter_pear-ovt.1.4), so
/// a maintainer reading both isn't looking at two different schemes.
String addonTargetName(String xcframeworkDirName) {
  final withoutExt =
      xcframeworkDirName.replaceAll(RegExp(r'\.xcframework$'), '');
  final withoutVersion = withoutExt.replaceAll(RegExp(r'(\.\d+)+$'), '');
  final pascal = withoutVersion
      .split('-')
      .where((s) => s.isNotEmpty)
      .map((s) => s[0].toUpperCase() + s.substring(1))
      .join();
  return 'Addon$pascal';
}

/// Generates `flutter_pear_bare/ios/flutter_pear_bare/Package.swift`
/// (flutter_pear-ovt.3.5, CEO decision 14): one pin source
/// (`barekit-pin.json` + the committed `ios/addons/*.xcframework` from
/// [linkNativeAddonsIos]), never hand-edited. Fails loud (nonzero, writes
/// nothing) if the pin is missing/malformed or `ios/addons/` has no
/// xcframeworks -- a partial manifest missing a target every addon
/// dlopens by name would be worse than no manifest at all.
///
/// Deterministic: addon targets are sorted by directory name, so unchanged
/// inputs regenerate a byte-identical file. The `BareKit` binary target's
/// `url` reads the `FLUTTER_PEAR_BAREKIT_URL` environment variable at SPM
/// RESOLUTION time (`ProcessInfo.processInfo.environment`, evaluated when
/// Xcode/`swift package resolve` reads the manifest, not at `:pack` time)
/// when set, falling back to the pinned `repackedUrl` -- an enterprise
/// proxy, air-gapped build, or a deleted-release recovery can override
/// where the binary is fetched from without ever touching the pinned
/// `checksum` (DX2 finding 48): a swapped URL still has to produce bytes
/// matching the same checksum, so this can redirect delivery but never
/// silently swap in different bytes.
///
/// The plugin's own Swift target (`flutter_pear_bare`, `CBareKit`) and its
/// `FlutterFramework` dependency (Flutter's own SPM-plugin convention) are
/// a fixed part of the template, not derived from the pin -- only the
/// `BareKit`/addon `binaryTarget`s below are pin/directory-driven.
Future<int> generatePackageSwift(String pkgRoot) async {
  final bareRoot = '$pkgRoot/../flutter_pear_bare';
  final pinFile = File('$bareRoot/barekit-pin.json');
  if (!pinFile.existsSync()) {
    stderr.writeln('generatePackageSwift: ${pinFile.path} missing -- run '
        'the BareKit repack step first.');
    return 1;
  }
  final Map<String, dynamic> pin;
  try {
    pin = jsonDecode(pinFile.readAsStringSync()) as Map<String, dynamic>;
  } catch (e) {
    stderr.writeln('generatePackageSwift: could not parse ${pinFile.path}: $e');
    return 1;
  }
  final repackedUrl = pin['repackedUrl'] as String?;
  final repackedSha256 = pin['repackedSha256'] as String?;
  if (repackedUrl == null || repackedSha256 == null) {
    stderr.writeln('generatePackageSwift: ${pinFile.path} is missing '
        'repackedUrl/repackedSha256.');
    return 1;
  }

  final addonsDir = Directory('$bareRoot/ios/addons');
  if (!addonsDir.existsSync()) {
    stderr.writeln('generatePackageSwift: ${addonsDir.path} missing -- run '
        'the iOS addon link step first.');
    return 1;
  }
  final addonDirNames = addonsDir
      .listSync()
      .whereType<Directory>()
      .map(_basename)
      .where((n) => n.endsWith('.xcframework'))
      .toList()
    ..sort();
  if (addonDirNames.isEmpty) {
    stderr.writeln(
        'generatePackageSwift: ${addonsDir.path} has no xcframeworks.');
    return 1;
  }

  final addonTargets =
      addonDirNames.map((n) => (name: addonTargetName(n), dirName: n)).toList();

  final b = StringBuffer()
    ..writeln('// swift-tools-version:5.9')
    ..writeln('// GENERATED by `dart run flutter_pear:pack` from '
        'barekit-pin.json -- DO NOT EDIT BY HAND (flutter_pear-ovt.3.5).')
    ..writeln('//')
    ..writeln('// Known SPM url: binaryTarget issues to watch for:')
    ..writeln('// - Xcode Cloud cache collision: flutter/flutter#187710')
    ..writeln('// - Cache-resolution footgun: flutter/flutter#186054')
    ..writeln('import Foundation')
    ..writeln('import PackageDescription')
    ..writeln()
    ..writeln('let bareKitURL = ProcessInfo.processInfo.environment['
        '"FLUTTER_PEAR_BAREKIT_URL"] ?? "$repackedUrl"')
    ..writeln()
    ..writeln('let package = Package(')
    ..writeln('    name: "flutter_pear_bare",')
    ..writeln('    platforms: [.iOS(.v13)],')
    ..writeln('    products: [')
    ..writeln('        // Flutter\'s SPM-plugin convention: '
        'FlutterGeneratedPluginSwiftPackage looks up this product by name')
    ..writeln('        // with underscores replaced by hyphens; the TARGET '
        'below keeps the underscored name.')
    ..writeln('        .library(name: "flutter-pear-bare", '
        'targets: ["flutter_pear_bare"]),')
    ..writeln('    ],')
    ..writeln('    dependencies: [')
    ..writeln('        .package(name: "FlutterFramework", '
        'path: "../FlutterFramework")')
    ..writeln('    ],')
    ..writeln('    targets: [')
    ..writeln('        // BareKit.xcframework ships no '
        'Modules/module.modulemap -- CBareKit re-exports BareKit.h as a')
    ..writeln('        // Clang module so Swift can `import CBareKit` '
        'without a bridging header (SPM targets can\'t use one).')
    ..writeln('        .target(')
    ..writeln('            name: "CBareKit",')
    ..writeln('            dependencies: ["BareKit"],')
    ..writeln('            path: "Sources/CBareKit",')
    ..writeln('            publicHeadersPath: "include"')
    ..writeln('        ),')
    ..writeln('        .target(')
    ..writeln('            name: "flutter_pear_bare",')
    ..writeln('            dependencies: [')
    ..writeln('                .product(name: "FlutterFramework", '
        'package: "FlutterFramework"),')
    ..writeln('                "CBareKit",');
  for (final a in addonTargets) {
    b.writeln('                "${a.name}",');
  }
  b
    ..writeln('            ]')
    ..writeln('        ),')
    ..writeln('        .binaryTarget(name: "BareKit", url: bareKitURL, '
        'checksum: "$repackedSha256"),');
  for (final a in addonTargets) {
    b.writeln('        .binaryTarget(name: "${a.name}", '
        'path: "addons/${a.dirName}"),');
  }
  b
    ..writeln('    ]')
    ..writeln(')');

  final outFile = File('$bareRoot/$packageSwiftRelativePath');
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(b.toString());
  stdout.writeln('wrote ${outFile.path}');
  return 0;
}

/// Default per-artifact size ceiling (eng-review 1A): GitHub hard-rejects a
/// single file at 100MB, so 95MB leaves headroom rather than pack.dart
/// tripping the platform's own limit with no advance warning.
const defaultMaxArtifactBytes = 95 * 1024 * 1024;

/// Default compressed pub.dev package-archive ceiling (pub.dev rejects a
/// package archive over 100MB compressed).
const defaultMaxArchiveBytes = 100 * 1024 * 1024;

/// Every file [checkArtifactSizes] guards and reports a growth delta for:
/// the committed pear-end bundle, every linked Android `.so` (per ABI),
/// every file inside every committed iOS addon `.xcframework` (individually
/// -- an xcframework is itself several files, any one of which could
/// individually approach the limit), and the BareKit pin manifest.
/// Enumeration tolerates any of these being entirely absent (a fresh
/// checkout before `:pack` has ever run, or `ios/addons` not yet created by
/// a sibling task) -- returns nothing for that category rather than
/// throwing, and automatically includes it the moment it exists.
List<File> _enumerateCommittedArtifacts(String pkgRoot) {
  final files = <File>[];

  final bundle = File('$pkgRoot/$bundleAssetPath');
  if (bundle.existsSync()) files.add(bundle);

  final bareRoot = '$pkgRoot/../flutter_pear_bare';

  final jniLibsRoot = Directory('$bareRoot/android/src/main/jniLibs');
  if (jniLibsRoot.existsSync()) {
    for (final abiDir in jniLibsRoot.listSync().whereType<Directory>()) {
      files.addAll(abiDir.listSync().whereType<File>());
    }
  }

  final addonsRoot = Directory('$bareRoot/ios/addons');
  if (addonsRoot.existsSync()) {
    for (final xcfw in addonsRoot.listSync().whereType<Directory>()) {
      for (final entry in xcfw.listSync(recursive: true)) {
        if (entry is File) files.add(entry);
      }
    }
  }

  final pinFile = File('$bareRoot/barekit-pin.json');
  if (pinFile.existsSync()) files.add(pinFile);

  return files;
}

/// Snapshots every [_enumerateCommittedArtifacts] file's size, keyed by
/// absolute path -- taken at [main]'s very start, before any artifact
/// write, so [checkArtifactSizes] can print a genuine before/after delta
/// rather than comparing a state to itself.
Map<String, int> _snapshotArtifactSizes(String pkgRoot) => {
      for (final f in _enumerateCommittedArtifacts(pkgRoot)) f.path: f.lengthSync(),
    };

/// A human-readable size string (`"2.05 MB"`, `"614 B"`) -- bytes under 1KB
/// print exactly, KB/MB print with 2 decimal places.
String _humanSize(num bytes) {
  final abs = bytes.abs();
  if (abs >= 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  if (abs >= 1024) return '${(bytes / 1024).toStringAsFixed(2)} KB';
  return '${bytes.round()} B';
}

/// A signed human-readable delta (`"+2.05 MB"`, `"-614 B"`, `"+0 B"`).
String _humanSizeDelta(int delta) => '${delta >= 0 ? '+' : '-'}${_humanSize(delta.abs())}';

/// Runs `dart pub publish --dry-run` in [pkgDir] and parses pub's own
/// `Total compressed archive size: <N> <unit>.` line -- real network/`gh`-
/// style I/O, factored out so [checkArtifactSizes]'s tests can inject a
/// fake instead. Parses the size line even when `--dry-run` exits nonzero
/// for unrelated validation warnings/hints (e.g. uncommitted files, a
/// pubspec_overrides.yaml override) -- those are real, but not this
/// guard's job; only a genuinely absent size line is this function's own
/// failure (returns `null`).
Future<int?> _pubDryRunArchiveSize(String pkgDir) async {
  final result = await Process.run(
    'dart',
    ['pub', 'publish', '--dry-run'],
    workingDirectory: pkgDir,
  );
  final combined = '${result.stdout}\n${result.stderr}';
  final match = RegExp(r'''Total compressed archive size:\s*([\d.]+)\s*(B|KB|MB|GB)\.''')
      .firstMatch(combined);
  if (match == null) return null;
  final value = double.parse(match.group(1)!);
  final multiplier = switch (match.group(2)!) {
    'B' => 1,
    'KB' => 1024,
    'MB' => 1024 * 1024,
    'GB' => 1024 * 1024 * 1024,
    _ => 1,
  };
  return (value * multiplier).round();
}

/// Guards [_enumerateCommittedArtifacts] against two size ceilings and
/// prints a human-readable growth delta (eng-review 1A, strengthened by
/// the outside voice) -- called at the END of `main()`, after every
/// artifact write, so it always judges the fresh state:
///
/// 1. Per-artifact: any single committed file at or above
///    [maxArtifactBytes] (default [defaultMaxArtifactBytes], overridable
///    via the `FLUTTER_PEAR_PACK_MAX_ARTIFACT` env var in bytes so the
///    guard can be demonstrated firing without an actual 95MB file) prints
///    the offending path and size, then fails loud.
/// 2. Archive: `dart pub publish --dry-run` (via [archiveSizeFn], real
///    network I/O by default) in both `flutter_pear` and
///    `flutter_pear_bare` must each report a compressed size under
///    [maxArchiveBytes] (default [defaultMaxArchiveBytes], overridable via
///    `FLUTTER_PEAR_PACK_MAX_ARCHIVE`) -- flutter/flutter#130210 means pub
///    downloads every dependency regardless of the consuming app's target
///    platform, so both packages' archives reach every consumer (decision
///    D20, accept-and-disclose) and must stay under pub.dev's own ceiling.
///
/// The growth delta always prints (even on a guard failure below it, so a
/// maintainer sees what grew right before learning why the run failed):
/// every changed path's before/after size plus a grand total, computed
/// against [beforeSizes] ([main] snapshots this via
/// [_snapshotArtifactSizes] before any artifact write).
Future<int> checkArtifactSizes(
  String pkgRoot, {
  required Map<String, int> beforeSizes,
  int? maxArtifactBytes,
  int? maxArchiveBytes,
  Future<int?> Function(String pkgDir) archiveSizeFn = _pubDryRunArchiveSize,
}) async {
  final maxArtifact = maxArtifactBytes ??
      int.tryParse(Platform.environment['FLUTTER_PEAR_PACK_MAX_ARTIFACT'] ?? '') ??
      defaultMaxArtifactBytes;
  final maxArchive = maxArchiveBytes ??
      int.tryParse(Platform.environment['FLUTTER_PEAR_PACK_MAX_ARCHIVE'] ?? '') ??
      defaultMaxArchiveBytes;

  final afterFiles = _enumerateCommittedArtifacts(pkgRoot);
  final afterSizes = {for (final f in afterFiles) f.path: f.lengthSync()};

  stdout.writeln('== committed artifact size delta ==');
  final allPaths = {...beforeSizes.keys, ...afterSizes.keys}.toList()..sort();
  var beforeTotal = 0;
  var afterTotal = 0;
  var anyChanged = false;
  for (final path in allPaths) {
    final before = beforeSizes[path] ?? 0;
    final after = afterSizes[path] ?? 0;
    beforeTotal += before;
    afterTotal += after;
    if (before != after) {
      anyChanged = true;
      stdout.writeln(
          '  $path: ${_humanSize(before)} -> ${_humanSize(after)} (${_humanSizeDelta(after - before)})');
    }
  }
  if (!anyChanged) stdout.writeln('  (no committed artifact changed size)');
  stdout.writeln(
      '  TOTAL: ${_humanSize(beforeTotal)} -> ${_humanSize(afterTotal)} (${_humanSizeDelta(afterTotal - beforeTotal)})');

  for (final entry in afterSizes.entries) {
    if (entry.value >= maxArtifact) {
      stderr.writeln('checkArtifactSizes: ${entry.key} is '
          '${_humanSize(entry.value)}, at or above the '
          '${_humanSize(maxArtifact)} per-artifact limit.');
      return 1;
    }
  }

  for (final dir in [pkgRoot, '$pkgRoot/../flutter_pear_bare']) {
    final size = await archiveSizeFn(dir);
    if (size == null) {
      stderr.writeln('checkArtifactSizes: could not find a "Total '
          'compressed archive size" line from dart pub publish --dry-run '
          'in $dir.');
      return 1;
    }
    if (size >= maxArchive) {
      stderr.writeln('checkArtifactSizes: $dir\'s compressed pub archive is '
          '${_humanSize(size)}, at or above the ${_humanSize(maxArchive)} '
          'ceiling.');
      return 1;
    }
  }

  return 0;
}

/// SPDX identifiers this repo accepts for a bundled dependency (E9.2,
/// LICENSING.md's "MIT / Apache-2.0 / BSD / ISC / 0BSD" rule, plus
/// `Unlicense` -- the SPDX id for a public-domain dedication, distinct from
/// npm's `UNLICENSED` meaning "no license granted" below).
const _allowedSpdxIds = {
  'MIT',
  'Apache-2.0',
  'BSD-2-Clause',
  'BSD-3-Clause',
  'ISC',
  '0BSD',
  'Unlicense',
};

/// Case-insensitive prefixes that fail the build outright, no matter what
/// else is true about the module -- the copyleft families LICENSING.md
/// names as never-acceptable, checked as prefixes since real-world SPDX ids
/// carry version suffixes (`GPL-3.0-only`, `LGPL-2.1-or-later`, ...).
const _deniedSpdxPrefixes = ['GPL', 'AGPL', 'LGPL', 'MPL', 'SSPL'];

/// Case-insensitive text markers that fail a module whose `package.json`
/// has no `license` field at all to run [_classifySpdx] against, but whose
/// bundled LICENSE file's own text self-identifies as copyleft -- a bare
/// "no field" module would otherwise sail through unclassified just
/// because there's nothing to feed the SPDX check (review finding, E9.2).
const _copyleftLicenseTextMarkers = [
  'GNU GENERAL PUBLIC LICENSE',
  'GNU LESSER GENERAL PUBLIC LICENSE',
  'GNU AFFERO GENERAL PUBLIC LICENSE',
  'MOZILLA PUBLIC LICENSE',
  'SERVER SIDE PUBLIC LICENSE',
];

/// Thrown by [collectThirdPartyLicenses] when a bundled module's license
/// can't be verified permissive -- `main` catches this, prints it, and
/// exits nonzero rather than silently shipping an unreviewed license.
class LicenseViolationException implements Exception {
  LicenseViolationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Classifies a `package.json` `license` value against [_allowedSpdxIds]
/// and [_deniedSpdxPrefixes]. Deliberately conservative: SPDX *expressions*
/// (`(MIT OR Apache-2.0)`, `SEE LICENSE IN LICENSE.txt` without a bundled
/// file, or anything else this repo doesn't recognize outright) classify as
/// [_SpdxVerdict.unknown] rather than being cleverly parsed -- a human
/// reviewing a genuinely new license shape is the point, not a parser that
/// might wave one through.
_SpdxVerdict _classifySpdx(String license) {
  final upper = license.trim().toUpperCase();
  // Compared uppercased on both sides -- a real-world package.json using
  // non-canonical casing (e.g. "mit", "apache-2.0") is exactly as
  // permissive as the canonical spelling and must not fail the build just
  // because the allow-list previously compared exact-case while the
  // deny-list below already compared case-insensitively (review finding).
  if (_allowedSpdxIds.any((id) => id.toUpperCase() == upper)) {
    return _SpdxVerdict.allowed;
  }
  if (upper == 'UNLICENSED') return _SpdxVerdict.denied;
  for (final prefix in _deniedSpdxPrefixes) {
    if (upper.startsWith(prefix)) return _SpdxVerdict.denied;
  }
  return _SpdxVerdict.unknown;
}

enum _SpdxVerdict { allowed, denied, unknown }

/// `bare-pack --host` values [buildBundle] targets -- exactly the 64-bit
/// hosts [nativeAddonAbis] links addons for (2 Android ABIs) plus both iOS
/// hosts, so bare-pack's asked-for hosts and bare-link's actually-linked
/// ABIs can never silently drift apart (32-bit `android-arm`/`android-ia32`
/// deliberately excluded -- same decision documented on [nativeAddonAbis]).
/// A documented top-level const, not inlined in [buildBundle], so tests can
/// assert it without running bare-pack.
const bundleHosts = [
  'android-arm64',
  'android-x64',
  'ios-arm64',
  'ios-arm64-simulator',
];

/// Bundles `pear-end/index.js` into [bundleAssetPath] (under [pkgRoot]) via
/// `bare-pack`, targeting [bundleHosts] (v0.2, E1 feasibility check #1: a
/// bare-pack build combining android+ios hosts works, so ONE bundle ships to
/// both platforms rather than a per-platform pair -- see
/// flutter_pear-ovt.1.6), with native addons resolved as `linked:` (required
/// on mobile, where addons must be linked ahead of time rather than loaded
/// from `file:` prebuilds — see bare-pack's "Linking").
///
/// Explicit `--host` flags, not `--preset android` (which is bare-pack's
/// shorthand for `--linked --host android-arm --host android-arm64 --host
/// android-ia32 --host android-x64`, mirroring the invocation
/// `holepunchto/bare-android` uses in its own Gradle `packApp` task, and
/// which also links -- wasting time -- the 32-bit `armeabi-v7a`/`x86`
/// output this repo has never shipped): no preset covers android+ios
/// together, so [bundleHosts] spells out exactly the hosts this repo needs.
/// Returns bare-pack's exit code (0 on success) instead of throwing, so
/// callers can propagate the real failure reason.
Future<int> buildBundle(String pkgRoot) async {
  final entry = '$pkgRoot/pear-end/index.js';
  final out = '$pkgRoot/$bundleAssetPath';
  await Directory('$pkgRoot/assets').create(recursive: true);

  // Written before bare-pack runs: index.js requires ./version, so it must
  // exist to be bundled in (E2.5's stale-worklet detection reads it back at
  // runtime via the attach.info RPC method).
  writeBundleVersion(pkgRoot, computeBundleVersion(pkgRoot));

  final result = await Process.run(
    'bare-pack',
    [
      '--linked',
      for (final host in bundleHosts) ...['--host', host],
      '--out', out,
      entry,
    ],
  );
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    stderr.writeln('bare-pack failed. Install it: npm i -g bare-pack');
    return result.exitCode;
  }
  stdout.writeln('wrote $out');
  return 0;
}

/// A short, deterministic version tag for the pear-end bundle, derived from
/// the content of the JS files this repo authors (`index.js`, `schema.js`)
/// plus `package-lock.json` -- NOT the full `node_modules` tree, whose
/// resolved content that lockfile already pins exactly. Changes
/// automatically whenever any of these change (including an `npm update`
/// that only bumps a transitive dependency), so a stale worklet is
/// detectable without a human remembering to bump a version number by hand.
String computeBundleVersion(String pkgRoot) {
  final bytes = [
    ...File('$pkgRoot/pear-end/index.js').readAsBytesSync(),
    ...File('$pkgRoot/pear-end/schema.js').readAsBytesSync(),
    ...File('$pkgRoot/pear-end/package-lock.json').readAsBytesSync(),
  ];
  return sha256.convert(bytes).toString().substring(0, 16);
}

/// Writes [version] to both sides of E2.5's stale-bundle check: a gitignored
/// `pear-end/version.js` (an intermediate `index.js` requires -- its content
/// ends up embedded in the committed `assets/pear-end.bundle`, so the
/// intermediate file itself isn't) and the committed
/// `lib/src/bundle_version.dart` Dart constant `Pear.start` compares against.
void writeBundleVersion(String pkgRoot, String version) {
  File('$pkgRoot/pear-end/version.js').writeAsStringSync(
    "'use strict'\n"
    '// Generated by `dart run flutter_pear:pack` -- do not edit by hand.\n'
    "module.exports = '$version'\n",
  );

  Directory('$pkgRoot/lib/src').createSync(recursive: true);
  File('$pkgRoot/lib/src/bundle_version.dart').writeAsStringSync(
    '/// The pear-end bundle version this package ships, baked in by\n'
    '/// `dart run flutter_pear:pack`. Generated -- do not edit by hand.\n'
    "const String kPearEndBundleVersion = '$version';\n",
  );
}

/// Aggregates the LICENSE and NOTICE files of every module under
/// `pear-end/node_modules` (walked recursively, so a dependency's own
/// non-hoisted `node_modules` is covered too) plus a static entry for the
/// natively-fetched Bare Kit binaries into `THIRD_PARTY_LICENSES` (and
/// `NOTICE`) at [pkgRoot]. Returns the number of modules whose license was
/// captured.
///
/// Enforces this repo's permissive-only policy (LICENSING.md) as it goes:
/// throws [LicenseViolationException] naming the offending module for a
/// forbidden SPDX id (GPL/AGPL/LGPL/MPL/SSPL/`UNLICENSED`), an unrecognized
/// one, or a module with neither a bundled LICENSE file nor a
/// `package.json` `license` field to fall back on. A module is never
/// silently skipped — either it's captured or the run fails loud.
///
/// No-op returning 0 if `node_modules` is absent — run `npm install` in
/// `pear-end/` first. Handles scoped (`@org/pkg`) packages.
///
/// [skipBareKitAttribution] (default `false`, so a real run always requires
/// the BareKit entry -- flutter_pear-ovt.2.6) lets an isolated test fixture
/// exercising unrelated license behavior opt out of needing a full sibling
/// `flutter_pear_bare/` checkout (gradle file + `barekit-pin.json`) just to
/// reach this function at all.
Future<int> collectThirdPartyLicenses(
  String pkgRoot, {
  bool skipBareKitAttribution = false,
}) async {
  final modules = Directory('$pkgRoot/pear-end/node_modules');
  if (!modules.existsSync()) {
    stderr.writeln('skip licenses: ${modules.path} missing — '
        'run `npm install` in pear-end/ first.');
    return 0;
  }

  final pkgDirs = _collectPackageDirs(modules);
  // Sorted by nesting depth (ascending) BEFORE dedup, not after -- a plain
  // DFS visits directories in raw (OS-dependent) listing order, which does
  // NOT guarantee a hoisted top-level copy is seen before a same-version
  // copy nested inside some other package's own node_modules (review
  // finding: confirmed by repro, a nested copy won when its container
  // directory happened to sort first). Depth-first here means "shallowest
  // path wins the dedup", independent of directory listing order.
  pkgDirs.sort((a, b) {
    final depthA = '/node_modules/'.allMatches(a.path).length;
    final depthB = '/node_modules/'.allMatches(b.path).length;
    return depthA != depthB
        ? depthA.compareTo(depthB)
        : a.path.compareTo(b.path);
  });
  // Dedup by name@version, not by path: the same resolved package can
  // legitimately appear both hoisted to the top level and nested inside a
  // dependency that needed a conflicting version pinned -- but the common
  // case (identical version at both spots) would otherwise double every
  // license entry. First occurrence wins, which is now genuinely the
  // shallowest (most-hoisted) copy per the depth sort above.
  final seen = <String>{};
  final dedupedDirs = <Directory>[];
  for (final dir in pkgDirs) {
    if (seen.add(_moduleKey(dir))) dedupedDirs.add(dir);
  }
  dedupedDirs.sort((a, b) => a.path.compareTo(b.path));

  final licenses = StringBuffer()
    ..writeln('Third-party modules bundled by flutter_pear.')
    ..writeln(
        'Generated by `dart run flutter_pear:pack` — do not edit by hand.')
    ..writeln();
  final notices = StringBuffer();
  var count = 0;

  for (final dir in dedupedDirs) {
    final licenseFiles = dir.listSync().whereType<File>().where((f) {
      final n = _basename(f).toUpperCase();
      return n.startsWith('LICENSE') ||
          n.startsWith('LICENCE') ||
          n.startsWith('COPYING');
    }).toList();
    final hasLicenseFile = licenseFiles.isNotEmpty;
    final license = _readLicenseField(dir);
    final id = _moduleId(dir, license);

    if (license == null && !hasLicenseFile) {
      throw LicenseViolationException(
          '$id has no LICENSE file and no package.json "license" field -- '
          'cannot verify it is permissively licensed.');
    }
    // No package.json "license" field to run _classifySpdx against -- the
    // SPDX check below is a no-op for this module, so a copyleft LICENSE
    // file would otherwise sail through uncaught (review finding: a module
    // with a real GPL LICENSE file but no license field was captured with
    // zero enforcement). A text-marker sniff of the bundled file itself is
    // the fallback signal in that specific gap; it does not run when a
    // license field IS present, since that's already the checked case.
    if (license == null && hasLicenseFile) {
      for (final f in licenseFiles) {
        final upperText = f.readAsStringSync().toUpperCase();
        for (final marker in _copyleftLicenseTextMarkers) {
          if (upperText.contains(marker)) {
            throw LicenseViolationException(
                '$id has no package.json "license" field, and its bundled '
                '${_basename(f)} self-identifies as "$marker" -- forbidden '
                'by this project\'s permissive-only policy (LICENSING.md).');
          }
        }
      }
    }
    // "SEE LICENSE IN <file>" is a legitimate npm convention meaning "the
    // bundled file IS the license" -- only trustworthy when that file is
    // actually present, so it still needs the hasLicenseFile check.
    final seeLicenseInFile =
        license != null && license.toUpperCase().startsWith('SEE LICENSE IN');
    if (license != null && !seeLicenseInFile) {
      final verdict = _classifySpdx(license);
      if (verdict == _SpdxVerdict.denied) {
        throw LicenseViolationException(
            '$id is forbidden by this project\'s permissive-only policy '
            '(LICENSING.md) -- reject GPL/AGPL/LGPL/MPL/SSPL/UNLICENSED '
            'dependencies.');
      }
      if (verdict == _SpdxVerdict.unknown) {
        throw LicenseViolationException(
            '$id has an unrecognized license "$license" -- add it to the '
            'allow-list in bin/pack.dart only after confirming it is '
            'permissive, or drop the dependency.');
      }
    } else if (seeLicenseInFile && !hasLicenseFile) {
      throw LicenseViolationException(
          '$id declares "$license" but ships no LICENSE file to back it.');
    }

    licenses
      ..writeln('=' * 72)
      ..writeln(id)
      ..writeln('=' * 72);
    if (hasLicenseFile) {
      for (final f in licenseFiles) {
        licenses
          ..writeln(f.readAsStringSync().trimRight())
          ..writeln();
      }
    } else {
      // No bundled LICENSE file, but package.json declares an allow-listed
      // SPDX id (e.g. corestore) -- attribute via the SPDX id rather than
      // silently dropping the module from the manifest entirely.
      licenses
        ..writeln('No LICENSE file is bundled by this module upstream; its '
            'package.json declares "$license". See '
            'https://spdx.org/licenses/$license.html for the full text.')
        ..writeln();
    }
    count++;

    final notice = File('${dir.path}/NOTICE');
    if (notice.existsSync()) {
      notices
        ..writeln('--- $id ---')
        ..writeln(notice.readAsStringSync().trimRight())
        ..writeln();
    }
  }

  if (!skipBareKitAttribution) {
    await _addBareKitStaticEntry(pkgRoot, licenses);
  }

  final licensesText = licenses.toString();
  // Belt and suspenders: _addBareKitStaticEntry above no longer has a
  // silent-no-op path (it throws instead), but this guards against a
  // FUTURE refactor accidentally reintroducing one -- the entry's
  // presence is asserted directly against the text about to be written,
  // not inferred from control flow.
  if (!skipBareKitAttribution && !licensesText.contains('bare-kit@')) {
    throw LicenseViolationException(
        'THIRD_PARTY_LICENSES is missing its bare-kit@ attribution entry -- '
        'this must never silently vanish.');
  }
  File('$pkgRoot/THIRD_PARTY_LICENSES').writeAsStringSync(licensesText);
  stdout.writeln('wrote THIRD_PARTY_LICENSES ($count modules)');
  // Always (re)written, even when empty -- a prior run's NOTICE must never
  // survive once the module that contributed it is gone.
  File('$pkgRoot/NOTICE').writeAsStringSync(notices.toString());
  stdout.writeln('wrote NOTICE');
  // ponytail: also register with Flutter's LicenseRegistry for the in-app
  // Licenses page — wire when the bundle actually loads (M1).
  return count;
}

/// Recursively walks [nodeModules], returning every package directory
/// (including scoped `@org/pkg` ones) at any nesting depth -- npm hoists
/// what it can to the top level but nests a dependency's own copy when a
/// version conflict forces it, and a collector that only looked at the top
/// level would silently miss that copy's license entirely.
List<Directory> _collectPackageDirs(Directory nodeModules, [int depth = 0]) {
  // A depth cap, not cycle detection: a symlink cycle under node_modules
  // (e.g. via `npm link` or a local `file:` dependency) would otherwise
  // recurse until the OS's own ELOOP surfaces as an uncaught
  // FileSystemException. No real dependency nests this deep today.
  if (depth > 10) return const [];
  final result = <Directory>[];
  for (final e in nodeModules.listSync().whereType<Directory>()) {
    final name = _basename(e);
    if (name.startsWith('.')) continue;
    if (name.startsWith('@')) {
      for (final scoped in e.listSync().whereType<Directory>()) {
        if (_basename(scoped).startsWith('.')) continue;
        result.add(scoped);
        result.addAll(_nestedPackageDirs(scoped, depth));
      }
    } else {
      result.add(e);
      result.addAll(_nestedPackageDirs(e, depth));
    }
  }
  return result;
}

List<Directory> _nestedPackageDirs(Directory pkg, int depth) {
  final nested = Directory('${pkg.path}/node_modules');
  return nested.existsSync()
      ? _collectPackageDirs(nested, depth + 1)
      : const [];
}

/// A static attribution entry for the Bare Kit native binaries: fetched as
/// a GitHub release archive at Android build time (`flutter_pear_bare`'s
/// Gradle task), never an npm package, so [_collectPackageDirs] can't see
/// it. Reads the pinned version out of that Gradle file rather than
/// hardcoding a second copy that could silently drift from the one
/// actually fetched. Soft-skips (a stderr note, no throw) when that file
/// isn't found -- e.g. isolated test fixtures with no sibling
/// `flutter_pear_bare` checkout -- since this entry only matters for the
/// real repo tree's release manifest.
/// Appends the `bare-kit@<version>` attribution entry to [licenses] --
/// BareKit's prebuilt native binaries are fetched at build time, never an
/// npm package, so [collectThirdPartyLicenses]'s `node_modules` walk can
/// never discover them itself.
///
/// Never soft-skips (flutter_pear-ovt.2.6, Eng2 finding — a moved/renamed
/// gradle file used to silently drop this entry from a release manifest
/// with only a stderr note): a missing/malformed `build.gradle` or
/// `barekit-pin.json` throws [LicenseViolationException], which
/// [collectThirdPartyLicenses]'s own caller (`main`) already catches and
/// exits nonzero for.
Future<void> _addBareKitStaticEntry(
    String pkgRoot, StringBuffer licenses) async {
  final gradleFile = File('$pkgRoot/../flutter_pear_bare/android/build.gradle');
  if (!gradleFile.existsSync()) {
    throw LicenseViolationException(
        '${gradleFile.path} not found -- cannot attribute the bundled Bare '
        'Kit native binaries.');
  }
  final match = RegExp(r'''bareKitVersion\s*=\s*["']([^"']+)["']''')
      .firstMatch(gradleFile.readAsStringSync());
  if (match == null) {
    throw LicenseViolationException(
        'could not find bareKitVersion in ${gradleFile.path} -- cannot '
        'attribute the bundled Bare Kit native binaries.');
  }
  final version = match.group(1)!;

  final pinFile = File('$pkgRoot/../flutter_pear_bare/barekit-pin.json');
  if (!pinFile.existsSync()) {
    throw LicenseViolationException(
        '${pinFile.path} not found -- run `dart run flutter_pear:pack '
        '--repack-barekit` first to attribute the iOS BareKit.xcframework '
        'asset.');
  }
  final Map<String, dynamic> pin;
  try {
    pin = jsonDecode(pinFile.readAsStringSync()) as Map<String, dynamic>;
  } catch (e) {
    throw LicenseViolationException('could not parse ${pinFile.path}: $e');
  }
  final upstreamUrl = pin['upstreamUrl'] as String?;
  final repackedUrl = pin['repackedUrl'] as String?;
  if (upstreamUrl == null || repackedUrl == null) {
    throw LicenseViolationException(
        '${pinFile.path} is missing upstreamUrl/repackedUrl -- run `dart '
        'run flutter_pear:pack --repack-barekit` first.');
  }

  licenses
    ..writeln('=' * 72)
    ..writeln('bare-kit@$version  (Apache-2.0)')
    ..writeln('=' * 72)
    ..writeln('Prebuilt native binaries (including the bare runtime itself), '
        'not an npm package, so no LICENSE file lives under node_modules. '
        'Apache-2.0 per LICENSING.md; see the upstream release for the '
        'full license text. Covers BOTH the Android .so and iOS '
        '.xcframework forms this repo ships:')
    ..writeln('  Android: fetched from $upstreamUrl at build time '
        '(checksum-pinned in flutter_pear_bare/android/build.gradle).')
    ..writeln('  iOS: BareKit.xcframework repacked from the same upstream '
        'release and rehosted at $repackedUrl (two-link checksum chain in '
        'flutter_pear_bare/barekit-pin.json: $upstreamUrl -> $repackedUrl).')
    ..writeln('The committed iOS addon xcframeworks under '
        'flutter_pear_bare/ios/addons/ are built from the same npm modules '
        'already attributed above in this file -- the Android .so and iOS '
        '.xcframework forms are two build outputs of identical source, not '
        'separate dependencies needing their own entries.')
    ..writeln();
}

String _basename(FileSystemEntity e) =>
    e.uri.pathSegments.where((s) => s.isNotEmpty).last;

Map<String, dynamic>? _readPackageJson(Directory dir) {
  final pj = File('${dir.path}/package.json');
  if (!pj.existsSync()) return null;
  try {
    return jsonDecode(pj.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

/// The `license` field, normalized to a plain SPDX string. Handles both the
/// modern `"license": "MIT"` form and the deprecated `"license": {"type":
/// "MIT", ...}` object form some older packages still ship; the even older
/// `"licenses": [...]` array form is intentionally not special-cased --
/// unrecognized shapes fall through to null, which fails the build via the
/// missing-license-field path rather than guessing.
String? _readLicenseField(Directory dir) {
  final m = _readPackageJson(dir);
  final license = m?['license'];
  if (license is String && license.trim().isNotEmpty) return license.trim();
  if (license is Map && license['type'] is String) {
    return (license['type'] as String).trim();
  }
  return null;
}

String _moduleKey(Directory dir) {
  final m = _readPackageJson(dir);
  final name = m?['name'] as String? ?? _basename(dir);
  final version = m?['version'] as String? ?? '?';
  return '$name@$version';
}

String _moduleId(Directory dir, String? license) {
  final fallback = _basename(dir);
  final m = _readPackageJson(dir);
  if (m == null) return fallback;
  return '${m['name'] ?? fallback}@${m['version'] ?? '?'}  '
      '(${license ?? 'license?'})';
}
