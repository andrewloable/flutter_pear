import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';

import '../bin/pack.dart';

void main() {
  test(
      'iosAddonHosts is exactly device arm64 + simulator arm64 -- no '
      'x86_64 slice (decision D21, flutter_pear-ovt.2.2)', () {
    expect(iosAddonHosts, ['ios-arm64', 'ios-arm64-simulator']);
  });

  group('committed ios/addons layout (reads the committed tree -- no '
      'toolchain, no self-skip)', () {
    late Directory addonsDir;

    setUpAll(() {
      addonsDir = Directory(
          '${Directory.current.path}/../flutter_pear_bare/ios/addons');
    });

    test('ios/addons exists with at least the sodium-native and udx-native '
        'families', () {
      expect(addonsDir.existsSync(), isTrue,
          reason: '${addonsDir.path} should exist once :pack has run');
      final names = addonsDir
          .listSync()
          .whereType<Directory>()
          .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toSet();
      expect(names.any((n) => n.startsWith('sodium-native.')), isTrue,
          reason: 'expected a sodium-native.*.xcframework entry');
      expect(names.any((n) => n.startsWith('udx-native.')), isTrue,
          reason: 'expected a udx-native.*.xcframework entry');
    });

    test('every entry under ios/addons is a directory named *.xcframework',
        () {
      for (final entity in addonsDir.listSync()) {
        final name =
            entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
        expect(entity, isA<Directory>(),
            reason: '$name should be a directory, not a loose file');
        expect(name.endsWith('.xcframework'), isTrue,
            reason: '$name should end in .xcframework');
      }
    });

    test(
        'every committed xcframework\'s Info.plist names both required '
        'slices, and nothing names x86_64', () {
      for (final entity in addonsDir.listSync().whereType<Directory>()) {
        final plist = File('${entity.path}/Info.plist');
        expect(plist.existsSync(), isTrue,
            reason: '${entity.path} should have an Info.plist');
        final text = plist.readAsStringSync();
        for (final host in iosAddonHosts) {
          expect(text.contains('<string>$host</string>'), isTrue,
              reason: '${entity.path}/Info.plist should list $host');
        }
        expect(text.contains('x86_64'), isFalse,
            reason: '${entity.path}/Info.plist should not list an x86_64 '
                'simulator slice (decision D21)');
      }
    });

    test(
        'every committed xcframework has an ACTUAL directory for both '
        'required slices, not just an Info.plist claiming they exist '
        '(flutter_pear-ovt.5.2)', () {
      // Deliberately separate from the Info.plist-text test above: an
      // xcframework whose Info.plist lists a slice but whose slice
      // directory (and binary) is missing/corrupt would still pass that
      // one -- exactly the gap flutter_pear-ovt.3.7's ios/tool/preflight.sh
      // exists to catch at build/consumer time. This is that same check,
      // pinned here against the repo's OWN committed state.
      for (final entity in addonsDir.listSync().whereType<Directory>()) {
        for (final host in iosAddonHosts) {
          final slice = Directory('${entity.path}/$host');
          expect(slice.existsSync(), isTrue,
              reason: '${entity.path} should have an actual $host/ slice '
                  'directory, not just an Info.plist mention of it');
        }
      }
    });
  });

  test(
      'linkNativeAddonsIos leaves a pre-populated ios/addons/ untouched '
      'when bare-link produces nothing usable', () async {
    try {
      await Process.run('bare-link', ['--version']);
    } on ProcessException {
      markTestSkipped('bare-link not installed — npm i -g bare-link');
      return;
    }

    // A pear-end/ with node_modules present (so linkNativeAddonsIos doesn't
    // take its "missing node_modules" skip path) but no package.json/
    // package-lock.json -- bare-link then has nothing to resolve and
    // produces an empty output directory, exactly the "produced nothing"
    // case this fixture exercises.
    final parent =
        Directory.systemTemp.createTempSync('fp_pack_ios_addons_empty');
    addTearDown(() => parent.deleteSync(recursive: true));
    final pkgRoot = Directory('${parent.path}/flutter_pear')..createSync();
    Directory('${pkgRoot.path}/pear-end/node_modules')
        .createSync(recursive: true);

    final addonsRoot =
        Directory('${parent.path}/flutter_pear_bare/ios/addons')
          ..createSync(recursive: true);
    final sentinel = Directory('${addonsRoot.path}/sentinel.xcframework')
      ..createSync();
    File('${sentinel.path}/marker').writeAsStringSync('pre-existing');

    expect(await linkNativeAddonsIos(pkgRoot.path), isNot(0));
    expect(sentinel.existsSync(), isTrue,
        reason: 'a produced-nothing bare-link run must not touch the '
            'previously-committed ios/addons/');
    expect(File('${sentinel.path}/marker').readAsStringSync(),
        'pre-existing');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('linkNativeAddonsIos is a no-op returning 0 when pear-end/'
      'node_modules is missing', () async {
    final tmp = Directory.systemTemp.createTempSync('fp_pack_ios_no_nm');
    addTearDown(() => tmp.deleteSync(recursive: true));
    expect(await linkNativeAddonsIos(tmp.path), 0);
  });

  group('BareKit repack (flutter_pear-ovt.2.3) -- network/gh kept out of '
      'these via injected downloadFn/uploadFn', () {
    const fixtureVersion = '9.9.9';
    // A real, arbitrary 64-hex-char string -- readBareKitGradlePin only
    // requires the SHAPE (64 hex chars), never verifies it against
    // anything itself (verification against a downloaded zip is
    // repackBareKit's job, covered separately below).
    const fixtureUpstreamSha =
        '353886e01e5b66cee849162486b715b0cb53df8bc0b871934d249cbed2e9451b';

    Directory writeFixtureGradle(String pkgRoot, {String? body}) {
      final bareDir =
          Directory('$pkgRoot/../flutter_pear_bare/android')..createSync(recursive: true);
      File('${bareDir.path}/build.gradle').writeAsStringSync(body ??
          'def bareKitVersion = "$fixtureVersion"\n'
              'def bareKitSha256 = "$fixtureUpstreamSha"\n');
      return bareDir;
    }

    Future<File> buildFixtureUpstreamZip(Directory parent) async {
      final xcfwDir =
          Directory('${parent.path}/apple/BareKit.xcframework')
            ..createSync(recursive: true);
      File('${xcfwDir.path}/Info.plist').writeAsStringSync('<plist/>');
      final zip = File('${parent.path}/prebuilds.zip');
      final result = await Process.run(
        'zip',
        ['-qr', zip.path, 'apple'],
        workingDirectory: parent.path,
      );
      expect(result.exitCode, 0, reason: 'fixture zip creation: ${result.stderr}');
      return zip;
    }

    test('readBareKitGradlePin parses version + upstreamSha256', () {
      final tmp = Directory.systemTemp.createTempSync('fp_pack_barekit_pin_ok');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final pkgRoot = Directory('${tmp.path}/flutter_pear')..createSync();
      writeFixtureGradle(pkgRoot.path);

      final pin = readBareKitGradlePin(pkgRoot.path);
      expect(pin.version, fixtureVersion);
      expect(pin.upstreamSha256, fixtureUpstreamSha);
    });

    test('readBareKitGradlePin throws when bareKitVersion is missing', () {
      final tmp =
          Directory.systemTemp.createTempSync('fp_pack_barekit_pin_novers');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final pkgRoot = Directory('${tmp.path}/flutter_pear')..createSync();
      writeFixtureGradle(pkgRoot.path,
          body: 'def bareKitSha256 = "$fixtureUpstreamSha"\n');

      expect(() => readBareKitGradlePin(pkgRoot.path),
          throwsA(isA<BareKitPinException>()));
    });

    test('readBareKitGradlePin throws when bareKitSha256 is missing', () {
      final tmp =
          Directory.systemTemp.createTempSync('fp_pack_barekit_pin_nosha');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final pkgRoot = Directory('${tmp.path}/flutter_pear')..createSync();
      writeFixtureGradle(pkgRoot.path,
          body: 'def bareKitVersion = "$fixtureVersion"\n');

      expect(() => readBareKitGradlePin(pkgRoot.path),
          throwsA(isA<BareKitPinException>()));
    });

    test(
        'repackBareKit (upload: false) writes a well-shaped pin with a '
        'PENDING-UPLOAD sentinel and never calls uploadFn', () async {
      final tmp =
          Directory.systemTemp.createTempSync('fp_pack_barekit_repack_ok');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final pkgRoot = Directory('${tmp.path}/flutter_pear')..createSync();
      final fixtureZip = await buildFixtureUpstreamZip(tmp);
      final realUpstreamSha =
          sha256Of(await fixtureZip.readAsBytes());
      writeFixtureGradle(pkgRoot.path,
          body: 'def bareKitVersion = "$fixtureVersion"\n'
              'def bareKitSha256 = "$realUpstreamSha"\n');

      var uploadCalled = false;
      final code = await repackBareKit(
        pkgRoot.path,
        upload: false,
        downloadFn: (url, dest) async {
          await fixtureZip.copy(dest.path);
        },
        uploadFn: (version, zip) async {
          uploadCalled = true;
          return 'https://example.invalid/should-never-be-called';
        },
      );

      expect(code, 0);
      expect(uploadCalled, isFalse);

      final pinFile =
          File('${pkgRoot.path}/../flutter_pear_bare/barekit-pin.json');
      expect(pinFile.existsSync(), isTrue);
      final pin = jsonDecode(pinFile.readAsStringSync()) as Map;
      expect(pin.keys.toSet(), {
        'bareKitVersion',
        'upstreamUrl',
        'upstreamSha256',
        'repackedUrl',
        'repackedSha256',
        'generatedBy',
      });
      expect(pin['bareKitVersion'], fixtureVersion);
      expect(Uri.parse(pin['upstreamUrl'] as String).isScheme('HTTPS'), isTrue);
      expect(pin['upstreamSha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(pin['repackedSha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect((pin['repackedUrl'] as String).startsWith('PENDING-UPLOAD'), isTrue);
    });

    test(
        'repackBareKit produces the SAME repackedSha256 across two separate '
        'runs against byte-identical upstream content (flutter_pear-2nd '
        'regression -- the rezip step used to bake in each run\'s own '
        'fresh-extraction mtimes/extended attributes, producing a '
        'different checksum every time even though the BareKit bytes '
        'never changed)', () async {
      // A richer fixture than buildFixtureUpstreamZip's single-file one --
      // multiple slice directories, each with a binary-ish file and its
      // own Info.plist, closer to a real xcframework's shape and more
      // likely to expose an entry-ORDER-dependent non-determinism too
      // (not just mtimes), since zip archives entries in whatever order
      // it encounters them on disk.
      Future<File> buildRicherFixtureUpstreamZip(Directory parent) async {
        final xcfwDir = Directory('${parent.path}/apple/BareKit.xcframework')
          ..createSync(recursive: true);
        File('${xcfwDir.path}/Info.plist').writeAsStringSync('<plist/>');
        for (final host in iosAddonHosts) {
          final hostDir = Directory('${xcfwDir.path}/$host/BareKit.framework')
            ..createSync(recursive: true);
          File('${hostDir.path}/BareKit')
              .writeAsBytesSync(List.generate(200, (i) => i % 256));
          File('${hostDir.path}/Info.plist').writeAsStringSync('<plist/>');
        }
        final zip = File('${parent.path}/prebuilds.zip');
        final result = await Process.run(
          'zip',
          ['-qr', zip.path, 'apple'],
          workingDirectory: parent.path,
        );
        expect(result.exitCode, 0,
            reason: 'fixture zip creation: ${result.stderr}');
        return zip;
      }

      final tmp =
          Directory.systemTemp.createTempSync('fp_pack_barekit_determinism');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final fixtureZip = await buildRicherFixtureUpstreamZip(tmp);
      final realUpstreamSha = sha256Of(await fixtureZip.readAsBytes());

      Future<String> repackOnceAndReadChecksum(String label) async {
        final pkgRoot =
            Directory('${tmp.path}/flutter_pear_$label')..createSync();
        writeFixtureGradle(pkgRoot.path,
            body: 'def bareKitVersion = "$fixtureVersion"\n'
                'def bareKitSha256 = "$realUpstreamSha"\n');
        final code = await repackBareKit(
          pkgRoot.path,
          upload: false,
          downloadFn: (url, dest) async {
            // A FRESH copy each call (not the same File object) -- mirrors
            // a real, separate download producing its own fresh mtimes,
            // the actual condition that exposed this bug originally.
            await fixtureZip.copy(dest.path);
          },
          uploadFn: (version, zip) async =>
              'https://example.invalid/should-never-be-called',
        );
        expect(code, 0);
        final pin = jsonDecode(File(
                '${pkgRoot.path}/../flutter_pear_bare/barekit-pin.json')
            .readAsStringSync()) as Map;
        return pin['repackedSha256'] as String;
      }

      final firstChecksum = await repackOnceAndReadChecksum('run1');
      // A real gap between runs -- the original bug was mtime-dependent,
      // so two repacks that happen to land in the same filesystem second
      // would be a weaker, potentially-flaky proof than a real gap.
      await Future<void>.delayed(const Duration(seconds: 2));
      final secondChecksum = await repackOnceAndReadChecksum('run2');

      expect(secondChecksum, firstChecksum,
          reason: 'byte-identical upstream content repacked twice, 2 '
              'seconds apart, must produce the SAME repacked zip checksum');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test(
        'repackBareKit aborts nonzero on an upstream checksum mismatch, '
        'before ever calling uploadFn', () async {
      final tmp = Directory.systemTemp
          .createTempSync('fp_pack_barekit_repack_mismatch');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final pkgRoot = Directory('${tmp.path}/flutter_pear')..createSync();
      final fixtureZip = await buildFixtureUpstreamZip(tmp);
      // Deliberately WRONG -- does not match fixtureZip's real checksum.
      writeFixtureGradle(pkgRoot.path,
          body: 'def bareKitVersion = "$fixtureVersion"\n'
              'def bareKitSha256 = "$fixtureUpstreamSha"\n');

      var uploadCalled = false;
      final code = await repackBareKit(
        pkgRoot.path,
        downloadFn: (url, dest) async {
          await fixtureZip.copy(dest.path);
        },
        uploadFn: (version, zip) async {
          uploadCalled = true;
          return 'https://example.invalid/should-never-be-called';
        },
      );

      expect(code, isNot(0));
      expect(uploadCalled, isFalse);
      expect(
          File('${pkgRoot.path}/../flutter_pear_bare/barekit-pin.json')
              .existsSync(),
          isFalse,
          reason: 'a checksum mismatch must never write a pin file');
    });

    test(
        'a plain re-run (upload enabled, not forced) refuses to silently '
        'publish when the existing pin is still PENDING-UPLOAD from an '
        'earlier --no-upload run -- regression for a real incident during '
        'this feature\'s own development', () async {
      final tmp = Directory.systemTemp
          .createTempSync('fp_pack_barekit_repack_pending_guard');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final pkgRoot = Directory('${tmp.path}/flutter_pear')..createSync();
      final fixtureZip = await buildFixtureUpstreamZip(tmp);
      final realUpstreamSha = sha256Of(await fixtureZip.readAsBytes());
      writeFixtureGradle(pkgRoot.path,
          body: 'def bareKitVersion = "$fixtureVersion"\n'
              'def bareKitSha256 = "$realUpstreamSha"\n');

      // First run, --no-upload equivalent -- writes a PENDING-UPLOAD pin,
      // exactly what happened for real in flutter_pear-ovt.2.3.
      final firstCode = await repackBareKit(
        pkgRoot.path,
        upload: false,
        downloadFn: (url, dest) async => fixtureZip.copy(dest.path),
        uploadFn: (version, zip) async =>
            'https://example.invalid/should-never-be-called',
      );
      expect(firstCode, 0);

      // A later PLAIN re-run (upload: true, the real default; force: false,
      // the real default) must refuse to silently escalate into a real
      // upload just because the sentinel URL fails the idempotence check's
      // HEAD probe -- it must fail loud instead, never calling uploadFn.
      var uploadCalled = false;
      final secondCode = await repackBareKit(
        pkgRoot.path,
        downloadFn: (url, dest) async => fixtureZip.copy(dest.path),
        uploadFn: (version, zip) async {
          uploadCalled = true;
          return 'https://example.invalid/should-never-be-called';
        },
      );

      expect(secondCode, isNot(0));
      expect(uploadCalled, isFalse,
          reason: 'must never silently call uploadFn for a PENDING-UPLOAD '
              'pin without an explicit --repack-barekit (force: true)');
    });
  });

  group('Package.swift generation (flutter_pear-ovt.2.4, 3.5)', () {
    Directory buildFixturePkgRoot({
      Map<String, String>? pin,
      List<String> addonDirNames = const ['sodium-native.5.1.0.xcframework', 'udx-native.1.20.7.xcframework'],
    }) {
      final tmp = Directory.systemTemp.createTempSync('fp_pack_swift_gen');
      final pkgRoot = Directory('${tmp.path}/flutter_pear')..createSync();
      final bareRoot = Directory('${tmp.path}/flutter_pear_bare')..createSync();
      if (pin != null) {
        File('${bareRoot.path}/barekit-pin.json').writeAsStringSync(jsonEncode(pin));
      }
      final addonsDir = Directory('${bareRoot.path}/ios/addons')..createSync(recursive: true);
      for (final name in addonDirNames) {
        Directory('${addonsDir.path}/$name').createSync(recursive: true);
      }
      return pkgRoot;
    }

    Map<String, String> fixturePin({String url = 'https://example.invalid/BareKit.xcframework.zip'}) => {
          'bareKitVersion': '2.3.0',
          'upstreamUrl': 'https://github.com/holepunchto/bare-kit/releases/download/v2.3.0/prebuilds.zip',
          'upstreamSha256': 'a386063fa405b0bb4967490e84745075f007f95359c9871c5b7a45c18c2f49e2',
          'repackedUrl': url,
          'repackedSha256': 'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210'
              .substring(0, 64),
          'generatedBy': 'test fixture',
        };

    test(
        'a fixture pin + fake addon dirs produce a manifest with every '
        'target name, the pinned checksum, the FLUTTER_PEAR_BAREKIT_URL '
        'lookup, and the do-not-edit header', () async {
      final pkgRoot = buildFixturePkgRoot(pin: fixturePin());
      addTearDown(() => pkgRoot.parent.deleteSync(recursive: true));

      expect(await generatePackageSwift(pkgRoot.path), 0);

      final manifest =
          File('${pkgRoot.path}/../flutter_pear_bare/$packageSwiftRelativePath')
              .readAsStringSync();
      expect(manifest, contains('DO NOT EDIT BY HAND'));
      expect(manifest, contains('FLUTTER_PEAR_BAREKIT_URL'));
      expect(manifest, contains('https://example.invalid/BareKit.xcframework.zip'));
      expect(manifest, contains(fixturePin()['repackedSha256']!));
      expect(manifest, contains('"BareKit"'));
      expect(manifest, contains('"AddonSodiumNative"'));
      expect(manifest, contains('addons/sodium-native.5.1.0.xcframework'));
      expect(manifest, contains('"AddonUdxNative"'));
      expect(manifest, contains('addons/udx-native.1.20.7.xcframework'));
      // flutter_pear-ovt.3.5: the real Flutter-plugin manifest, not the
      // pack epic's original standalone BareKitShim -- a hyphenated
      // product name (Flutter's own SPM-plugin naming convention), a
      // FlutterFramework dependency (what makes `import Flutter` resolve
      // in FlutterPearBarePlugin.swift), and the CBareKit shim target
      // (BareKit.xcframework ships no module map).
      expect(manifest, contains('name: "flutter_pear_bare"'));
      expect(manifest, contains('.library(name: "flutter-pear-bare"'));
      expect(manifest, contains('.package(name: "FlutterFramework"'));
      expect(manifest, contains('name: "CBareKit"'));
      expect(manifest, contains('publicHeadersPath: "include"'));
    });

    test('fails (nonzero, writes nothing) when barekit-pin.json is missing',
        () async {
      final pkgRoot = buildFixturePkgRoot(pin: null);
      addTearDown(() => pkgRoot.parent.deleteSync(recursive: true));

      expect(await generatePackageSwift(pkgRoot.path), isNot(0));
      expect(
          File('${pkgRoot.path}/../flutter_pear_bare/$packageSwiftRelativePath')
              .existsSync(),
          isFalse);
    });

    test('fails (nonzero, writes nothing) when ios/addons has no '
        'xcframeworks', () async {
      final pkgRoot = buildFixturePkgRoot(pin: fixturePin(), addonDirNames: const []);
      addTearDown(() => pkgRoot.parent.deleteSync(recursive: true));

      expect(await generatePackageSwift(pkgRoot.path), isNot(0));
      expect(
          File('${pkgRoot.path}/../flutter_pear_bare/$packageSwiftRelativePath')
              .existsSync(),
          isFalse);
    });

    test('two runs on identical inputs produce a byte-identical manifest '
        '(addons sorted by name)', () async {
      final pkgRoot = buildFixturePkgRoot(
        pin: fixturePin(),
        addonDirNames: const [
          'udx-native.1.20.7.xcframework',
          'sodium-native.5.1.0.xcframework',
        ],
      );
      addTearDown(() => pkgRoot.parent.deleteSync(recursive: true));

      expect(await generatePackageSwift(pkgRoot.path), 0);
      final manifestFile =
          File('${pkgRoot.path}/../flutter_pear_bare/$packageSwiftRelativePath');
      final first = manifestFile.readAsStringSync();

      expect(await generatePackageSwift(pkgRoot.path), 0);
      final second = manifestFile.readAsStringSync();

      expect(first, second);
      // Sorted regardless of the addon directories' creation order above.
      expect(first.indexOf('AddonSodiumNative'),
          lessThan(first.indexOf('AddonUdxNative')));
    });

    test('addonTargetName derives a Swift-identifier-safe PascalCase name '
        'from a kebab-case, versioned xcframework directory name', () {
      expect(addonTargetName('sodium-native.5.1.0.xcframework'), 'AddonSodiumNative');
      expect(addonTargetName('bare-fs.4.7.3.xcframework'), 'AddonBareFs');
      expect(addonTargetName('udx-native.1.20.7.xcframework'), 'AddonUdxNative');
    });
  });
}

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();
