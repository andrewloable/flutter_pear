import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/pack.dart';

void main() {
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
}
