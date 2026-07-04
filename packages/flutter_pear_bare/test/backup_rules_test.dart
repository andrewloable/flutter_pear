import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

// E5.9 -- keeps the Android backup-exclusion rules honest against
// pear-end/index.js's ACTUAL Corestore/bulk-storage directory names, the
// same "don't let a doc/config silently drift from the real value"
// discipline flutter_pear/test/schema_test.dart already applies to the
// Dart<->JS schema mirror. `flutter test` runs with the package root
// (packages/flutter_pear_bare/) as the working directory -- reaching into
// the sibling flutter_pear package mirrors the SAME cross-package sibling
// path convention flutter_pear_bare/android/build.gradle's own
// linkNativeAddons task already uses (see its own comment on why that
// only holds for this melos monorepo's exact directory depth).
//
// Parses each file with package:xml rather than substring-matching the raw
// text: XmlDocument.parse throws on malformed XML (catches a broken
// comment breaking the real Android build, which a plain `.contains(...)`
// check can't), and checking each directory name is an `<exclude>`
// element's `path` attribute (not just present anywhere in the file text)
// catches an accidental `<include>` flip or a stale mention surviving only
// in a comment.

const _androidNs = 'http://schemas.android.com/apk/res/android';

/// The `path` attributes of every direct `<exclude domain="file" .../>`
/// child of [scope].
Set<String> _excludedFilePaths(XmlElement scope) => scope.childElements
    .where((e) => e.name.local == 'exclude' && e.getAttribute('domain') == 'file')
    .map((e) => e.getAttribute('path'))
    .whereType<String>()
    .toSet();

void main() {
  test(
      'the Android backup-exclusion rules exclude exactly the storage '
      'directory names pear-end/index.js actually uses (E5.9)', () {
    final indexJs = File(
            '${Directory.current.path}/../flutter_pear/pear-end/index.js')
        .readAsStringSync();

    // The two directory names index.js actually derives from Bare.argv[0]
    // (the app's private files dir) -- see its own BULK_STORAGE_DIR/
    // Corestore comments. Extracted from source, not hardcoded twice, so a
    // rename there is exactly what this test is meant to catch.
    final corestoreMatch = RegExp(
            r"new Corestore\(path\.join\(Bare\.argv\[0\], '([^']+)'\)\)")
        .firstMatch(indexJs);
    expect(corestoreMatch, isNotNull,
        reason:
            "couldn't find `new Corestore(path.join(Bare.argv[0], '...'))` "
            'in pear-end/index.js -- this test needs updating to match '
            'wherever that moved to');
    final corestoreDir = corestoreMatch!.group(1)!;

    final bulkMatch = RegExp(
            r"BULK_STORAGE_DIR = path\.join\(Bare\.argv\[0\], '([^']+)'\)")
        .firstMatch(indexJs);
    expect(bulkMatch, isNotNull,
        reason: "couldn't find BULK_STORAGE_DIR's definition in "
            'pear-end/index.js -- this test needs updating to match '
            'wherever that moved to');
    final bulkDir = bulkMatch!.group(1)!;

    final dataExtractionRules = XmlDocument.parse(File(
            '${Directory.current.path}/android/src/main/res/xml/flutter_pear_data_extraction_rules.xml')
        .readAsStringSync());
    final fullBackupContent = XmlDocument.parse(File(
            '${Directory.current.path}/android/src/main/res/xml/flutter_pear_full_backup_content.xml')
        .readAsStringSync());
    final manifest = XmlDocument.parse(File(
            '${Directory.current.path}/android/src/main/AndroidManifest.xml')
        .readAsStringSync());

    for (final section in ['cloud-backup', 'device-transfer']) {
      final excluded = _excludedFilePaths(dataExtractionRules.rootElement
          .childElements
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
