// 5A (flutter_pear-ovt.5.4): guards against a stale committed bundle
// shipping silently. Every committed bundle asset under assets/ must embed
// the exact kPearEndBundleVersion string (bare-pack bakes pear-end/version.js's
// module.exports literal into the bundle -- see bin/pack.dart's
// writeBundleVersion doc comment), and pear-end/version.js itself must equal
// kPearEndBundleVersion (source-side lockstep, since :pack writes both from
// the same computed value in one call). Named mutation this guards against
// (per the epic's acceptance): bump kPearEndBundleVersion in
// lib/src/bundle_version.dart WITHOUT re-running `dart run flutter_pear:pack`
// -- both assertions below then fail, since the actual bundle bytes and
// version.js still carry the OLD, un-repacked value.
//
// Today there is exactly one committed bundle asset (assets/pear-end.bundle,
// a single multi-host bundle -- see flutter_pear-ovt.1.6's FEAS-MULTIHOST
// finding); this test asserts over every *.bundle file under assets/ so it
// keeps working unchanged if a future per-platform fallback ever lands a
// second one (Eng2 #9 atomicity).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ignore: implementation_imports
import 'package:flutter_pear/src/bundle_version.dart';

void main() {
  test(
      'every committed bundle asset contains the exact kPearEndBundleVersion '
      'string', () {
    // `flutter test` runs with the package root as the working directory.
    final assetsDir = Directory('${Directory.current.path}/assets');
    final bundles = assetsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.bundle'))
        .toList();
    expect(bundles, isNotEmpty,
        reason: 'expected at least one committed *.bundle asset under '
            '${assetsDir.path}');

    for (final bundle in bundles) {
      final contents = bundle.readAsStringSync();
      expect(contents, contains(kPearEndBundleVersion),
          reason: '${bundle.path} does not contain the baked version '
              '"$kPearEndBundleVersion" -- run `dart run flutter_pear:pack` '
              'and commit the result');
    }
  });

  test(
      'pear-end/version.js (the JS-side half of the same stamp) equals '
      'kPearEndBundleVersion exactly', () {
    final versionJs =
        File('${Directory.current.path}/pear-end/version.js');
    expect(versionJs.existsSync(), isTrue,
        reason: '${versionJs.path} should exist -- writeBundleVersion writes '
            'it every time :pack runs');
    final match = RegExp(r'''module\.exports\s*=\s*['"]([^'"]+)['"]''')
        .firstMatch(versionJs.readAsStringSync());
    expect(match, isNotNull,
        reason: 'could not find module.exports = \'...\' in '
            '${versionJs.path}');
    expect(match!.group(1), kPearEndBundleVersion,
        reason: '${versionJs.path} is out of lockstep with '
            'lib/src/bundle_version.dart\'s kPearEndBundleVersion -- both '
            'are meant to be written together by writeBundleVersion; run '
            '`dart run flutter_pear:pack`');
  });
}
