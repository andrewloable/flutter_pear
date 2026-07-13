import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// flutter_pear-0t6 -- the Desktop/bare-runtime story is written out twice
// (root README.md and this package's own README.md) because GitHub's
// renderer can't include one file inside another. That let a stale claim
// survive in 6 separate spots until a human happened to spot one (see the
// 0t6 bug report). This test can't stop the wording from drifting, but it
// pins the few facts that actually matter -- the fix-step count, the
// `doctor --fix` ordering in the quick-start block -- so a future edit to
// one README without the other fails `flutter test` instead of shipping
// silently, the same "catch drift with a real test" discipline
// error_catalog_test.dart/check_pins_test.dart already apply elsewhere.

void main() {
  final rootReadme =
      File('${Directory.current.path}/../../README.md').readAsStringSync();
  final packageReadme =
      File('${Directory.current.path}/README.md').readAsStringSync();
  final readmes = {
    'README.md': rootReadme,
    'packages/flutter_pear/README.md': packageReadme,
  };

  test(
      'both READMEs run `doctor --fix` between `flutter create` and '
      '`flutter run` in the Desktop quick-start block (flutter_pear-t5c)',
      () {
    for (final entry in readmes.entries) {
      final block = RegExp(
        r'```bash\nflutter create --platforms=macos.*?\n```',
        dotAll: true,
      ).firstMatch(entry.value);
      expect(block, isNotNull,
          reason:
              '${entry.key}: could not find the Desktop quick-start code '
              'block -- update this test if it moved');
      final lines = block!.group(0)!.split('\n');
      final createIndex = lines.indexWhere((l) => l.contains('flutter create'));
      final fixIndex = lines.indexWhere((l) => l.contains('doctor --fix'));
      final runIndex = lines.indexWhere((l) => l.contains('flutter run'));
      expect(createIndex, greaterThanOrEqualTo(0), reason: entry.key);
      expect(fixIndex, greaterThan(createIndex),
          reason:
              '${entry.key}: `doctor --fix` must appear after `flutter '
              'create` in the quick-start block');
      expect(runIndex, greaterThan(fixIndex),
          reason:
              '${entry.key}: `flutter run` must appear after `doctor '
              '--fix`, not before it -- a reader following the block '
              'top-to-bottom would hit the raw SwiftPM error first');
    }
  });

  test(
      'both READMEs agree on how many extra things macOS needs before it '
      'builds', () {
    final rootCount =
        RegExp(r'macOS specifically needs (\w+) more things').firstMatch(rootReadme)?.group(1);
    final packageCount =
        RegExp(r'macOS needs (\w+) more things').firstMatch(packageReadme)?.group(1);
    expect(rootCount, isNotNull,
        reason: 'README.md wording moved -- update this test to match');
    expect(packageCount, isNotNull,
        reason:
            'packages/flutter_pear/README.md wording moved -- update this '
            'test to match');
    expect(rootCount, equals(packageCount),
        reason:
            'README.md says "$rootCount", packages/flutter_pear/README.md '
            'says "$packageCount" -- these describe the same doctor --fix '
            'behavior and must agree');
  });

  test(
      'both READMEs list the same 3 macOS-only fix steps, matching what '
      'applyMacosFixes() actually does', () {
    for (final phrase in [
      'App Sandbox is disabled',
      'NSLocalNetworkUsageDescription',
      '10.15.4',
    ]) {
      expect(rootReadme, contains(phrase),
          reason: 'README.md is missing "$phrase"');
      expect(packageReadme, contains(phrase),
          reason: 'packages/flutter_pear/README.md is missing "$phrase"');
    }
  });

  test(
      'both READMEs describe `bare` auto-fetch as covering all three '
      'desktop platforms, not stale macOS-only wording (flutter_pear-8f6)',
      () {
    for (final entry in readmes.entries) {
      expect(
          entry.value,
          contains('fetched automatically on all three desktop platforms'),
          reason: '${entry.key}: missing/stale bare-runtime auto-fetch claim');
      expect(entry.value, isNot(contains('still need it on PATH')),
          reason:
              '${entry.key}: reintroduces the pre-8f6 stale claim that '
              'Linux/Windows need `bare` on PATH manually');
    }
  });
}
