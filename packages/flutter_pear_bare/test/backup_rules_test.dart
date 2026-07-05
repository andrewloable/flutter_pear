import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

// E5.9 -- keeps the Android backup-exclusion rules honest against
// pear-end/index.js's ACTUAL Corestore/bulk-storage directory names, the
// same "don't let a doc/config silently drift from the real value"
// discipline flutter_pear/test/schema_test.dart already applies to the
// Dart<->JS schema mirror. `flutter test` runs with the package root
// (packages/flutter_pear_bare/) as the working directory -- reaching into
// the sibling flutter_pear package is safe here specifically BECAUSE this
// only ever runs at dev/test time inside this monorepo, the same reason
// bin/pack.dart's own maintainer-only cross-package paths are safe
// (flutter_pear-k2y: the same kind of monorepo-relative path was NOT safe
// when it ran inside flutter_pear_bare's Gradle build at a real
// consumer's build time -- see that fix's history for why).
//
// Checks structure, not just substrings: each directory name must be an
// `<exclude>` element's `path` attribute (not just present anywhere in the
// file text -- an accidental `<include>` flip or a stale mention surviving
// only in a comment would slip past a plain `.contains(...)` check).
// package:xml's own parser is lenient about a stray "--" inside a comment
// (real parsers -- libxml2, Android's manifest merger, AAPT2 -- are not,
// and reject it outright), so that specific well-formedness rule is
// checked directly against the raw text below, independent of the parser.

const _androidNs = 'http://schemas.android.com/apk/res/android';

/// The `path` attributes of every direct `<exclude domain="file" .../>`
/// child of [scope].
Set<String> _excludedFilePaths(XmlElement scope) => scope.childElements
    .where(
        (e) => e.name.local == 'exclude' && e.getAttribute('domain') == 'file')
    .map((e) => e.getAttribute('path'))
    .whereType<String>()
    .toSet();

/// XML 1.0 forbids "--" anywhere inside a comment body (only the closing
/// "-->" may contain it). Checked here because package:xml's parser
/// doesn't enforce this, but a real Android build (manifest merger/AAPT2)
/// does -- this is what actually broke when an em dash got typed as two
/// ASCII hyphens in an E5.9 comment.
void _expectNoDoubleHyphenInComments(String path, String content) {
  for (final match
      in RegExp(r'<!--(.*?)-->', dotAll: true).allMatches(content)) {
    expect(
      match.group(1)!.contains('--'),
      isFalse,
      reason: '$path has "--" inside an XML comment, which is illegal '
          'per XML 1.0 and breaks a real Android build even though '
          "package:xml's own parser accepts it leniently -- offending "
          'comment: <!--${match.group(1)}-->',
    );
  }
}

void main() {
  test(
      'the Android backup-exclusion rules exclude exactly the storage '
      'directory names pear-end/index.js actually uses (E5.9)', () {
    final indexJs =
        File('${Directory.current.path}/../flutter_pear/pear-end/index.js')
            .readAsStringSync();

    // The two directory names index.js actually derives from Bare.argv[0]
    // (the app's private files dir) -- see its own BULK_STORAGE_DIR/
    // Corestore comments. Extracted from source, not hardcoded twice, so a
    // rename there is exactly what this test is meant to catch.
    final corestoreMatch =
        RegExp(r"new Corestore\(path\.join\(Bare\.argv\[0\], '([^']+)'\)\)")
            .firstMatch(indexJs);
    expect(corestoreMatch, isNotNull,
        reason: "couldn't find `new Corestore(path.join(Bare.argv[0], '...'))` "
            'in pear-end/index.js -- this test needs updating to match '
            'wherever that moved to');
    final corestoreDir = corestoreMatch!.group(1)!;

    final bulkMatch =
        RegExp(r"BULK_STORAGE_DIR = path\.join\(Bare\.argv\[0\], '([^']+)'\)")
            .firstMatch(indexJs);
    expect(bulkMatch, isNotNull,
        reason: "couldn't find BULK_STORAGE_DIR's definition in "
            'pear-end/index.js -- this test needs updating to match '
            'wherever that moved to');
    final bulkDir = bulkMatch!.group(1)!;

    final dataExtractionRulesPath =
        '${Directory.current.path}/android/src/main/res/xml/flutter_pear_data_extraction_rules.xml';
    final fullBackupContentPath =
        '${Directory.current.path}/android/src/main/res/xml/flutter_pear_full_backup_content.xml';
    final manifestPath =
        '${Directory.current.path}/android/src/main/AndroidManifest.xml';

    final dataExtractionRulesText =
        File(dataExtractionRulesPath).readAsStringSync();
    final fullBackupContentText =
        File(fullBackupContentPath).readAsStringSync();
    final manifestText = File(manifestPath).readAsStringSync();

    _expectNoDoubleHyphenInComments(
        dataExtractionRulesPath, dataExtractionRulesText);
    _expectNoDoubleHyphenInComments(
        fullBackupContentPath, fullBackupContentText);
    _expectNoDoubleHyphenInComments(manifestPath, manifestText);

    final dataExtractionRules = XmlDocument.parse(dataExtractionRulesText);
    final fullBackupContent = XmlDocument.parse(fullBackupContentText);
    final manifest = XmlDocument.parse(manifestText);

    for (final section in ['cloud-backup', 'device-transfer']) {
      final excluded = _excludedFilePaths(dataExtractionRules
          .rootElement.childElements
          .firstWhere((e) => e.name.local == section));
      for (final dir in [corestoreDir, bulkDir]) {
        expect(
          excluded.contains(dir),
          isTrue,
          reason: 'flutter_pear_data_extraction_rules.xml\'s <$section> '
              'must <exclude domain="file" path="$dir"/> (the actual '
              'directory name index.js uses)',
        );
      }
    }

    final fullBackupExcluded =
        _excludedFilePaths(fullBackupContent.rootElement);
    for (final dir in [corestoreDir, bulkDir]) {
      expect(
        fullBackupExcluded.contains(dir),
        isTrue,
        reason: 'flutter_pear_full_backup_content.xml must <exclude '
            'domain="file" path="$dir"/> (the actual directory name '
            'index.js uses)',
      );
    }

    final application = manifest.rootElement.childElements
        .firstWhere((e) => e.name.local == 'application');
    expect(
      application.getAttribute('dataExtractionRules', namespace: _androidNs),
      '@xml/flutter_pear_data_extraction_rules',
      reason: 'AndroidManifest.xml\'s <application> must reference the data '
          'extraction rules file for it to actually take effect',
    );
    expect(
      application.getAttribute('fullBackupContent', namespace: _androidNs),
      '@xml/flutter_pear_full_backup_content',
      reason: 'AndroidManifest.xml\'s <application> must reference the full '
          'backup content file for it to actually take effect on devices/ '
          'apps that don\'t qualify for dataExtractionRules',
    );
  });
}
