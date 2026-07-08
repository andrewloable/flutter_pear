// `dart run flutter_pear:check_compatibility` — E9.5's CI gate: diffs
// COMPATIBILITY.md's version + toolchain tables against each value's real
// source of truth (build.gradle, pubspec.yaml, package.json, the example
// app's gradle-wrapper.properties, root CLAUDE.md) and fails loud, naming
// every disagreement, rather than letting the doc quietly drift from what's
// actually pinned.
//
// ponytail: plain regex/line-based extraction (matching bin/pack.dart's own
// `_addBareKitStaticEntry` style), not a full Gradle/YAML parser — this repo
// controls every source file's format, so a targeted regex per field is
// enough and stays legible. Same reasoning for the markdown table parser
// below: it only needs to understand the exact pipe-table shape this repo
// writes, not arbitrary Markdown.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  // `dart run` executes a cached kernel snapshot, so Platform.script doesn't
  // point at this file on disk (see bin/pack.dart's own note on the same
  // issue). Run from the package root: `cd packages/flutter_pear && dart run
  // flutter_pear:check_compatibility` (or `dart run
  // bin/check_compatibility.dart` equivalently).
  final pkgRoot = Directory.current.path;
  try {
    final mismatches = checkCompatibility(pkgRoot);
    if (mismatches.isEmpty) {
      stdout.writeln(
          'COMPATIBILITY.md agrees with every checked pin ($_lastCheckedCount fields checked, 0 mismatches).');
      return;
    }
    stderr.writeln('COMPATIBILITY.md is out of sync with '
        '${mismatches.length} real pin(s):\n');
    for (final m in mismatches) {
      stderr.writeln('  - ${m.describe()}');
    }
    stderr
        .writeln('\nFix: update whichever side is stale (the real pin, or the '
            'COMPATIBILITY.md cell) so they agree again — see '
            'COMPATIBILITY.md\'s own "Bump procedure" section.');
    exit(1);
  } on CompatibilityCheckException catch (e) {
    stderr.writeln('check_compatibility failed: $e');
    exit(1);
  }
}

// Set by [checkCompatibility] right before returning, purely so main()'s
// success message can report how many fields were verified without
// checkCompatibility needing a separate return channel just for a count.
int _lastCheckedCount = 0;

/// Swift tools version (from `Package.swift`'s `// swift-tools-version:X.Y`
/// header) → the first Xcode release that supports it, per Apple/Swift's own
/// published release notes -- this repo has no other machine-checkable Xcode
/// pin, so the "Xcode" column is derived transitively through this table
/// instead of being independently asserted. Deliberately only covers the
/// version(s) this repo actually declares; a future swift-tools-version bump
/// to an unmapped value fails loudly (see its use in [checkCompatibility])
/// rather than silently reporting a wrong or stale minimum.
const _minXcodeForSwiftToolsVersion = {
  '5.9': '15.0',
};

/// One disagreement between a `COMPATIBILITY.md` table cell and the real
/// pinned value it's supposed to describe.
class CompatibilityMismatch {
  CompatibilityMismatch({
    required this.field,
    required this.tableValue,
    required this.actualValue,
    required this.actualSource,
  });

  /// Human-readable name of the checked field, e.g. `"Bare Kit"` or
  /// `"autobase"`.
  final String field;

  /// The value found in `COMPATIBILITY.md`'s table cell.
  final String tableValue;

  /// The real value extracted from [actualSource].
  final String actualValue;

  /// Where [actualValue] came from (a file path, e.g.
  /// `packages/flutter_pear_bare/android/build.gradle`), for the mismatch
  /// message.
  final String actualSource;

  /// A single-line, greppable description naming the field and both
  /// disagreeing values plus where the real one lives.
  String describe() => '$field: COMPATIBILITY.md says "$tableValue", but '
      '$actualSource says "$actualValue"';
}

