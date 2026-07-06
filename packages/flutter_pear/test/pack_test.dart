import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/pack.dart';

void main() {
  test(
      'bundleHosts is exactly the 64-bit Android ABIs plus both iOS hosts -- '
      'no 32-bit hosts, no --preset shortcut (flutter_pear-ovt.2.1)', () {
    expect(bundleHosts, [
      'android-arm64',
      'android-x64',
      'ios-arm64',
      'ios-arm64-simulator',
    ]);
  });

  test('buildBundle packs pear-end/index.js to the documented asset path',
      () async {
    try {
      await Process.run('bare-pack', ['--version']);
    } on ProcessException {
      markTestSkipped('bare-pack not installed — npm i -g bare-pack');
      return;
    }

    // `flutter test` runs with the package root as the working directory.
    final realPearEnd = Directory('${Directory.current.path}/pear-end');
    final realNodeModules = Directory('${realPearEnd.path}/node_modules');
    if (!realNodeModules.existsSync()) {
      markTestSkipped(
          'pear-end/node_modules missing — run `npm install` in pear-end/ first');
      return;
    }

    final tmp = Directory.systemTemp.createTempSync('fp_pack_bundle');
    addTearDown(() => tmp.deleteSync(recursive: true));
    Directory('${tmp.path}/pear-end').createSync(recursive: true);
    // Every top-level *.js/*.json file, not a hand-picked list (E5.7
    // review fix): index.js grew a same-directory sibling module
    // (autobase-recipes.js) that a fixed copy list silently left out of
    // this test's bundle attempt -- bare-pack then failed to resolve
    // index.js's `require('./autobase-recipes')` with MODULE_NOT_FOUND,
    // and nothing caught it because this whole test skips silently
    // whenever bare-pack isn't on PATH (see the try/catch above). A glob
    // over pear-end/*.js{,on} can't go stale the same way the next time a
    // new sibling module is added.
    for (final entity in realPearEnd.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.js') || name.endsWith('.json')) {
        entity.copySync('${tmp.path}/pear-end/$name');
      }
    }
    // Symlinked, not copied: index.js now requires real npm packages
    // (hyperswarm et al.), and bare-pack needs them resolvable to bundle.
    Link('${tmp.path}/pear-end/node_modules').createSync(realNodeModules.path);

    expect(await buildBundle(tmp.path), 0);

    final bundle = File('${tmp.path}/$bundleAssetPath');
    expect(bundle.existsSync(), isTrue);
    expect(bundle.lengthSync(), greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
      'linkNativeAddons commits real .so files for each ABI into the '
      'sibling flutter_pear_bare package (flutter_pear-k2y)', () async {
    try {
      await Process.run('bare-link', ['--version']);
    } on ProcessException {
      markTestSkipped('bare-link not installed — npm i -g bare-link');
      return;
    }

    final realPearEnd = Directory('${Directory.current.path}/pear-end');
    final realNodeModules = Directory('${realPearEnd.path}/node_modules');
    if (!realNodeModules.existsSync()) {
      markTestSkipped(
          'pear-end/node_modules missing — run `npm install` in pear-end/ first');
      return;
    }

    // pkgRoot/pear-end/node_modules (symlinked to the real, already
    // `npm install`-ed tree -- bare-link needs real resolved packages, not
    // a fixture) with a sibling flutter_pear_bare/android/, exactly the
    // real repo's layout -- linkNativeAddons writes relative to pkgRoot.
    final parent = Directory.systemTemp.createTempSync('fp_pack_link_addons');
    addTearDown(() => parent.deleteSync(recursive: true));
    final pkgRoot = Directory('${parent.path}/flutter_pear')..createSync();
    Directory('${pkgRoot.path}/pear-end').createSync();
    Link('${pkgRoot.path}/pear-end/node_modules')
        .createSync(realNodeModules.path);
    // bare-link reads package.json (and, per npm convention, resolves
    // against package-lock.json) from the CURRENT directory to know what
    // to link -- a node_modules symlink alone isn't enough; a first
    // attempt at this test with only node_modules present had bare-link
    // exit 0 having linked nothing at all (this test caught that, hence
    // this explicit copy).
    for (final name in ['package.json', 'package-lock.json']) {
      File('${realPearEnd.path}/$name')
          .copySync('${pkgRoot.path}/pear-end/$name');
    }
    final jniLibsRoot =
        Directory('${parent.path}/flutter_pear_bare/android/src/main/jniLibs')
          ..createSync(recursive: true);

    expect(await linkNativeAddons(pkgRoot.path), 0);

    for (final abi in ['arm64-v8a', 'x86_64']) {
      final abiDir = Directory('${jniLibsRoot.path}/$abi');
      expect(abiDir.existsSync(), isTrue, reason: '$abi dir should exist');
      final soFiles = abiDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.so'));
      expect(soFiles, isNotEmpty, reason: '$abi should have linked .so files');
      // A real dependency this repo bundles today (hyperswarm's transport
      // encryption) -- proves this is a genuine bare-link run, not just an
      // empty directory.
      expect(soFiles.any((f) => f.path.contains('sodium-native')), isTrue,
          reason: '$abi should include libsodium-native.so');
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
      'linkNativeAddons prunes a stale ABI directory that is no longer in '
      'nativeAddonAbis, matching fetchBareKit\'s own ABI-pruning behavior '
      '(review finding)', () async {
    try {
      await Process.run('bare-link', ['--version']);
    } on ProcessException {
      markTestSkipped('bare-link not installed — npm i -g bare-link');
      return;
    }
    final realPearEnd = Directory('${Directory.current.path}/pear-end');
    final realNodeModules = Directory('${realPearEnd.path}/node_modules');
    if (!realNodeModules.existsSync()) {
      markTestSkipped(
          'pear-end/node_modules missing — run `npm install` in pear-end/ first');
      return;
    }

    final parent =
        Directory.systemTemp.createTempSync('fp_pack_link_addons_prune');
    addTearDown(() => parent.deleteSync(recursive: true));
    final pkgRoot = Directory('${parent.path}/flutter_pear')..createSync();
    Directory('${pkgRoot.path}/pear-end').createSync();
    Link('${pkgRoot.path}/pear-end/node_modules')
        .createSync(realNodeModules.path);
    for (final name in ['package.json', 'package-lock.json']) {
      File('${realPearEnd.path}/$name')
          .copySync('${pkgRoot.path}/pear-end/$name');
    }
    final jniLibsRoot =
        Directory('${parent.path}/flutter_pear_bare/android/src/main/jniLibs')
          ..createSync(recursive: true);
    // A stale ABI this repo no longer ships (e.g. dropped 32-bit) --
    // linkNativeAddons must remove it, not just leave it alongside the
    // current arm64-v8a/x86_64 output.
    final staleAbiDir = Directory('${jniLibsRoot.path}/armeabi-v7a')
      ..createSync(recursive: true);
    File('${staleAbiDir.path}/libstale-addon.so').writeAsStringSync('stale');

    expect(await linkNativeAddons(pkgRoot.path), 0);

    expect(staleAbiDir.existsSync(), isFalse,
        reason: 'a stale ABI directory not in nativeAddonAbis must be pruned');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
      'nativeAddonAbis stays in sync with build.gradle\'s bareKitAbis '
      '(review finding -- the two lists were only linked by a comment)', () {
    final gradleFile = File(
        '${Directory.current.path}/../flutter_pear_bare/android/build.gradle');
    if (!gradleFile.existsSync()) {
      markTestSkipped(
          '../flutter_pear_bare/android/build.gradle not found (needs the '
          'real monorepo checkout)');
      return;
    }
    final listMatch = RegExp(r'''bareKitAbis\s*=\s*\[([^\]]*)\]''')
        .firstMatch(gradleFile.readAsStringSync());
    expect(listMatch, isNotNull,
        reason: 'could not find bareKitAbis in build.gradle');
    final gradleAbis = RegExp(r'''["']([^"']+)["']''')
        .allMatches(listMatch!.group(1)!)
        .map((m) => m.group(1)!)
        .toSet();
    expect(nativeAddonAbis.keys.toSet(), gradleAbis,
        reason: "bin/pack.dart's nativeAddonAbis must match "
            "build.gradle's bareKitAbis exactly");
  });

  test('collects LICENSE + NOTICE, including scoped packages', () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final nm = Directory('${tmp.path}/pear-end/node_modules')
      ..createSync(recursive: true);

    // plain module
    Directory('${nm.path}/hypercore').createSync();
    File('${nm.path}/hypercore/LICENSE').writeAsStringSync('MIT — hypercore');
    File('${nm.path}/hypercore/package.json').writeAsStringSync(
        '{"name":"hypercore","version":"1.0.0","license":"MIT"}');

    // scoped module with a NOTICE
    Directory('${nm.path}/@hyperswarm/secret-stream')
        .createSync(recursive: true);
    File('${nm.path}/@hyperswarm/secret-stream/LICENSE')
        .writeAsStringSync('MIT — secret-stream');
    File('${nm.path}/@hyperswarm/secret-stream/NOTICE')
        .writeAsStringSync('Copyright Holepunch');

    final count = await collectThirdPartyLicenses(tmp.path);
    expect(count, 2);

    final tpl = File('${tmp.path}/THIRD_PARTY_LICENSES').readAsStringSync();
    expect(tpl, contains('hypercore@1.0.0'));
    expect(tpl, contains('MIT — hypercore'));
    expect(tpl, contains('secret-stream'));
    expect(tpl, contains('MIT — secret-stream'));

    expect(File('${tmp.path}/NOTICE').readAsStringSync(),
        contains('Copyright Holepunch'));
  });

  test('missing node_modules is a no-op returning 0', () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack_empty');
    addTearDown(() => tmp.deleteSync(recursive: true));
    expect(await collectThirdPartyLicenses(tmp.path), 0);
  });

  test(
      'a module with neither a LICENSE file nor a package.json license '
      'field fails loud, naming the module', () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack_missing');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final nm = Directory('${tmp.path}/pear-end/node_modules')
      ..createSync(recursive: true);
    Directory('${nm.path}/mystery-pkg').createSync();
    File('${nm.path}/mystery-pkg/package.json')
        .writeAsStringSync('{"name":"mystery-pkg","version":"1.0.0"}');

    await expectLater(
      () => collectThirdPartyLicenses(tmp.path),
      throwsA(isA<LicenseViolationException>()
          .having((e) => e.toString(), 'message', contains('mystery-pkg'))),
    );
  });

  test('a GPL-licensed module fails loud instead of being bundled', () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack_gpl');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final nm = Directory('${tmp.path}/pear-end/node_modules')
      ..createSync(recursive: true);
    Directory('${nm.path}/copyleft-pkg').createSync();
    File('${nm.path}/copyleft-pkg/package.json').writeAsStringSync(
        '{"name":"copyleft-pkg","version":"2.0.0","license":"GPL-3.0-only"}');
    File('${nm.path}/copyleft-pkg/LICENSE')
        .writeAsStringSync('GNU GENERAL PUBLIC LICENSE');

    await expectLater(
      () => collectThirdPartyLicenses(tmp.path),
      throwsA(isA<LicenseViolationException>()
          .having((e) => e.toString(), 'message', contains('copyleft-pkg'))),
    );
  });

  test('an unrecognized license expression fails loud rather than guessing',
      () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack_unknown');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final nm = Directory('${tmp.path}/pear-end/node_modules')
      ..createSync(recursive: true);
    Directory('${nm.path}/dual-licensed-pkg').createSync();
    File('${nm.path}/dual-licensed-pkg/package.json')
        .writeAsStringSync('{"name":"dual-licensed-pkg","version":"1.0.0",'
            '"license":"(MIT OR Apache-2.0)"}');
    File('${nm.path}/dual-licensed-pkg/LICENSE').writeAsStringSync('...');

    await expectLater(
      () => collectThirdPartyLicenses(tmp.path),
      throwsA(isA<LicenseViolationException>().having(
          (e) => e.toString(), 'message', contains('dual-licensed-pkg'))),
    );
  });

  test(
      'a module with a copyleft LICENSE file but NO package.json license '
      'field still fails loud (not just when the field itself is denied)',
      () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack_gpl_nofield');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final nm = Directory('${tmp.path}/pear-end/node_modules')
      ..createSync(recursive: true);
    Directory('${nm.path}/sneaky-copyleft').createSync();
    File('${nm.path}/sneaky-copyleft/package.json')
        .writeAsStringSync('{"name":"sneaky-copyleft","version":"1.0.0"}');
    File('${nm.path}/sneaky-copyleft/LICENSE')
        .writeAsStringSync('GNU GENERAL PUBLIC LICENSE Version 3');

    await expectLater(
      () => collectThirdPartyLicenses(tmp.path),
      throwsA(isA<LicenseViolationException>()
          .having((e) => e.toString(), 'message', contains('sneaky-copyleft'))),
    );
  });

  test(
      'a name@version collision between a hoisted and a nested copy keeps '
      'the hoisted (shallower) one\'s license text', () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack_dedup');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final nm = Directory('${tmp.path}/pear-end/node_modules')
      ..createSync(recursive: true);

    // Hoisted copy, listed AFTER its container alphabetically so a naive
    // listing-order dedup (rather than a depth-based one) would pick the
    // nested copy instead -- this is the exact ordering the review finding
    // reproduced the bug with.
    Directory('${nm.path}/zzz-hoisted-dup').createSync();
    File('${nm.path}/zzz-hoisted-dup/package.json').writeAsStringSync(
        '{"name":"dup-pkg","version":"1.0.0","license":"MIT"}');
    File('${nm.path}/zzz-hoisted-dup/LICENSE')
        .writeAsStringSync('HOISTED-COPY-TEXT');
    // Rename trick: the actual package name comes from package.json, not
    // the directory name, so this directory IS the "dup-pkg@1.0.0" the
    // nested copy below collides with.

    Directory('${nm.path}/aaa-container').createSync();
    File('${nm.path}/aaa-container/package.json').writeAsStringSync(
        '{"name":"aaa-container","version":"1.0.0","license":"MIT"}');
    File('${nm.path}/aaa-container/LICENSE')
        .writeAsStringSync('MIT — aaa-container');
    final nestedNm = Directory('${nm.path}/aaa-container/node_modules')
      ..createSync(recursive: true);
    Directory('${nestedNm.path}/dup-pkg-dir').createSync();
    File('${nestedNm.path}/dup-pkg-dir/package.json').writeAsStringSync(
        '{"name":"dup-pkg","version":"1.0.0","license":"MIT"}');
    File('${nestedNm.path}/dup-pkg-dir/LICENSE')
        .writeAsStringSync('NESTED-COPY-TEXT');

    await collectThirdPartyLicenses(tmp.path);
    final result = File('${tmp.path}/THIRD_PARTY_LICENSES').readAsStringSync();
    expect(result, contains('HOISTED-COPY-TEXT'));
    expect(result, isNot(contains('NESTED-COPY-TEXT')));
  });

  test(
      'a module with no bundled LICENSE file but an allow-listed '
      'package.json license (e.g. corestore) is captured, not skipped',
      () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack_fieldonly');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final nm = Directory('${tmp.path}/pear-end/node_modules')
      ..createSync(recursive: true);
    Directory('${nm.path}/corestore-like').createSync();
    File('${nm.path}/corestore-like/package.json').writeAsStringSync(
        '{"name":"corestore-like","version":"7.11.0","license":"MIT"}');
    // Deliberately no LICENSE file, mirroring the real corestore package.

    final count = await collectThirdPartyLicenses(tmp.path);
    expect(count, 1);
    final tpl = File('${tmp.path}/THIRD_PARTY_LICENSES').readAsStringSync();
    expect(tpl, contains('corestore-like@7.11.0'));
    expect(tpl, contains('MIT'));
  });

  test(
      'a dependency nested inside another package\'s own node_modules is '
      'still collected, not just top-level packages', () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack_nested');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final nm = Directory('${tmp.path}/pear-end/node_modules')
      ..createSync(recursive: true);
    Directory('${nm.path}/outer').createSync();
    File('${nm.path}/outer/package.json').writeAsStringSync(
        '{"name":"outer","version":"1.0.0","license":"MIT"}');
    File('${nm.path}/outer/LICENSE').writeAsStringSync('MIT — outer');

    final nestedNm = Directory('${nm.path}/outer/node_modules')
      ..createSync(recursive: true);
    Directory('${nestedNm.path}/inner').createSync();
    File('${nestedNm.path}/inner/package.json').writeAsStringSync(
        '{"name":"inner","version":"3.0.0","license":"ISC"}');
    File('${nestedNm.path}/inner/LICENSE').writeAsStringSync('ISC — inner');

    final count = await collectThirdPartyLicenses(tmp.path);
    expect(count, 2);
    final tpl = File('${tmp.path}/THIRD_PARTY_LICENSES').readAsStringSync();
    expect(tpl, contains('outer@1.0.0'));
    expect(tpl, contains('inner@3.0.0'));
    expect(tpl, contains('ISC — inner'));
  });

  test(
      'bare-kit static entry is added when a sibling '
      'flutter_pear_bare/android/build.gradle declares bareKitVersion',
      () async {
    final parent =
        Directory.systemTemp.createTempSync('fp_pack_barekit_ok_parent');
    addTearDown(() => parent.deleteSync(recursive: true));
    final pkgRoot = Directory('${parent.path}/flutter_pear')..createSync();
    Directory('${pkgRoot.path}/pear-end/node_modules')
        .createSync(recursive: true);
    final bareDir = Directory('${parent.path}/flutter_pear_bare/android')
      ..createSync(recursive: true);
    File('${bareDir.path}/build.gradle')
        .writeAsStringSync('def bareKitVersion = "9.9.9"\n');

    final count = await collectThirdPartyLicenses(pkgRoot.path);
    expect(count, 0); // no real node_modules packages, just the static entry
    final tpl = File('${pkgRoot.path}/THIRD_PARTY_LICENSES').readAsStringSync();
    expect(tpl, contains('bare-kit@9.9.9'));
    expect(tpl, contains('Apache-2.0'));
  });

  test(
      'bare-kit static entry fails loud if the sibling build.gradle has no '
      'parseable bareKitVersion', () async {
    final parent =
        Directory.systemTemp.createTempSync('fp_pack_barekit_bad_parent');
    addTearDown(() => parent.deleteSync(recursive: true));
    final pkgRoot = Directory('${parent.path}/flutter_pear')..createSync();
    Directory('${pkgRoot.path}/pear-end/node_modules')
        .createSync(recursive: true);
    final bareDir = Directory('${parent.path}/flutter_pear_bare/android')
      ..createSync(recursive: true);
    File('${bareDir.path}/build.gradle')
        .writeAsStringSync('// no version declared here\n');

    await expectLater(
      () => collectThirdPartyLicenses(pkgRoot.path),
      throwsA(isA<LicenseViolationException>()
          .having((e) => e.toString(), 'message', contains('bareKitVersion'))),
    );
  });

  test(
      'NOTICE is regenerated fresh each run -- stale content never '
      'survives a module being removed', () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack_stale_notice');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final nm = Directory('${tmp.path}/pear-end/node_modules')
      ..createSync(recursive: true);
    final pkgDir = Directory('${nm.path}/noisy-pkg')..createSync();
    File('${pkgDir.path}/package.json').writeAsStringSync(
        '{"name":"noisy-pkg","version":"1.0.0","license":"MIT"}');
    File('${pkgDir.path}/LICENSE').writeAsStringSync('MIT — noisy-pkg');
    File('${pkgDir.path}/NOTICE').writeAsStringSync('Copyright Noisy Corp');

    await collectThirdPartyLicenses(tmp.path);
    expect(File('${tmp.path}/NOTICE').readAsStringSync(),
        contains('Copyright Noisy Corp'));

    // Remove the module that contributed the NOTICE entry, then rerun.
    pkgDir.deleteSync(recursive: true);
    await collectThirdPartyLicenses(tmp.path);
    expect(File('${tmp.path}/NOTICE').readAsStringSync(),
        isNot(contains('Copyright Noisy Corp')));
  });
}
