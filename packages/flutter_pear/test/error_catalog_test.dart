import 'dart:io';

import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';

// E8.3 -- keeps PearErrorCatalog, the real PearErrorCode registry, and
// ERRORS.md's anchors from silently drifting apart, the same
// "extract from source, don't hardcode twice" discipline
// backup_rules_test.dart/schema_test.dart already apply elsewhere.

void main() {
  test('every PearErrorCode has a catalog entry, and vice versa', () {
    final schemaDart = File('${Directory.current.path}/lib/src/schema.dart')
        .readAsStringSync();
    final classMatch =
        RegExp(r'abstract final class PearErrorCode \{(.*?)\n\}', dotAll: true)
            .firstMatch(schemaDart);
    expect(classMatch, isNotNull,
        reason: "couldn't find PearErrorCode's class body in schema.dart "
            '-- update this test if it moved');
    // `[^']+`, not `[A-Z_]+` -- matches the code's actual quoted value
    // regardless of its character set, so a future code containing a digit
    // or lowercase letter can't silently slip past this check the way an
    // uppercase-only pattern would (caught by E8.3's own review).
    final codeValues = RegExp(r"static const \w+ = '([^']+)';")
        .allMatches(classMatch!.group(1)!)
        .map((m) => m.group(1)!)
        .toSet();
    expect(codeValues.length, greaterThan(20),
        reason: 'this regex should find ~30 codes -- something is broken '
            'if it finds far fewer than that');

    for (final code in codeValues) {
      expect(PearErrorCatalog.entries.containsKey(code), isTrue,
          reason: '$code has no PearErrorCatalog entry');
    }
    for (final code in PearErrorCatalog.entries.keys) {
      expect(codeValues.contains(code), isTrue,
          reason: 'PearErrorCatalog has an entry for "$code", which is not '
              'a real PearErrorCode constant -- stale entry?');
    }
  });

  test("every catalog entry's anchor resolves to a real ERRORS.md section", () {
    final errorsMd =
        File('${Directory.current.path}/ERRORS.md').readAsStringSync();
    for (final code in PearErrorCatalog.entries.keys) {
      expect(errorsMd.contains('<a id="$code"></a>'), isTrue,
          reason: 'ERRORS.md has no `<a id="$code"></a>` anchor for $code');
    }
  });

  test(
      'PearException.toString() renders problem/cause/fix/docs for a '
      'cataloged code, across all three exception classes', () {
    // One code from each PearErrorCategory, plus one with none (falls back
    // to the base PearException) -- exercising all three concrete
    // exception classes this catalog has to render correctly for.
    for (final code in [
      PearErrorCode.unknownPeer, // PearConnectionException
      PearErrorCode.coreClosed, // PearStorageException
      PearErrorCode.rpcTimeout, // base PearException (uncategorized)
    ]) {
      final entry = PearErrorCatalog.entries[code]!;
      final e = pearExceptionFor('boom', code: code);
      final str = e.toString();
      expect(str, startsWith('${e.runtimeType}($code):'), reason: code);
      expect(str, contains(entry.problem), reason: code);
      expect(str, contains('Cause: ${entry.cause}'), reason: code);
      expect(str, contains('Fix: ${entry.fix}'), reason: code);
      expect(str, contains('Docs: ${anchorFor(code)}'), reason: code);
    }
  });

  test(
      "PearException.toString() falls back gracefully for a code the "
      'catalog has never heard of', () {
    final e = PearException('mystery', code: 'TOTALLY_UNKNOWN_CODE');
    expect(e.toString(), 'PearException(TOTALLY_UNKNOWN_CODE): mystery');
  });

  test(
      'PearException.details includes the JS stack when present, but '
      'toString() never does', () {
    final e = PearException('boom',
        code: PearErrorCode.workletCrashed, stack: 'at foo.js:1:1');
    expect(e.details, contains('boom'));
    expect(e.details, contains('at foo.js:1:1'));
    expect(e.toString(), isNot(contains('at foo.js:1:1')));
  });
}
