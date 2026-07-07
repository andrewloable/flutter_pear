// `dart run flutter_pear:check_pins` — a release_gate.sh leg (v0.2 plan Test
// Requirements, pin_consistency_check; DX2 decision 50). One BareKit release
// is pinned in several places across two platforms and they must never
// drift silently: this cross-checks every pin location against every other,
// plus the bundle asset name chain and the baked bundle version embedded in
// every committed bundle asset.
//
// Some pin locations don't exist yet (the iOS pack/podspec epics haven't
// landed): those legs print a loud SKIPPED-MISSING line instead of being
// silently omitted, so the tool's own coverage can't quietly shrink without
// anyone noticing. `--strict` (what release_gate.sh runs with) turns every
// SKIPPED-MISSING line into a failure instead.
//
// ponytail: plain regex/line extraction, matching bin/check_compatibility.dart's
// own style — this repo controls every source file's format, so a full
// Gradle/Podfile/SwiftPM parser would be more code for no real benefit.
import 'dart:convert';
import 'dart:io';

import 'pack.dart' show bundleAssetPath;

Future<void> main(List<String> args) async {
  final strict = args.contains('--strict');
  // `dart run` executes a cached kernel snapshot, so Platform.script doesn't
  // point at this file on disk (see bin/pack.dart's own note on the same
  // issue). Run from the package root: `cd packages/flutter_pear && dart run
  // flutter_pear:check_pins`.
  final pkgRoot = Directory.current.path;
  try {
    final result = checkPins(pkgRoot);
    for (final skip in result.skipped) {
      stdout.writeln('SKIPPED-MISSING: $skip');
    }
    final effectiveMismatches = [
      ...result.mismatches,
      if (strict)
        for (final skip in result.skipped)
          PinMismatch(
            field: skip,
            valueA: '(missing)',
            sourceA: '--strict',
            valueB: '(required)',
            sourceB: '--strict',
          ),
    ];
    if (effectiveMismatches.isEmpty) {
      stdout.writeln('\nAll pins agree (${result.checkedCount} checked, '
          '${result.skipped.length} leg(s) skipped as not-yet-landed).');
      return;
    }
    stderr.writeln('\n${effectiveMismatches.length} pin(s) out of sync:\n');
    for (final m in effectiveMismatches) {
      stderr.writeln('  - ${m.describe()}');
    }
    exit(1);
  } on PinCheckException catch (e) {
    stderr.writeln('check_pins failed: $e');
    exit(1);
  }
}

/// One disagreement between two pin sources that both exist — never raised
/// for a leg that's simply missing (see [PinCheckResult.skipped] instead).
class PinMismatch {
  PinMismatch({
    required this.field,
    required this.valueA,
    required this.sourceA,
    required this.valueB,
    required this.sourceB,
  });

  /// Human-readable name of the checked field, e.g. `"BareKit version"`.
  final String field;
  final String valueA;
  final String sourceA;
  final String valueB;
  final String sourceB;

  /// A single-line, greppable description naming both disagreeing sources
  /// and both values.
  String describe() =>
      '$field: $sourceA says "$valueA", but $sourceB says "$valueB"';
}

