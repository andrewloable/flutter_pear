import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// flutter_pear-ovt.3.3 -- the iOS counterpart of backup_rules_test.dart's
// "don't let a doc/config silently drift from the real value" discipline.
// Pure file-content check (not a real filesystem/sim run -- that's this
// task's own AUTO-VALIDATION, run by hand against a booted simulator) so
// this runs anywhere, same as backup_rules_test.dart's own rationale for
// why it reads source text instead of actually invoking Gradle.

void main() {
  test(
      'the Swift host writes worklet storage under Application Support '
      'with pear-corestore/pear-bulk excluded from backup, never under '
      'Documents (Eng2 decision 35 -- an iCloud restore of Hypercore '
      'writer keys onto a second device forks cores)', () {
    final swiftHostPath =
        '${Directory.current.path}/ios/flutter_pear_bare/Sources/flutter_pear_bare/FlutterPearBarePlugin.swift';
    final swiftHost = File(swiftHostPath);
    expect(swiftHost.existsSync(), isTrue,
        reason: 'expected the Swift host at $swiftHostPath');
    final text = swiftHost.readAsStringSync();

    // Directory names must match pear-end/index.js's own Corestore/
    // BULK_STORAGE_DIR names exactly -- extracted from source there (same
    // as backup_rules_test.dart), not hardcoded twice here, so a rename in
    // index.js is exactly what this test is meant to catch. STORAGE_DIR
    // (flutter_pear-71g, E-D2a), not the literal Bare.argv[0] -- index.js
    // now resolves the storage-dir SOURCE per host (BareKit vs. desktop
    // bare subprocess) into that one local, then joins it the same way
    // either way.
    final indexJsPath =
        '${Directory.current.path}/../flutter_pear/pear-end/index.js';
    final indexJs = File(indexJsPath).readAsStringSync();
    final corestoreMatch =
        RegExp(r"new Corestore\(path\.join\(STORAGE_DIR, '([^']+)'\)\)")
            .firstMatch(indexJs);
    expect(corestoreMatch, isNotNull,
        reason: "couldn't find `new Corestore(path.join(STORAGE_DIR, '...'))` "
            'in pear-end/index.js -- this test needs updating to match '
            'wherever that moved to');
    final corestoreDir = corestoreMatch!.group(1)!;

    final bulkMatch =
        RegExp(r"BULK_STORAGE_DIR = path\.join\(STORAGE_DIR, '([^']+)'\)")
            .firstMatch(indexJs);
    expect(bulkMatch, isNotNull,
        reason: "couldn't find BULK_STORAGE_DIR's definition in "
            'pear-end/index.js -- this test needs updating to match '
            'wherever that moved to');
    final bulkDir = bulkMatch!.group(1)!;

    // Quoted, exact match -- "pear-corestore" is a substring of a mutated
    // "pear-corestorex", so a plain text.contains(corestoreDir) would still
    // pass against a broken rename; requiring the closing quote right after
    // the name catches that.
    expect(text.contains('"$corestoreDir"'), isTrue,
        reason: 'FlutterPearBarePlugin.swift must reference the exact '
            'directory name "$corestoreDir" pear-end/index.js uses for its '
            'Corestore');
    expect(text.contains('"$bulkDir"'), isTrue,
        reason: 'FlutterPearBarePlugin.swift must reference the exact '
            'directory name "$bulkDir" pear-end/index.js uses for bulk '
            'storage');
    expect(text.contains('applicationSupportDirectory'), isTrue,
        reason: 'the worklet storage root must be under Application '
            'Support, not Documents');
    expect(text.contains('isExcludedFromBackup'), isTrue,
        reason: 'pear-corestore/pear-bulk must be excluded from iCloud '
            'backup (Eng2 decision 35)');
    expect(text.contains('documentDirectory'), isFalse,
        reason: 'the worklet must never write under Documents -- an '
            'iCloud restore of Hypercore writer keys onto a second device '
            'forks cores, protocol corruption, not a UX nicety');
  });
}
