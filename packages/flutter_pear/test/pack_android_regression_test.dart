// 5A CRITICAL (flutter_pear-ovt.5.1): the v0.2 iOS extension to bin/pack.dart
// (multi-host bare-pack invocation, see buildBundle's doc comment) must
// never silently change what ships to ANDROID. This regenerates the
// Android-scoped :pack outputs into a temp tree from the real pear-end
// inputs and byte-compares them against the committed artifacts -- a stale
// committed bundle or addon set fails this test, not just a future device.
//
// Determinism (Eng2 #7): confirmed empirically in flutter_pear-ovt.1.6 --
// two bare-pack runs from identical inputs produced byte-identical output
// (cmp + matching sha256). This test therefore asserts byte-identical
// equality directly, not a normalized/fuzzy comparison.
//
// Bundle shape (Eng2 #3 fallback): the v0.2 pack extension landed as ONE
// multi-host bundle (android + ios hosts in a single bare-pack invocation,
// see buildBundle) rather than per-platform bundles (confirmed in
// flutter_pear-ovt.1.6's FEAS-MULTIHOST note) -- so there is no separate
// per-platform Android asset name to assert; `bundleAssetPath` is it.
//
// iOS outputs get no shape-only assertion here: as of this test, iOS
// produces no COMMITTED artifacts at all (the addon xcframeworks and
// BareKit.xcframework live only in the gitignored .spike/ spike directory,
// see flutter_pear-ovt.1.2/1.5) -- nothing to regress-test yet.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/pack.dart';

void main() {
  test(
      'regenerated bundle + Android jniLibs are byte-identical to the '
      'committed artifacts (5A CRITICAL -- Android must not drift)',
      () async {
    try {
      await Process.run('bare-pack', ['--version']);
      await Process.run('bare-link', ['--version']);
    } on ProcessException {
      markTestSkipped('PACK_REGRESSION_SKIPPED: bare-pack/bare-link not '
          'installed — npm i -g bare-pack bare-link');
      return;
    }

    // `flutter test` runs with the package root as the working directory.
    final realPkgRoot = Directory.current.path;
    final realPearEnd = Directory('$realPkgRoot/pear-end');
    final realNodeModules = Directory('${realPearEnd.path}/node_modules');
    if (!realNodeModules.existsSync()) {
      markTestSkipped('PACK_REGRESSION_SKIPPED: pear-end/node_modules '
          'missing — run `npm install` in pear-end/ first');
      return;
    }

    // Same temp-pkgRoot pattern as pack_test.dart, with a sibling
    // flutter_pear_bare/android/ so linkNativeAddons's relative
    // `$pkgRoot/../flutter_pear_bare/...` write lands inside the temp tree,
    // never the real one.
    //
    // resolveSymbolicLinksSync, not the raw createTempSync path: on macOS
    // Directory.systemTemp lives under /var/folders, itself a symlink to
    // /private/var/folders -- but Directory.current (what the OS actually
    // reports as cwd once set, and what a child process inherits) always
    // comes back fully resolved. Comparing bare-pack's manifest-path
    // computation against an UNresolved pkgRoot string it never itself sees
    // as cwd made every path grow a spurious ../.. bridge instead of
    // matching the committed bundle's short /pear-end/... form.
    final parentRaw =
        Directory.systemTemp.createTempSync('fp_pack_android_regression');
    final parent = Directory(parentRaw.resolveSymbolicLinksSync());
    addTearDown(() => parentRaw.deleteSync(recursive: true));
    final pkgRoot = Directory('${parent.path}/flutter_pear')..createSync();
    Directory('${pkgRoot.path}/pear-end').createSync();
    for (final entity in realPearEnd.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.endsWith('.js') || name.endsWith('.json')) {
        entity.copySync('${pkgRoot.path}/pear-end/$name');
      }
    }
    Link('${pkgRoot.path}/pear-end/node_modules')
        .createSync(realNodeModules.path);
    Directory('${parent.path}/flutter_pear_bare/android/src/main/jniLibs')
        .createSync(recursive: true);

    // bare-pack computes every embedded file's manifest-path KEY relative to
    // the process's current working directory, not the entry file's own
    // directory -- the real `dart run flutter_pear:pack` always has cwd ==
    // pkgRoot (main() reads pkgRoot straight from Directory.current.path),
    // so buildBundle's `Process.run('bare-pack', ...)` (no explicit
    // workingDirectory override) inherits that. Without switching cwd here
    // too, this test's temp pkgRoot sits far outside the process's real cwd
    // and every manifest path grows a long ../../.. prefix instead of the
    // committed bundle's short /pear-end/... form -- same bytes bundled,
    // different (non-matching) manifest, a real trap for a byte-comparison
    // test the pre-existing "buildBundle packs..." existence-only test never
    // hit. Restored via addTearDown so later tests in this same process see
    // the normal package-root cwd again.
    addTearDown(() => Directory.current = realPkgRoot);
    Directory.current = pkgRoot.path;

    expect(await buildBundle(pkgRoot.path), 0);
    expect(await linkNativeAddons(pkgRoot.path), 0);
    await collectThirdPartyLicenses(pkgRoot.path);

    final regeneratedBundle = File('${pkgRoot.path}/$bundleAssetPath');
    final committedBundle = File('$realPkgRoot/$bundleAssetPath');
    expect(committedBundle.existsSync(), isTrue,
        reason: 'committed $bundleAssetPath must exist in a fresh checkout');
    expect(
      regeneratedBundle.readAsBytesSync(),
      equals(committedBundle.readAsBytesSync()),
      reason: '$bundleAssetPath drifted from what :pack currently produces — '
          'run `dart run flutter_pear:pack` and commit the result',
    );

    for (final abi in nativeAddonAbis.keys) {
      final regeneratedDir = Directory(
          '${parent.path}/flutter_pear_bare/android/src/main/jniLibs/$abi');
      final committedDir = Directory(
          '$realPkgRoot/../flutter_pear_bare/android/src/main/jniLibs/$abi');
      expect(committedDir.existsSync(), isTrue,
          reason: 'committed jniLibs/$abi must exist in a fresh checkout');

      final regenerated = {
        for (final f in regeneratedDir.listSync().whereType<File>())
          f.uri.pathSegments.last: f.readAsBytesSync()
      };
      final committed = {
        for (final f in committedDir.listSync().whereType<File>())
          f.uri.pathSegments.last: f.readAsBytesSync()
      };
      expect(regenerated.keys.toSet(), committed.keys.toSet(),
          reason: 'jniLibs/$abi\'s .so file SET drifted from :pack\'s '
              'current output');
      for (final name in regenerated.keys) {
        expect(regenerated[name], equals(committed[name]),
            reason: 'jniLibs/$abi/$name drifted from :pack\'s current '
                'output — run `dart run flutter_pear:pack` and commit the '
                'result');
      }
    }

    // Shape only (Eng2 #7): THIRD_PARTY_LICENSES legitimately changes with
    // every dependency bump, so it is never byte-compared.
    final tpl = File('${pkgRoot.path}/THIRD_PARTY_LICENSES');
    expect(tpl.existsSync(), isTrue);
    final tplContent = tpl.readAsStringSync();
    expect(tplContent, isNotEmpty);
    expect(tplContent, contains('Apache License'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
