import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../bin/pack.dart';

void main() {
  group('desktopBundleHosts', () {
    test('is exactly the macOS + Linux + Windows hosts (flutter_pear-6yz '
        'E-D3 macOS leg, flutter_pear-65g E-D2c Linux leg, flutter_pear-pfp '
        'E-D2b Windows leg)', () {
      expect(desktopBundleHosts,
          ['darwin-arm64', 'darwin-x64', 'linux-x64', 'win32-x64']);
    });
  });

  group('desktopBundleAssetDir routing (flutter_pear-9ng: each host lands '
      "inside flutter_pear_bare's OWN per-platform plugin folder, never "
      "flutter_pear's shared Flutter assets)", () {
    test('both darwin hosts route to the macOS plugin\'s SPM resources '
        'directory -- both, not just the current dev machine\'s own '
        'architecture, since a universal binary decides at OS launch which '
        'one it actually reads', () {
      expect(
        desktopBundleAssetDir('/pkg', 'darwin-arm64'),
        '/pkg/../flutter_pear_bare/macos/flutter_pear_bare/Sources/'
            'flutter_pear_bare/Resources/desktop/darwin-arm64',
      );
      expect(
        desktopBundleAssetDir('/pkg', 'darwin-x64'),
        '/pkg/../flutter_pear_bare/macos/flutter_pear_bare/Sources/'
            'flutter_pear_bare/Resources/desktop/darwin-x64',
      );
    });

    test('linux-x64 routes to the Linux plugin folder', () {
      expect(
        desktopBundleAssetDir('/pkg', 'linux-x64'),
        '/pkg/../flutter_pear_bare/linux/assets/desktop/linux-x64',
      );
    });

    test('win32-x64 routes to the Windows plugin folder', () {
      expect(
        desktopBundleAssetDir('/pkg', 'win32-x64'),
        '/pkg/../flutter_pear_bare/windows/assets/desktop/win32-x64',
      );
    });

    test('an unrecognized host throws rather than guessing a path', () {
      expect(() => desktopBundleAssetDir('/pkg', 'freebsd-x64'),
          throwsArgumentError);
    });
  });

  group('committed desktop bundle + addon layout (reads the committed tree '
      '-- no bare-pack invocation, no toolchain)', () {
    late String pkgRoot;

    setUpAll(() {
      pkgRoot = Directory.current.path;
    });

    test('every desktopBundleHosts entry has a committed pear-end.bundle',
        () {
      for (final host in desktopBundleHosts) {
        final bundle = File(
            '${desktopBundleAssetDir(pkgRoot, host)}/pear-end.bundle');
        expect(bundle.existsSync(), isTrue,
            reason: '${bundle.path} should exist once :pack has run');
        expect(bundle.lengthSync(), greaterThan(0),
            reason: '${bundle.path} should not be empty');
      }
    });

    test(
        'every offloaded addon under each host has an ACTUAL .bare prebuild '
        'file, not just an empty directory', () {
      for (final host in desktopBundleHosts) {
        final nodeModulesDir =
            Directory('${desktopBundleAssetDir(pkgRoot, host)}/node_modules');
        expect(nodeModulesDir.existsSync(), isTrue,
            reason: '${nodeModulesDir.path} should exist once :pack has run');
        final addonDirs =
            nodeModulesDir.listSync().whereType<Directory>().toList();
        expect(addonDirs, isNotEmpty,
            reason: 'expected at least one offloaded addon under '
                '${nodeModulesDir.path}');
        for (final addonDir in addonDirs) {
          final name =
              addonDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
          final prebuild =
              File('${addonDir.path}/prebuilds/$host/$name.bare');
          expect(prebuild.existsSync(), isTrue,
              reason: 'expected ${prebuild.path} (offloaded by '
                  'buildDesktopBundle) to exist');
        }
      }
    });

    test(
        'both darwin hosts land under the SAME macOS resources directory '
        '(one shared resource bundle, not two separate ones) -- catches a '
        'routing regression that scattered them', () {
      final arm64 = Directory(desktopBundleAssetDir(pkgRoot, 'darwin-arm64'));
      final x64 = Directory(desktopBundleAssetDir(pkgRoot, 'darwin-x64'));
      expect(arm64.parent.path, x64.parent.path,
          reason: 'both darwin-arm64/ and darwin-x64/ should be siblings '
              'under Resources/desktop/');
    });
  });

  group("flutter_pear's own pubspec.yaml never re-acquires a desktop asset "
      '(regression guard for flutter_pear-9ng itself: this is the exact '
      'shape of bug the fix removed -- a universal Flutter asset every '
      'consuming app bundles regardless of its own target platform)', () {
    test('no assets/desktop/ entry anywhere in the flutter: assets: list',
        () {
      final pubspecText =
          File('${Directory.current.path}/pubspec.yaml').readAsStringSync();
      expect(pubspecText, isNot(contains('assets/desktop')),
          reason: 'flutter_pear/pubspec.yaml must not declare any desktop '
              'host as a Flutter asset -- every consuming app on every '
              'platform would bundle it (flutter_pear-9ng)');
    });

    test('the old universal assets/desktop/ directory is gone from '
        "flutter_pear's own package tree", () {
      final oldDir = Directory('${Directory.current.path}/assets/desktop');
      expect(oldDir.existsSync(), isFalse,
          reason: '${oldDir.path} should have been removed once its '
              'contents moved into flutter_pear_bare\'s own platform '
              'folders');
    });
  });

  group('each desktop platform\'s own native build declares the bundling '
      '(flutter_pear-9ng: this is what makes the asset arrive at build '
      "time; the committed FILES alone prove nothing about whether a "
      "platform's build system actually packages them)", () {
    late String bareRoot;

    setUpAll(() {
      bareRoot = '${Directory.current.path}/../flutter_pear_bare';
    });

    test('macOS Package.swift declares the desktop Resources', () {
      final text =
          File('$bareRoot/macos/flutter_pear_bare/Package.swift')
              .readAsStringSync();
      expect(text, contains('.copy("Resources/desktop")'),
          reason: 'the SPM target must declare its desktop resources, or '
              'Bundle.module will never find them at runtime');
    });

    test('macOS podspec declares the desktop resource_bundles (CocoaPods '
        'compat path)', () {
      final text = File('$bareRoot/macos/flutter_pear_bare.podspec')
          .readAsStringSync();
      expect(text, contains('resource_bundles'));
      expect(text, contains('flutter_pear_bare_desktop'));
      expect(text, contains('Resources/desktop'));
    });

    test('Linux CMakeLists.txt declares an install(DIRECTORY ...) for '
        'linux-x64, preserving nested structure (install(FILES ...) via '
        'flutter_pear_bare_bundled_libraries would flatten it and break '
        "bare's own require() resolution)", () {
      final text = File('$bareRoot/linux/CMakeLists.txt').readAsStringSync();
      expect(text, contains('install(DIRECTORY'));
      expect(text, contains('assets/desktop/linux-x64'));
      expect(text, contains('flutter_pear_bare_desktop'));
    });

    test('Windows CMakeLists.txt declares an install(CODE "file(INSTALL '
        '...)") for win32-x64 -- a bare install(DIRECTORY ...) fails under '
        "Visual Studio's multi-config generator", () {
      final text =
          File('$bareRoot/windows/CMakeLists.txt').readAsStringSync();
      expect(text, contains('install(CODE'));
      expect(text, contains('file(INSTALL'));
      expect(text, contains('assets/desktop/win32-x64'));
      expect(text, contains('flutter_pear_bare_desktop'));
    });
  });
}