/// Thrown when the check itself cannot run to completion — a required file
/// is missing, or a table/column/row this tool expects to find in
/// `COMPATIBILITY.md` isn't there. Distinct from a normal value mismatch
/// (reported via [CompatibilityMismatch] instead): this means the contract
/// itself is malformed, not just out of sync.
class CompatibilityCheckException implements Exception {
  CompatibilityCheckException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Diffs `COMPATIBILITY.md` (found at `$pkgRoot/../../COMPATIBILITY.md`)
/// against every real pin it documents, for the row matching the current
/// `flutter_pear` plugin version (read from `$pkgRoot/pubspec.yaml`).
///
/// Returns the (possibly empty) list of disagreements found — empty means
/// the table and every real pin agree. Throws [CompatibilityCheckException]
/// for a structural problem (a source file missing, or a table/row/column
/// this tool expects not found) rather than folding that into the mismatch
/// list, since there's nothing to "diff" in that case.
///
/// [pkgRoot] is expected to be `packages/flutter_pear` inside a real (or
/// fixture) checkout of this monorepo — sibling packages
/// (`flutter_pear_bare`, `flutter_pear_example`) and the repo root are
/// located relative to it, the same sibling-relative-path pattern
/// `bin/pack.dart` already uses for maintainer/CI-time tooling.
List<CompatibilityMismatch> checkCompatibility(String pkgRoot) {
  final repoRoot = Directory('$pkgRoot/../..').absolute.path;
  final bareRoot = '$pkgRoot/../flutter_pear_bare';
  final exampleRoot = '$pkgRoot/../flutter_pear_example';

  final compatMdPath = '$repoRoot/COMPATIBILITY.md';
  final compatMd = _readOrThrow(compatMdPath);

  final pkgPubspecPath = '$pkgRoot/pubspec.yaml';
  final pkgPubspec = _stripLineComments(_readOrThrow(pkgPubspecPath), '#');
  final version = _extractOrThrow(
    pkgPubspec,
    RegExp(r'^version:\s*(\S+)', multiLine: true),
    '"version:"',
    pkgPubspecPath,
  );

  final bareGradlePath = '$bareRoot/android/build.gradle';
  // Comment-stripped: every regex below runs against this, not the raw
  // file, so a decoy value inside a `//` comment can't shadow the real pin.
  final bareGradle = _stripLineComments(_readOrThrow(bareGradlePath), '//');

  final barePubspecPath = '$bareRoot/pubspec.yaml';
  final barePubspec = _stripLineComments(_readOrThrow(barePubspecPath), '#');

  final pearEndPkgJsonPath = '$pkgRoot/pear-end/package.json';
  final pearEndPkgJson = _readOrThrow(pearEndPkgJsonPath);
  final Map<String, dynamic> pearEndJson;
  try {
    pearEndJson = jsonDecode(pearEndPkgJson) as Map<String, dynamic>;
  } catch (e) {
    throw CompatibilityCheckException(
        'could not parse $pearEndPkgJsonPath as JSON: $e');
  }
  final hyperDeps =
      (pearEndJson['dependencies'] as Map?)?.cast<String, dynamic>();
  if (hyperDeps == null) {
    throw CompatibilityCheckException(
        '$pearEndPkgJsonPath has no top-level "dependencies" object');
  }

  final gradleWrapperPath =
      '$exampleRoot/android/gradle/wrapper/gradle-wrapper.properties';
  // Java-properties comments start with "#" -- stripped for the same reason
  // as the YAML/Gradle sources above.
  final gradleWrapper =
      _stripLineComments(_readOrThrow(gradleWrapperPath), '#');

  final claudeMdPath = '$repoRoot/CLAUDE.md';
  final claudeMd = _readOrThrow(claudeMdPath);

  final mismatches = <CompatibilityMismatch>[];
  var checkedCount = 0;
  void check(
    String field,
    String tableValue,
    String actualValue,
    String actualSource,
  ) {
    checkedCount++;
    if (tableValue.trim() != actualValue.trim()) {
      mismatches.add(CompatibilityMismatch(
        field: field,
        tableValue: tableValue.trim(),
        actualValue: actualValue.trim(),
        actualSource: actualSource,
      ));
    }
  }

  // --- Table 1: plugin <-> Bare Kit <-> Hyper* module versions ---
  const hyperTableName = 'Plugin ↔ Bare Kit ↔ Hyper* module versions';
  // Note: this row is found BY matching its "flutter_pear version" cell
  // against `version` already, so re-`check()`-ing that same cell against
  // `version` afterwards would be tautological (it can never disagree) —
  // deliberately not done here for that reason.
  final hyperRow = _findRow(
    compatMd,
    headerContains: 'flutter_pear version | Bare Kit',
    tableName: hyperTableName,
    versionColumn: 'flutter_pear version',
    version: version,
    docPath: compatMdPath,
  );
  check(
    'Bare Kit',
    hyperRow.get('Bare Kit', hyperTableName, compatMdPath),
    _extractOrThrow(
      bareGradle,
      RegExp(r'''bareKitVersion\s*=\s*["']([^"']+)["']'''),
      'bareKitVersion',
      bareGradlePath,
    ),
    bareGradlePath,
  );
  // package.json keys match the table's column names exactly (both are the
  // real npm package names) — one loop covers all 15 Hyper* dependencies.
  const hyperPackages = [
    'autobase',
    'bare-fs',
    'bare-path',
    'blind-pairing',
    'blind-pairing-core',
    'compact-encoding',
    'corestore',
    'hyperbee',
    'hypercore-crypto',
    'hyperdrive',
    'hyperswarm',
    'localdrive',
    'mirror-drive',
    'protomux',
    'streamx',
  ];
  for (final pkg in hyperPackages) {
    final actual = hyperDeps[pkg];
    if (actual == null) {
      throw CompatibilityCheckException(
          '$pearEndPkgJsonPath has no "$pkg" dependency — either it was '
          'dropped (remove its column from COMPATIBILITY.md too) or renamed');
    }
    check(
      pkg,
      hyperRow.get(pkg, hyperTableName, compatMdPath),
      actual.toString(),
      pearEndPkgJsonPath,
    );
  }

  // --- Table 2: toolchain ---
  const toolchainTableName = 'Toolchain';
  // Same reasoning as the Hyper* table above: no tautological re-check of
  // the version cell that located this row.
  final toolchainRow = _findRow(
    compatMd,
    headerContains: 'flutter_pear version | Flutter SDK',
    tableName: toolchainTableName,
    versionColumn: 'flutter_pear version',
    version: version,
    docPath: compatMdPath,
  );

  final tableFlutterSdk =
      toolchainRow.get('Flutter SDK', toolchainTableName, compatMdPath);
  check(
    'Flutter SDK (flutter_pear/pubspec.yaml)',
    tableFlutterSdk,
    _pubspecSectionValue(pkgPubspec, 'environment', 'flutter', pkgPubspecPath),
    pkgPubspecPath,
  );
  check(
    'Flutter SDK (flutter_pear_bare/pubspec.yaml)',
    tableFlutterSdk,
    _pubspecSectionValue(
        barePubspec, 'environment', 'flutter', barePubspecPath),
    barePubspecPath,
  );

  final tableDartSdk =
      toolchainRow.get('Dart SDK', toolchainTableName, compatMdPath);
  check(
    'Dart SDK (flutter_pear/pubspec.yaml)',
    tableDartSdk,
    _pubspecSectionValue(pkgPubspec, 'environment', 'sdk', pkgPubspecPath),
    pkgPubspecPath,
  );
  check(
    'Dart SDK (flutter_pear_bare/pubspec.yaml)',
    tableDartSdk,
    _pubspecSectionValue(barePubspec, 'environment', 'sdk', barePubspecPath),
    barePubspecPath,
  );

  final workspacePubspecPath = '$repoRoot/pubspec.yaml';
  final workspacePubspec =
      _stripLineComments(_readOrThrow(workspacePubspecPath), '#');
  check(
    'Melos',
    toolchainRow.get('Melos', toolchainTableName, compatMdPath),
    _pubspecSectionValue(
        workspacePubspec, 'dev_dependencies', 'melos', workspacePubspecPath),
    workspacePubspecPath,
  );

  check(
    'Android Gradle Plugin (flutter_pear_bare)',
    toolchainRow.get('Android Gradle Plugin (flutter_pear_bare)',
        toolchainTableName, compatMdPath),
    _extractOrThrow(
      bareGradle,
      RegExp(r'''com\.android\.tools\.build:gradle:([^"']+)'''),
      'the com.android.tools.build:gradle classpath version',
      bareGradlePath,
    ),
    bareGradlePath,
  );
  check(
    'Kotlin (flutter_pear_bare)',
    toolchainRow.get(
        'Kotlin (flutter_pear_bare)', toolchainTableName, compatMdPath),
    _extractOrThrow(
      bareGradle,
      RegExp(r'''kotlin_version\s*=\s*["']([^"']+)["']'''),
      'kotlin_version',
      bareGradlePath,
    ),
    bareGradlePath,
  );
  check(
    'Gradle (example app dev/CI wrapper)',
    toolchainRow.get('Gradle (example app dev/CI wrapper)', toolchainTableName,
        compatMdPath),
    _extractOrThrow(
      gradleWrapper,
      RegExp(r'gradle-([0-9][0-9.]*)-'),
      'the Gradle version in distributionUrl',
      gradleWrapperPath,
    ),
    gradleWrapperPath,
  );
  check(
    'Android compileSdk',
    toolchainRow.get('Android compileSdk', toolchainTableName, compatMdPath),
    _extractOrThrow(
      bareGradle,
      RegExp(r'compileSdk\s*=\s*(\d+)'),
      'compileSdk',
      bareGradlePath,
    ),
    bareGradlePath,
  );
  check(
    'Android minSdk',
    toolchainRow.get('Android minSdk', toolchainTableName, compatMdPath),
    _extractOrThrow(
      bareGradle,
      RegExp(r'minSdk\s*=\s*(\d+)'),
      'minSdk',
      bareGradlePath,
    ),
    bareGradlePath,
  );

  final ndkMismatch = _checkNdk(
    repoRoot,
    toolchainRow.get('Android NDK', toolchainTableName, compatMdPath),
  );
  checkedCount++;
  if (ndkMismatch != null) mismatches.add(ndkMismatch);

  final abisMatch =
      RegExp(r'''bareKitAbis\s*=\s*\[([^\]]*)\]''').firstMatch(bareGradle);
  if (abisMatch == null) {
    throw CompatibilityCheckException(
        'could not find bareKitAbis in $bareGradlePath');
  }
  final actualAbis = RegExp(r'''["']([^"']+)["']''')
      .allMatches(abisMatch.group(1)!)
      .map((m) => m.group(1)!)
      .toSet();
  final tableAbis = toolchainRow
      .get('Supported ABIs', toolchainTableName, compatMdPath)
      .split(',')
      .map((s) => s.trim())
      .toSet();
  checkedCount++;
  // `Set`'s `==` is reference identity, not content equality (no override
  // in core Dart) — compare by size + mutual containment instead of `!=`,
  // which would otherwise report a mismatch on every single run.
  final abisEqual = tableAbis.length == actualAbis.length &&
      tableAbis.containsAll(actualAbis);
  if (!abisEqual) {
    mismatches.add(CompatibilityMismatch(
      field: 'Supported ABIs',
      tableValue: (tableAbis.toList()..sort()).join(', '),
      actualValue: (actualAbis.toList()..sort()).join(', '),
      actualSource: bareGradlePath,
    ));
  }

  check(
    'JDK',
    toolchainRow.get('JDK', toolchainTableName, compatMdPath),
    _extractOrThrow(
      claudeMd,
      RegExp(r'JDK (\d+)'),
      'a "JDK <number>" mention in the Toolchain table',
      claudeMdPath,
    ),
    '$claudeMdPath Toolchain table',
  );

  final packageSwiftPath = '$bareRoot/ios/flutter_pear_bare/Package.swift';
  final packageSwift = _readOrThrow(packageSwiftPath);
  check(
    'iOS deployment target (Package.swift)',
    toolchainRow.get('iOS deployment target', toolchainTableName, compatMdPath),
    _extractOrThrow(
      packageSwift,
      RegExp(r'''\.iOS\(\.v(\d+)\)'''),
      'a platforms: [.iOS(.vNN)] entry',
      packageSwiftPath,
    ),
    packageSwiftPath,
  );

  // The podspec's own s.platform declaration is a decimal version string
  // ('13.0'), unlike Package.swift's bare integer (.v13) -- only the
  // leading integer is compared against the same table cell (flutter_pear-
  // ovt.3.6's own DO step 3: "keep the two values identical").
  final podspecPath = '$bareRoot/ios/flutter_pear_bare.podspec';
  final podspec = _readOrThrow(podspecPath);
  check(
    'iOS deployment target (podspec)',
    toolchainRow.get('iOS deployment target', toolchainTableName, compatMdPath),
    _extractOrThrow(
      podspec,
      RegExp("platform\\s*=\\s*:ios,\\s*'(\\d+)(?:\\.\\d+)?'"),
      "an s.platform = :ios, '<version>' entry",
      podspecPath,
    ),
    podspecPath,
  );

  final swiftToolsVersion = _extractOrThrow(
    packageSwift,
    RegExp(r'''swift-tools-version:\s*(\d+\.\d+)'''),
    'a "// swift-tools-version:X.Y" header',
    packageSwiftPath,
  );
  final minXcode = _minXcodeForSwiftToolsVersion[swiftToolsVersion];
  if (minXcode == null) {
    throw CompatibilityCheckException(
        '$packageSwiftPath declares swift-tools-version:$swiftToolsVersion, '
        'which has no known minimum-Xcode mapping in '
        '_minXcodeForSwiftToolsVersion (bin/check_compatibility.dart) -- add '
        'one (the first Xcode release supporting that Swift tools version, '
        'per Apple/Swift release notes) before this can be checked.');
  }
  check(
    'Xcode',
    toolchainRow.get('Xcode', toolchainTableName, compatMdPath),
    '>=$minXcode',
    '$packageSwiftPath (swift-tools-version:$swiftToolsVersion)',
  );

  _lastCheckedCount = checkedCount;
  return mismatches;
}

/// Runs [checkCompatibility] and throws [CompatibilityMismatchException] if
/// it finds any disagreement — the assertion form used by tests and by a
/// CI script that just wants a single throw/no-throw signal.
void assertCompatibilityMatches(String pkgRoot) {
  final mismatches = checkCompatibility(pkgRoot);
  if (mismatches.isNotEmpty) {
    throw CompatibilityMismatchException(mismatches);
  }
}

/// Thrown by [assertCompatibilityMatches] when [checkCompatibility] found
/// one or more real disagreements between `COMPATIBILITY.md` and the pins
/// it documents.
class CompatibilityMismatchException implements Exception {
  CompatibilityMismatchException(this.mismatches);
  final List<CompatibilityMismatch> mismatches;
  @override
  String toString() => mismatches.map((m) => m.describe()).join('\n');
}

/// Verifies the repo's "Android NDK" claim in [tableValue] (expected to be
/// exactly `"not pinned"` today, per COMPATIBILITY.md) against a scan of
/// every `packages/*/android/**/build.gradle{,.kts}` file for a literal
/// `ndkVersion` assignment. `ndkVersion = flutter.ndkVersion` (delegating to
/// the installed Flutter SDK's own default) is the one sanctioned form and
/// does not count as a pin; any other right-hand side does. Returns null
/// when the table's claim still holds, or a [CompatibilityMismatch] naming
/// every offending file otherwise.
CompatibilityMismatch? _checkNdk(String repoRoot, String tableValue) {
  final packagesDir = Directory('$repoRoot/packages');
  if (!packagesDir.existsSync()) {
    throw CompatibilityCheckException(
        'expected directory not found: ${packagesDir.path}');
  }
  final offenders = <String>[];
  for (final pkgDir in packagesDir.listSync().whereType<Directory>()) {
    final androidDir = Directory('${pkgDir.path}/android');
    if (!androidDir.existsSync()) continue;
    for (final entity in _findGradleFiles(androidDir)) {
      final name = entity.uri.pathSegments.last;
      if (name != 'build.gradle' && name != 'build.gradle.kts') continue;
      // Comment-stripped so an inert `// ndkVersion = "..."` mention doesn't
      // read as a real pin (see flutter_pear E9.5 review).
      final text = _stripLineComments(entity.readAsStringSync(), '//');
      for (final m in RegExp(r'ndkVersion\s*=\s*(.+)').allMatches(text)) {
        final rhs = m.group(1)!.trim();
        if (rhs.isEmpty) continue;
        if (rhs != 'flutter.ndkVersion') {
          offenders.add('${entity.path}: ndkVersion = $rhs');
        }
      }
    }
  }
  final actual = offenders.isEmpty ? 'not pinned' : offenders.join('; ');
  if (tableValue.trim() == actual) return null;
  return CompatibilityMismatch(
    field: 'Android NDK',
    tableValue: tableValue.trim(),
    actualValue: actual,
    actualSource: offenders.isEmpty
        ? '(scan of every packages/*/android/**/build.gradle{,.kts})'
        : offenders.first.split(':').first,
  );
}

/// Strips end-of-line comments starting with [marker] (`"//"` for
/// Groovy/Kotlin-DSL Gradle files, `"#"` for YAML/Java-properties files)
/// from every line of [text], but only when [marker] appears outside a
/// quoted string literal — naively cutting at the first occurrence on every
/// line would corrupt real content like a `"https://..."` URL elsewhere in
/// the same file. Every single-line regex extraction below runs against
/// comment-stripped text so a decoy value inside a comment can't shadow the
/// real pin (see flutter_pear E9.5 review: the Melos check originally
/// matched a "melos:" mention inside a comment instead of the real
/// `dev_dependencies` pin).
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

/// Directory names Gradle/AGP itself generates under an `android/` tree —
/// build output, caches, IDE state. Always gitignored, never source
/// content, and machine/build-history dependent, so [_findGradleFiles] never
/// descends into them: a leftover `build.gradle`-named file inside one of
/// these (e.g. an exploded-AAR transform under `build/`) is not a real,
/// source-controlled pin and must not be able to trigger a compatibility
/// mismatch (see flutter_pear E9.5 review).
const _gradleGeneratedDirNames = {
  'build',
  '.gradle',
  '.kotlin',
  '.cxx',
  '.idea',
};

/// Recursively finds every regular file under [dir], skipping any
/// subdirectory named like a Gradle/AGP-generated build-output or cache dir
/// (see [_gradleGeneratedDirNames]) — unlike `Directory.listSync(recursive:
/// true)`, which walks everything and leaves filtering to the caller after
/// the fact, this never even opens those subtrees.
Iterable<File> _findGradleFiles(Directory dir) {
  final result = <File>[];
  void walk(Directory d) {
    for (final entity in d.listSync()) {
      if (entity is Directory) {
        final name = entity.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        if (_gradleGeneratedDirNames.contains(name)) continue;
        walk(entity);
      } else if (entity is File) {
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
    throw CompatibilityCheckException('expected source file not found: $path');
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
    throw CompatibilityCheckException('could not find $what in $path');
  }
  return m.group(1)!;
}

/// Extracts `key: 'value'` (or `"value"`, or a bare unquoted value like
/// `^6.3.2`) from within a pubspec.yaml's top-level [section] block
/// specifically (e.g. `environment:` or `dev_dependencies:`) — a bare
/// whole-file regex for e.g. `flutter:` would also match the unrelated
/// `flutter:` plugin/assets section every Flutter package pubspec has, and
/// one for `melos:` would match any earlier mention of that word anywhere
/// in the file, comment or not (see flutter_pear E9.5 review). [pubspecText]
/// is expected to already have `#` comments stripped (see
/// [_stripLineComments]) so a decoy line above the section can't be
/// mistaken for real content inside it — though scoping to the section
/// block already excludes anything before its header regardless.
String _pubspecSectionValue(
  String pubspecText,
  String section,
  String key,
  String path,
) {
  final sectionMatch =
      RegExp('^$section:\\s*\\n((?:[ \\t]+\\S.*\\n?)*)', multiLine: true)
          .firstMatch(pubspecText);
  if (sectionMatch == null) {
    throw CompatibilityCheckException(
        'could not find a "$section:" block in $path');
  }
  final block = sectionMatch.group(1)!;
  final kv =
      RegExp('^[ \\t]*$key:\\s*(?:[\'"]([^\'"]+)[\'"]|(\\S+))', multiLine: true)
          .firstMatch(block);
  if (kv == null) {
    throw CompatibilityCheckException(
        'could not find "$key:" inside the $section: block of $path');
  }
  return (kv.group(1) ?? kv.group(2))!;
}

/// One parsed data row of a markdown pipe-table, as a column-name → cell
/// map.
class _ParsedRow {
  _ParsedRow(this.cells);
  final Map<String, String> cells;

  /// Returns the trimmed cell for [column], throwing
  /// [CompatibilityCheckException] naming [docPath] and [tableName] if the
  /// table this row came from has no such column at all (a missing VALUE
  /// for an existing column would instead show up as an empty-string
  /// mismatch via [checkCompatibility]'s normal diff, which is the more
  /// useful signal there).
  String get(String column, String tableName, String docPath) {
    final v = cells[column];
    if (v == null) {
      throw CompatibilityCheckException(
          '$docPath\'s "$tableName" table has no "$column" column');
    }
    return v.trim();
  }
}

/// Finds the markdown pipe-table in [markdown] whose header row contains
/// [headerContains], then the data row within it whose [versionColumn] cell
/// equals [version] exactly.
///
/// Deliberately a plain line-scanner tied to this repo's own fixed table
/// shape (a header line, a `|---|...` separator line, then one or more
/// `|`-prefixed data lines) rather than a general Markdown parser — see this
/// file's header comment.
_ParsedRow _findRow(
  String markdown, {
  required String headerContains,
  required String tableName,
  required String versionColumn,
  required String version,
  required String docPath,
}) {
  final lines = markdown.split('\n');
  final headerIdx = lines.indexWhere((l) => l.contains(headerContains));
  if (headerIdx == -1) {
    throw CompatibilityCheckException(
        '$docPath: could not find the "$tableName" table (looked for a '
        'header row containing "$headerContains")');
  }
  final headers = _splitTableRow(lines[headerIdx]);
  // lines[headerIdx + 1] is expected to be the `|---|---|` separator row;
  // data rows start right after it.
  for (var i = headerIdx + 2; i < lines.length; i++) {
    final line = lines[i];
    if (!line.trimLeft().startsWith('|')) break;
    final cells = _splitTableRow(line);
    if (cells.length != headers.length) continue;
    final map = Map<String, String>.fromIterables(headers, cells);
    if (map[versionColumn]?.trim() == version) {
      return _ParsedRow(map);
    }
  }
  throw CompatibilityCheckException(
      '$docPath\'s "$tableName" table has no row where "$versionColumn" == '
      '"$version" — add one (STEP 1: "one row per released plugin version")');
}

List<String> _splitTableRow(String line) {
  var t = line.trim();
  if (t.startsWith('|')) t = t.substring(1);
  if (t.endsWith('|')) t = t.substring(0, t.length - 1);
  return t.split('|').map((c) => c.trim()).toList();
}
