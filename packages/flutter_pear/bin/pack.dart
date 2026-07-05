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

  final code = await buildBundle(pkgRoot);
  if (code != 0) exit(code);
  final linkCode = await linkNativeAddons(pkgRoot);
  if (linkCode != 0) exit(linkCode);
  try {
    await collectThirdPartyLicenses(pkgRoot);
  } on LicenseViolationException catch (e) {
    stderr.writeln('license check failed: $e');
    exit(1);
  }
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
    stderr.writeln(
        'skip linkNativeAddons: $pearEndDir/node_modules missing — '
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

    final jniLibsRoot = Directory(
        '$pkgRoot/../flutter_pear_bare/android/src/main/jniLibs');
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

/// Bundles `pear-end/index.js` into [bundleAssetPath] (under [pkgRoot]) via
/// `bare-pack`, targeting every Android ABI with native addons resolved as
/// `linked:` (required on mobile, where addons must be linked ahead of time
/// rather than loaded from `file:` prebuilds — see bare-pack's "Linking").
///
/// `--preset android` is bare-pack's shorthand for `--linked --host
/// android-arm --host android-arm64 --host android-ia32 --host android-x64`
/// (mirrors the invocation `holepunchto/bare-android` uses in its own Gradle
/// `packApp` task). Returns bare-pack's exit code (0 on success) instead of
/// throwing, so callers can propagate the real failure reason.
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
    ['--preset', 'android', '--out', out, entry],
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
Future<int> collectThirdPartyLicenses(String pkgRoot) async {
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
    return depthA != depthB ? depthA.compareTo(depthB) : a.path.compareTo(b.path);
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

  await _addBareKitStaticEntry(pkgRoot, licenses);

  File('$pkgRoot/THIRD_PARTY_LICENSES').writeAsStringSync(licenses.toString());
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
Future<void> _addBareKitStaticEntry(
    String pkgRoot, StringBuffer licenses) async {
  final gradleFile =
      File('$pkgRoot/../flutter_pear_bare/android/build.gradle');
  if (!gradleFile.existsSync()) {
    stderr.writeln('note: ${gradleFile.path} not found — skipping the '
        'bare-kit static license entry.');
    return;
  }
  final match = RegExp(r'''bareKitVersion\s*=\s*["']([^"']+)["']''')
      .firstMatch(gradleFile.readAsStringSync());
  if (match == null) {
    throw LicenseViolationException(
        'could not find bareKitVersion in ${gradleFile.path} -- cannot '
        'attribute the bundled Bare Kit native binaries.');
  }
  final version = match.group(1)!;
  licenses
    ..writeln('=' * 72)
    ..writeln('bare-kit@$version  (Apache-2.0)')
    ..writeln('=' * 72)
    ..writeln('Prebuilt native binaries (including the bare runtime itself) '
        'fetched from https://github.com/holepunchto/bare-kit/releases/'
        'tag/v$version at Android build time -- not an npm package, so no '
        'LICENSE file lives under node_modules. Apache-2.0 per '
        'LICENSING.md; see the upstream release for the full license text.')
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