/// Thrown when the check itself cannot run to completion — a pin source that
/// is expected to exist today (e.g. the Android Gradle file) is missing or
/// malformed. Distinct from [PinMismatch] (a real disagreement between two
/// existing sources) and from [PinCheckResult.skipped] (a not-yet-landed
/// leg, which is expected and not an error).
class PinCheckException implements Exception {
  PinCheckException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Result of [checkPins]: real disagreements, not-yet-landed legs skipped
/// (each a human-readable reason string), and how many fields were actually
/// compared.
class PinCheckResult {
  PinCheckResult(
      {required this.mismatches,
      required this.skipped,
      required this.checkedCount});
  final List<PinMismatch> mismatches;
  final List<String> skipped;
  final int checkedCount;
}

/// Cross-checks every BareKit/bundle pin location this repo knows about.
/// [pkgRoot] is expected to be `packages/flutter_pear` inside a real (or
/// fixture) checkout of this monorepo, matching bin/check_compatibility.dart's
/// own convention — sibling packages are located relative to it.
PinCheckResult checkPins(String pkgRoot) {
  final bareRoot = '$pkgRoot/../flutter_pear_bare';
  final mismatches = <PinMismatch>[];
  final skipped = <String>[];
  var checkedCount = 0;

  // --- BareKit version + sha256 pin, across every location that pins it ---
  final bareGradlePath = '$bareRoot/android/build.gradle';
  final bareGradle = _stripLineComments(_readOrThrow(bareGradlePath), '//');
  final gradleVersion = _extractOrThrow(
    bareGradle,
    RegExp(r'''bareKitVersion\s*=\s*["']([^"']+)["']'''),
    'bareKitVersion',
    bareGradlePath,
  );
  final gradleSha256 = _extractOrThrow(
    bareGradle,
    RegExp(r'''bareKitSha256\s*=\s*["']([^"']+)["']'''),
    'bareKitSha256',
    bareGradlePath,
  );
  checkedCount += 2;

  final pinSources = <({String label, String path, String? version, String? sha256})>[
    (label: 'Android Gradle', path: bareGradlePath, version: gradleVersion, sha256: gradleSha256),
  ];

  final barekitPinJsonPath = '$bareRoot/barekit-pin.json';
  final barekitPinJsonFile = File(barekitPinJsonPath);
  if (!barekitPinJsonFile.existsSync()) {
    skipped.add('barekit-pin.json ($barekitPinJsonPath) not landed yet '
        '(pack epic)');
  } else {
    final Map<String, dynamic> json;
    try {
      json = jsonDecode(barekitPinJsonFile.readAsStringSync())
          as Map<String, dynamic>;
    } catch (e) {
      throw PinCheckException('could not parse $barekitPinJsonPath as JSON: $e');
    }
    // Field names match repackBareKit's actual output (flutter_pear-ovt.2.3):
    // "bareKitVersion" + "upstreamSha256" -- the two-link checksum chain's
    // FIRST link, the same upstream prebuilds.zip version+checksum Android's
    // Gradle pin already records (repackedUrl/repackedSha256, the SECOND
    // link, describe the repacked asset itself, not upstream, so they don't
    // belong in this cross-pin consistency comparison).
    final version = json['bareKitVersion'] as String?;
    final sha256 = json['upstreamSha256'] as String?;
    if (version == null || sha256 == null) {
      throw PinCheckException('$barekitPinJsonPath must have string '
          '"bareKitVersion" and "upstreamSha256" keys');
    }
    pinSources.add((
      label: 'barekit-pin.json',
      path: barekitPinJsonPath,
      version: version,
      sha256: sha256,
    ));
  }

  final packageSwiftMatches = Directory(bareRoot)
      .existsSync()
      ? _findFiles(Directory(bareRoot), 'Package.swift')
      : const <File>[];
  if (packageSwiftMatches.isEmpty) {
    skipped.add('flutter_pear_bare/ios/**/Package.swift not landed yet '
        '(pack epic)');
  } else {
    for (final f in packageSwiftMatches) {
      final text = f.readAsStringSync();
      // generatePackageSwift (flutter_pear-ovt.2.4) writes a real,
      // generated Package.swift the moment barekit-pin.json + ios/addons/
      // exist -- but its BareKit url can itself still be the PENDING-UPLOAD
      // sentinel (flutter_pear-ovt.2.3) when the repacked asset hasn't
      // actually been published yet. That's a real, named, legitimate
      // intermediate repo state, not a malformed file -- skip it the same
      // way an entirely-absent Package.swift is skipped, rather than
      // throwing a generic parse error that reads like a bug.
      if (text.contains('PENDING-UPLOAD')) {
        skipped.add('${f.path} has a PENDING-UPLOAD BareKit url (repack '
            'not published yet, flutter_pear-ovt.2.3)');
        continue;
      }
      final urlMatch =
          RegExp(r'''url:\s*"[^"]*v(\d[\d.]*\d)/[^"]*"''').firstMatch(text);
      final checksumMatch =
          RegExp(r'''checksum:\s*"([0-9a-fA-F]+)"''').firstMatch(text);
      if (urlMatch == null || checksumMatch == null) {
        throw PinCheckException(
            'could not find both a versioned url: and a checksum: in ${f.path}');
      }
      pinSources.add((
        label: f.path,
        path: f.path,
        version: urlMatch.group(1),
        sha256: checksumMatch.group(1),
      ));
    }
  }

  final podspecMatches = Directory(bareRoot).existsSync()
      ? _findFiles(Directory(bareRoot), '.podspec')
      : const <File>[];
  if (podspecMatches.isEmpty) {
    skipped.add('flutter_pear_bare*.podspec not landed yet (podspec epic)');
  } else {
    for (final f in podspecMatches) {
      final text = f.readAsStringSync();
      final versionMatch =
          RegExp(r'''v(\d[\d.]*\d)/prebuilds\.zip''').firstMatch(text);
      final shaMatch =
          RegExp(r'''sha256[^0-9a-fA-F]*([0-9a-fA-F]{64})''').firstMatch(text);
      if (versionMatch == null || shaMatch == null) {
        throw PinCheckException(
            'could not find both a versioned prebuilds.zip URL and a sha256 '
            'in ${f.path}');
      }
      pinSources.add((
        label: f.path,
        path: f.path,
        version: versionMatch.group(1),
        sha256: shaMatch.group(1),
      ));
    }
  }

  for (var i = 1; i < pinSources.length; i++) {
    final a = pinSources[0];
    final b = pinSources[i];
    checkedCount += 2;
    if (a.version != b.version) {
      mismatches.add(PinMismatch(
        field: 'BareKit version',
        valueA: a.version!,
        sourceA: a.path,
        valueB: b.version!,
        sourceB: b.path,
      ));
    }
    if (a.sha256!.toLowerCase() != b.sha256!.toLowerCase()) {
      mismatches.add(PinMismatch(
        field: 'BareKit sha256',
        valueA: a.sha256!,
        sourceA: a.path,
        valueB: b.sha256!,
        sourceB: b.path,
      ));
    }
  }

  // --- Bundle asset name chain (Eng2 #9) ---
  final pubspecPath = '$pkgRoot/pubspec.yaml';
  final pubspec = _stripLineComments(_readOrThrow(pubspecPath), '#');
  final pubspecAsset = _extractOrThrow(
    pubspec,
    RegExp(r'''^\s*-\s*(assets/\S+\.bundle)\s*$''', multiLine: true),
    'a "- assets/*.bundle" entry',
    pubspecPath,
  );
  checkedCount++;
  if (pubspecAsset != bundleAssetPath) {
    mismatches.add(PinMismatch(
      field: 'Bundle asset name',
      valueA: pubspecAsset,
      sourceA: pubspecPath,
      valueB: bundleAssetPath,
      sourceB: 'bin/pack.dart bundleAssetPath',
    ));
  }

  final kotlinHostPath =
      '$bareRoot/android/src/main/kotlin/tech/loable/flutter_pear_bare/FlutterPearBarePlugin.kt';
  final kotlinHost = _readOrThrow(kotlinHostPath);
  final kotlinAsset = _extractOrThrow(
    kotlinHost,
    RegExp(r'''BUNDLE_ASSET_SUBPATH\s*=\s*"([^"]+)"'''),
    'BUNDLE_ASSET_SUBPATH',
    kotlinHostPath,
  );
  checkedCount++;
  if (kotlinAsset != bundleAssetPath) {
    mismatches.add(PinMismatch(
      field: 'Bundle asset name',
      valueA: kotlinAsset,
      sourceA: kotlinHostPath,
      valueB: bundleAssetPath,
      sourceB: 'bin/pack.dart bundleAssetPath',
    ));
  }

  // "Package.swift" is SPM's manifest filename, never the actual host
  // implementation -- excluded so a landed BareKitShim-style Package.swift
  // (checked separately above) doesn't get mistaken for "the Swift host has
  // landed" and silently suppress this leg's own SKIPPED-MISSING line.
  //
  // Matches a NAMED CONSTANT declaration (`bundleAssetSubpath = "..."`),
  // not a `lookupKey(forAsset: "...")` call site: the real host
  // (FlutterPearBarePlugin.swift, flutter_pear-ovt.3.1) factors the asset
  // path into a top-level `private let bundleAssetSubpath = ...` constant,
  // passed to lookupKey(forAsset:fromPackage:) by reference -- mirroring
  // the Kotlin host's own BUNDLE_ASSET_SUBPATH constant (checked the same
  // way just above), not the inline-literal style the since-removed T0
  // spike host used.
  final swiftHostMatches = Directory(bareRoot).existsSync()
      ? _findFiles(Directory(bareRoot), '.swift')
          .where((f) => f.uri.pathSegments.last != 'Package.swift')
      : const <File>[];
  final swiftHostsWithAsset = swiftHostMatches.where((f) => RegExp(
          r'''bundleAssetSubpath\s*=\s*"([^"]+)"''')
      .hasMatch(f.readAsStringSync()));
  if (swiftHostsWithAsset.isEmpty) {
    skipped.add('flutter_pear_bare/ios/**/*.swift host not landed yet '
        '(Swift host epic)');
  } else {
    for (final f in swiftHostsWithAsset) {
      final text = f.readAsStringSync();
      final m = RegExp(r'''bundleAssetSubpath\s*=\s*"([^"]+)"''').firstMatch(text);
      checkedCount++;
      if (m!.group(1) != bundleAssetPath) {
        mismatches.add(PinMismatch(
          field: 'Bundle asset name',
          valueA: m.group(1)!,
          sourceA: f.path,
          valueB: bundleAssetPath,
          sourceB: 'bin/pack.dart bundleAssetPath',
        ));
      }
    }
  }

  // --- Baked bundle version embedded in every committed bundle asset ---
  final bundleVersionPath = '$pkgRoot/lib/src/bundle_version.dart';
  final bundleVersionSource = _readOrThrow(bundleVersionPath);
  final bakedVersion = _extractOrThrow(
    bundleVersionSource,
    RegExp(r'''kPearEndBundleVersion\s*=\s*['"]([^'"]+)['"]'''),
    'kPearEndBundleVersion',
    bundleVersionPath,
  );
  final bundleFile = File('$pkgRoot/$bundleAssetPath');
  if (!bundleFile.existsSync()) {
    throw PinCheckException(
        'committed bundle asset not found: ${bundleFile.path}');
  }
  checkedCount++;
  final bundleBytes = bundleFile.readAsBytesSync();
  final needle = latin1.encode(bakedVersion);
  if (!_containsBytes(bundleBytes, needle)) {
    mismatches.add(PinMismatch(
      field: 'Baked bundle version',
      valueA: bakedVersion,
      sourceA: bundleVersionPath,
      valueB: 'not found in bundle bytes',
      sourceB: bundleFile.path,
    ));
  }

  return PinCheckResult(
      mismatches: mismatches, skipped: skipped, checkedCount: checkedCount);
}

bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

/// Recursively finds every file directly under [dir] whose name ends with
/// [suffix] (e.g. `"Package.swift"` or `".podspec"`), skipping generated/tool
/// directories the same way bin/check_compatibility.dart's own Gradle-file
/// walker does.
List<File> _findFiles(Directory dir, String suffix) {
  const skipDirNames = {'build', '.dart_tool', '.symlinks', 'Pods', '.git'};
  final result = <File>[];
  void walk(Directory d) {
    for (final entity in d.listSync()) {
      if (entity is Directory) {
        final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        if (skipDirNames.contains(name)) continue;
        walk(entity);
      } else if (entity is File && entity.path.endsWith(suffix)) {
        result.add(entity);
      }
    }
  }

  walk(dir);
  return result;
}

String _readOrThrow(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    throw PinCheckException('expected source file not found: $path');
  }
  return f.readAsStringSync();
}

String _extractOrThrow(
  String text,
  RegExp pattern,
  String what,
  String path,
) {
  final m = pattern.firstMatch(text);
  if (m == null) {
    throw PinCheckException('could not find $what in $path');
  }
  return m.group(1)!;
}

/// Strips end-of-line comments starting with [marker], but only outside a
/// quoted string literal — see bin/check_compatibility.dart's identically
/// named helper for the full rationale (kept as a private copy here rather
/// than a shared import so each CLI tool stays a single self-contained
/// file, matching this repo's existing bin/ convention).
String _stripLineComments(String text, String marker) {
  final out = StringBuffer();
  final lines = text.split('\n');
  for (var li = 0; li < lines.length; li++) {
    final line = lines[li];
    var cutAt = -1;
    String? quote;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (quote != null) {
        if (c == quote) quote = null;
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        continue;
      }
      if (line.startsWith(marker, i)) {
        cutAt = i;
        break;
      }
    }
    out.write(cutAt == -1 ? line : line.substring(0, cutAt));
    if (li != lines.length - 1) out.write('\n');
  }
  return out.toString();
}
