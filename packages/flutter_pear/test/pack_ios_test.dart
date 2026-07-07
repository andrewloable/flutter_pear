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
}

String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();
