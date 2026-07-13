import 'dart:convert';
import 'dart:io';

import 'package:flutter_pear/src/doctor_ios_checks.dart'
    show DoctorCheckStatus, ProcessRunner;
import 'package:flutter_pear/src/doctor_macos_checks.dart';
import 'package:flutter_test/flutter_test.dart';

/// A canned [ProcessResult] for a successful command.
ProcessResult _ok(String stdout, {int exitCode = 0}) =>
    ProcessResult(0, exitCode, stdout, '');

const _validEntitlements = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<false/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
''';

const _sandboxedEntitlements = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
</dict>
</plist>
''';

void main() {
  late Directory root;
  late String consumerRoot;
  late String flutterPearRoot;
  late String bareRoot;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fp_doctor_macos');
    consumerRoot = '${root.path}/consumer';
    flutterPearRoot = '${root.path}/flutter_pear';
    bareRoot = '${root.path}/bare';
    Directory('$consumerRoot/macos/Runner').createSync(recursive: true);
    Directory('$consumerRoot/macos/Runner.xcodeproj')
        .createSync(recursive: true);
    Directory('$flutterPearRoot/assets/desktop/darwin-arm64')
        .createSync(recursive: true);
    Directory('$flutterPearRoot/assets/desktop/darwin-x64')
        .createSync(recursive: true);
    File('$flutterPearRoot/assets/desktop/darwin-arm64/pear-end.bundle')
        .writeAsBytesSync([1, 2, 3]);
    File('$flutterPearRoot/assets/desktop/darwin-x64/pear-end.bundle')
        .writeAsBytesSync([1, 2, 3]);
    Directory('$bareRoot/macos/flutter_pear_bare').createSync(recursive: true);

    File('$consumerRoot/macos/Runner/Info.plist').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Test app uses the local network.</string>
</dict>
</plist>
''');
    File('$consumerRoot/macos/Runner/DebugProfile.entitlements')
        .writeAsStringSync(_validEntitlements);
    File('$consumerRoot/macos/Runner/Release.entitlements')
        .writeAsStringSync(_validEntitlements);
    File('$consumerRoot/macos/Runner.xcodeproj/project.pbxproj')
        .writeAsStringSync('''
				MACOSX_DEPLOYMENT_TARGET = 10.15.4;
''');
    File('$bareRoot/macos/flutter_pear_bare/Package.swift')
        .writeAsStringSync('''
// swift-tools-version: 5.9
let package = Package(
    name: "flutter_pear_bare",
    platforms: [
        .macOS("10.15.4")
    ]
)
''');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> passingProcessRunner(
      String executable, List<String> args) async {
    if (executable == 'xcodebuild') {
      return _ok('Xcode 26.6\nBuild version 17F113');
    }
    if (executable == 'flutter') {
      return _ok(jsonEncode({'frameworkVersion': '3.44.4'}));
    }
    if (executable == 'bare') {
      return _ok('1.16.0');
    }
    throw StateError('unexpected executable: $executable');
  }

  DoctorMacosContext buildContext({
    bool isMacOs = true,
    ProcessRunner? processRunner,
  }) =>
      DoctorMacosContext(
        consumerRoot: consumerRoot,
        flutterPearRoot: flutterPearRoot,
        flutterPearBareRoot: bareRoot,
        isMacOs: isMacOs,
        processRunner: processRunner ?? passingProcessRunner,
      );

  group('runDoctorMacosChecks gating', () {
    test('non-macOS yields a single "macOS: not applicable" skip, no other '
        'checks run', () async {
      final results =
          await runDoctorMacosChecks(buildContext(isMacOs: false));
      expect(results, hasLength(1));
      expect(results.single.status, DoctorCheckStatus.skip);
      expect(results.single.message, contains('macOS: not applicable'));
      expect(results.single.message, contains('not on macOS'));
    });

    test('a project with no macos/ directory yields a single "macOS: not '
        'applicable" skip', () async {
      Directory('$consumerRoot/macos').deleteSync(recursive: true);
      final results = await runDoctorMacosChecks(buildContext());
      expect(results, hasLength(1));
      expect(results.single.status, DoctorCheckStatus.skip);
      expect(results.single.message, contains('no macos/ directory'));
    });
  });

  group('a fully self-consistent fixture', () {
    test('every check passes or is informational, none fail', () async {
      final results = await runDoctorMacosChecks(buildContext());
      final fails =
          results.where((r) => r.status == DoctorCheckStatus.fail).toList();
      expect(fails, isEmpty, reason: fails.map((f) => f.render()).join('\n'));
      expect(results.any((r) => r.status == DoctorCheckStatus.pass), isTrue);
    });
  });

  group('Xcode presence', () {
    test('Xcode not found FAILs', () async {
      final results = await runDoctorMacosChecks(buildContext(
        processRunner: (exe, args) async {
          if (exe == 'xcodebuild') throw const ProcessException('xcodebuild', []);
          return passingProcessRunner(exe, args);
        },
      ));
      final xcodeResult =
          results.firstWhere((r) => r.message.contains('Xcode'));
      expect(xcodeResult.status, DoctorCheckStatus.fail);
    });

    test('below minimum version FAILs', () async {
      final results = await runDoctorMacosChecks(buildContext(
        processRunner: (exe, args) async {
          if (exe == 'xcodebuild') return _ok('Xcode 14.2\nBuild version x');
          return passingProcessRunner(exe, args);
        },
      ));
      final xcodeResult =
          results.firstWhere((r) => r.message.contains('Xcode 14.2'));
      expect(xcodeResult.status, DoctorCheckStatus.fail);
      expect(xcodeResult.remediation, contains('Update Xcode'));
    });
  });

  group('Info.plist NSLocalNetworkUsageDescription', () {
    test('missing the key FAILs naming it, with the copy-paste block as '
        'remediation', () async {
      File('$consumerRoot/macos/Runner/Info.plist').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
''');
      final results = await runDoctorMacosChecks(buildContext());
      final plistResult = results.firstWhere((r) =>
          r.message.contains('Info.plist') &&
          r.message.contains('NSLocalNetworkUsageDescription'));
      expect(plistResult.status, DoctorCheckStatus.fail);
      expect(
          plistResult.remediation, contains('NSLocalNetworkUsageDescription'));
      expect(plistResult.remediation, isNot(contains(':pack')));
    });

    test('no macos/Runner/Info.plist at all SKIPs rather than FAILs',
        () async {
      File('$consumerRoot/macos/Runner/Info.plist').deleteSync();
      final results = await runDoctorMacosChecks(buildContext());
      final plistResult =
          results.firstWhere((r) => r.message.contains('Info.plist'));
      expect(plistResult.status, DoctorCheckStatus.skip);
    });

    test('present passes', () async {
      final results = await runDoctorMacosChecks(buildContext());
      final plistResult = results.firstWhere((r) =>
          r.message.contains('Info.plist') &&
          r.message.contains('NSLocalNetworkUsageDescription'));
      expect(plistResult.status, DoctorCheckStatus.pass);
    });
  });

  group('App Sandbox entitlement', () {
    test('sandboxed (true) FAILs both Debug and Release, naming the exact '
        'fix', () async {
      File('$consumerRoot/macos/Runner/DebugProfile.entitlements')
          .writeAsStringSync(_sandboxedEntitlements);
      File('$consumerRoot/macos/Runner/Release.entitlements')
          .writeAsStringSync(_sandboxedEntitlements);
      final results = await runDoctorMacosChecks(buildContext());
      final debugResult = results.firstWhere(
          (r) => r.message.contains('DebugProfile.entitlements'));
      final releaseResult = results
          .firstWhere((r) => r.message.contains('Release.entitlements'));
      expect(debugResult.status, DoctorCheckStatus.fail);
      expect(releaseResult.status, DoctorCheckStatus.fail);
      expect(debugResult.remediation, contains('app-sandbox'));
      expect(debugResult.remediation, contains('bare'));
    });

    test('Debug fixed but Release still sandboxed -- Release alone FAILs '
        '(catches a half-fixed project)', () async {
      File('$consumerRoot/macos/Runner/Release.entitlements')
          .writeAsStringSync(_sandboxedEntitlements);
      final results = await runDoctorMacosChecks(buildContext());
      final debugResult = results.firstWhere(
          (r) => r.message.contains('DebugProfile.entitlements'));
      final releaseResult = results
          .firstWhere((r) => r.message.contains('Release.entitlements'));
      expect(debugResult.status, DoctorCheckStatus.pass);
      expect(releaseResult.status, DoctorCheckStatus.fail);
    });

    test('not sandboxed (false) passes', () async {
      final results = await runDoctorMacosChecks(buildContext());
      final debugResult = results.firstWhere(
          (r) => r.message.contains('DebugProfile.entitlements'));
      expect(debugResult.status, DoctorCheckStatus.pass);
    });

    test('missing entitlements file SKIPs rather than FAILs', () async {
      File('$consumerRoot/macos/Runner/DebugProfile.entitlements')
          .deleteSync();
      final results = await runDoctorMacosChecks(buildContext());
      final debugResult = results.firstWhere(
          (r) => r.message.contains('DebugProfile.entitlements'));
      expect(debugResult.status, DoctorCheckStatus.skip);
    });

    test('a file present but with no app-sandbox key SKIPs rather than '
        'guessing', () async {
      File('$consumerRoot/macos/Runner/DebugProfile.entitlements')
          .writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
''');
      final results = await runDoctorMacosChecks(buildContext());
      final debugResult = results.firstWhere(
          (r) => r.message.contains('DebugProfile.entitlements'));
      expect(debugResult.status, DoctorCheckStatus.skip);
    });
  });

  group('committed desktop bundle', () {
    test('present for every host passes', () async {
      final results = await runDoctorMacosChecks(buildContext());
      final bundleResult =
          results.firstWhere((r) => r.message.contains('pear-end.bundle'));
      expect(bundleResult.status, DoctorCheckStatus.pass);
    });

    test('missing for one host FAILs naming it, remediation never mentions '
        ':pack', () async {
      File('$flutterPearRoot/assets/desktop/darwin-x64/pear-end.bundle')
          .deleteSync();
      final results = await runDoctorMacosChecks(buildContext());
      final bundleResult =
          results.firstWhere((r) => r.message.contains('pear-end.bundle'));
      expect(bundleResult.status, DoctorCheckStatus.fail);
      expect(bundleResult.message, contains('darwin-x64'));
      expect(bundleResult.remediation, isNot(contains(':pack')));
    });

    test('an empty bundle file FAILs (not just existence-checked)', () async {
      File('$flutterPearRoot/assets/desktop/darwin-arm64/pear-end.bundle')
          .writeAsBytesSync([]);
      final results = await runDoctorMacosChecks(buildContext());
      final bundleResult =
          results.firstWhere((r) => r.message.contains('pear-end.bundle'));
      expect(bundleResult.status, DoctorCheckStatus.fail);
      expect(bundleResult.message, contains('darwin-arm64'));
    });
  });

  group('deployment target', () {
    test('below the Package.swift-pinned minimum FAILs', () async {
      File('$consumerRoot/macos/Runner.xcodeproj/project.pbxproj')
          .writeAsStringSync('MACOSX_DEPLOYMENT_TARGET = 10.13;\n');
      final results = await runDoctorMacosChecks(buildContext());
      final targetResult = results
          .firstWhere((r) => r.message.contains('deployment target'));
      expect(targetResult.status, DoctorCheckStatus.fail);
      expect(targetResult.remediation, contains('10.15.4'));
    });

    test('at the minimum passes', () async {
      final results = await runDoctorMacosChecks(buildContext());
      final targetResult = results
          .firstWhere((r) => r.message.contains('deployment target'));
      expect(targetResult.status, DoctorCheckStatus.pass);
    });

    test(
        '3-component minimum (10.15.4) correctly FAILs a project target '
        'one patch below it (10.15.3 < 10.15.4) -- a plain double can\'t '
        'even represent "10.15.4" (two decimal points), so this pins the '
        'fix for flutter_pear-a4p\'s deployment-target bump', () async {
      File('$consumerRoot/macos/Runner.xcodeproj/project.pbxproj')
          .writeAsStringSync('MACOSX_DEPLOYMENT_TARGET = 10.15.3;\n');
      final results = await runDoctorMacosChecks(buildContext());
      final targetResult = results
          .firstWhere((r) => r.message.contains('deployment target'));
      expect(targetResult.status, DoctorCheckStatus.fail);
      expect(targetResult.remediation, contains('10.15.4'));
    });

    test(
        '3-component project target above the minimum (10.15.5 > 10.15.4) '
        'passes', () async {
      File('$consumerRoot/macos/Runner.xcodeproj/project.pbxproj')
          .writeAsStringSync('MACOSX_DEPLOYMENT_TARGET = 10.15.5;\n');
      final results = await runDoctorMacosChecks(buildContext());
      final targetResult = results
          .firstWhere((r) => r.message.contains('deployment target'));
      expect(targetResult.status, DoctorCheckStatus.pass);
    });

    test('missing project.pbxproj SKIPs', () async {
      Directory('$consumerRoot/macos/Runner.xcodeproj')
          .deleteSync(recursive: true);
      final results = await runDoctorMacosChecks(buildContext());
      final targetResult = results
          .firstWhere((r) => r.message.contains('project.pbxproj'));
      expect(targetResult.status, DoctorCheckStatus.skip);
    });
  });

  group('packaging path + Flutter version', () {
    test('SwiftPM path detected when no macos/Podfile', () async {
      final results = await runDoctorMacosChecks(buildContext());
      final pathResult =
          results.firstWhere((r) => r.message.contains('SwiftPM path'));
      expect(pathResult.status, DoctorCheckStatus.info);
    });

    test('CocoaPods compat path detected when macos/Podfile exists',
        () async {
      File('$consumerRoot/macos/Podfile').writeAsStringSync('');
      final results = await runDoctorMacosChecks(buildContext());
      final pathResult = results
          .firstWhere((r) => r.message.contains('CocoaPods compat path'));
      expect(pathResult.status, DoctorCheckStatus.info);
    });

    test('a too-old Flutter on the SwiftPM path FAILs', () async {
      final results = await runDoctorMacosChecks(buildContext(
        processRunner: (exe, args) async {
          if (exe == 'flutter') {
            return _ok(jsonEncode({'frameworkVersion': '3.10.0'}));
          }
          return passingProcessRunner(exe, args);
        },
      ));
      final versionResult =
          results.firstWhere((r) => r.message.contains('3.10.0'));
      expect(versionResult.status, DoctorCheckStatus.fail);
      expect(versionResult.remediation, contains('macos/Podfile'));
    });

    test('the same too-old Flutter on the CocoaPods path passes (SwiftPM '
        'minimum does not apply)', () async {
      File('$consumerRoot/macos/Podfile').writeAsStringSync('');
      final results = await runDoctorMacosChecks(buildContext(
        processRunner: (exe, args) async {
          if (exe == 'flutter') {
            return _ok(jsonEncode({'frameworkVersion': '3.10.0'}));
          }
          return passingProcessRunner(exe, args);
        },
      ));
      final versionResult =
          results.firstWhere((r) => r.message.contains('3.10.0'));
      expect(versionResult.status, DoctorCheckStatus.pass);
    });
  });

  group('bare runtime (flutter_pear-bhv)', () {
    test('bare not found on PATH -> a FAIL naming npm i -g bare, not a '
        'silently-passing SKIP', () async {
      final results = await runDoctorMacosChecks(buildContext(
        processRunner: (exe, args) async {
          if (exe == 'bare') throw const ProcessException('bare', []);
          return passingProcessRunner(exe, args);
        },
      ));
      final bareResult =
          results.firstWhere((r) => r.message.contains('bare'));
      expect(bareResult.status, DoctorCheckStatus.fail);
      expect(bareResult.remediation, contains('npm i -g bare'));
      expect(bareResult.remediation, contains('BARE_RUNTIME_MISSING'));
    });

    test('bare --version exits nonzero -> a FAIL', () async {
      final results = await runDoctorMacosChecks(buildContext(
        processRunner: (exe, args) async {
          if (exe == 'bare') return _ok('', exitCode: 1);
          return passingProcessRunner(exe, args);
        },
      ));
      final bareResult =
          results.firstWhere((r) => r.message.contains('bare --version'));
      expect(bareResult.status, DoctorCheckStatus.fail);
    });

    test('bare present passes', () async {
      final results = await runDoctorMacosChecks(buildContext());
      final bareResult =
          results.firstWhere((r) => r.message.contains("'bare' runtime"));
      expect(bareResult.status, DoctorCheckStatus.pass);
    });
  });

  group('applyMacosFixes (--fix, flutter_pear-jxf)', () {
    test(
        'sandboxed (true) entitlements FIXED to false in BOTH files, one '
        'change line per file, Info.plist untouched (setUp fixture already '
        'has NSLocalNetworkUsageDescription)', () {
      File('$consumerRoot/macos/Runner/DebugProfile.entitlements')
          .writeAsStringSync(_sandboxedEntitlements);
      File('$consumerRoot/macos/Runner/Release.entitlements')
          .writeAsStringSync(_sandboxedEntitlements);

      final changes = applyMacosFixes(consumerRoot);

      expect(changes, hasLength(2));
      expect(changes.any((c) => c.contains('DebugProfile.entitlements')),
          isTrue);
      expect(changes.any((c) => c.contains('Release.entitlements')), isTrue);
    });

    test('already-correct project (setUp fixture) -> no changes at all '
        '(idempotent)', () {
      final changes = applyMacosFixes(consumerRoot);
      expect(changes, isEmpty);
    });

    test(
        'sandboxed entitlements: after fixing, the file actually reads '
        'app-sandbox=false, and re-running reports no further change',
        () {
      File('$consumerRoot/macos/Runner/DebugProfile.entitlements')
          .writeAsStringSync(_sandboxedEntitlements);

      final firstRun = applyMacosFixes(consumerRoot);
      expect(
          firstRun,
          contains(contains(
              'DebugProfile.entitlements: set com.apple.security.app-sandbox to false')));

      final fixedText = File('$consumerRoot/macos/Runner/DebugProfile.entitlements')
          .readAsStringSync();
      expect(
          RegExp(r'<key>com\.apple\.security\.app-sandbox</key>\s*<false\s*/>')
              .hasMatch(fixedText),
          isTrue);
      // The key must appear exactly once -- a buggy insert-instead-of-
      // replace would leave the old <true/> pair AND add a new <false/> one.
      expect('com.apple.security.app-sandbox'.allMatches(fixedText).length, 1);

      final secondRun = applyMacosFixes(consumerRoot);
      expect(
          secondRun.where((c) => c.contains('DebugProfile.entitlements')),
          isEmpty);
    });

    test(
        'entitlements file with the app-sandbox key entirely ABSENT gets '
        'it inserted as false, producing well-formed XML', () {
      const noSandboxKey = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
''';
      File('$consumerRoot/macos/Runner/DebugProfile.entitlements')
          .writeAsStringSync(noSandboxKey);

      final changes = applyMacosFixes(consumerRoot);

      expect(
          changes,
          contains(contains(
              'DebugProfile.entitlements: added com.apple.security.app-sandbox = false')));
      final fixedText = File('$consumerRoot/macos/Runner/DebugProfile.entitlements')
          .readAsStringSync();
      expect(
          RegExp(r'<key>com\.apple\.security\.app-sandbox</key>\s*<false\s*/>')
              .hasMatch(fixedText),
          isTrue);
      expect(fixedText, contains('com.apple.security.network.client'),
          reason: 'the pre-existing key must survive the insertion');
    });

    test('Info.plist missing NSLocalNetworkUsageDescription gets it added',
        () {
      File('$consumerRoot/macos/Runner/Info.plist').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
''');

      final changes = applyMacosFixes(consumerRoot);

      expect(
          changes,
          contains(contains(
              'Info.plist: added NSLocalNetworkUsageDescription')));
      final fixedText =
          File('$consumerRoot/macos/Runner/Info.plist').readAsStringSync();
      expect(fixedText, contains('NSLocalNetworkUsageDescription'));
      expect(fixedText, contains('NSPrincipalClass'),
          reason: 'the pre-existing key must survive the insertion');
    });

    test('Info.plist already has the key -> not touched, not reported',
        () {
      final before =
          File('$consumerRoot/macos/Runner/Info.plist').readAsStringSync();
      final changes = applyMacosFixes(consumerRoot);
      expect(changes.where((c) => c.contains('Info.plist')), isEmpty);
      expect(File('$consumerRoot/macos/Runner/Info.plist').readAsStringSync(),
          before);
    });

    test('missing files entirely (no macos/ dir) -> returns empty, does '
        'not throw', () {
      Directory('$consumerRoot/macos').deleteSync(recursive: true);
      expect(applyMacosFixes(consumerRoot), isEmpty);
    });

    test(
        'a below-minimum MACOSX_DEPLOYMENT_TARGET is raised to the pinned '
        'minimum (found via /devex-review dogfooding a real fresh-project '
        'build -- a below-minimum target fails the BUILD itself, not just '
        'a doctor check, with a raw non-flutter_pear-branded SwiftPM '
        'error)', () {
      File('$consumerRoot/macos/Runner.xcodeproj/project.pbxproj')
          .writeAsStringSync('MACOSX_DEPLOYMENT_TARGET = 10.15;\n');

      final changes = applyMacosFixes(consumerRoot);

      expect(
          changes,
          contains(contains('raised 1 MACOSX_DEPLOYMENT_TARGET setting to '
              '10.15.4')));
      final fixedText =
          File('$consumerRoot/macos/Runner.xcodeproj/project.pbxproj')
              .readAsStringSync();
      expect(fixedText, contains('MACOSX_DEPLOYMENT_TARGET = 10.15.4;'));
    });

    test(
        'a real project.pbxproj with 3 build configurations (Debug/'
        'Release/Profile) gets all 3 below-minimum lines raised in one '
        'pass, plural in the change message', () {
      File('$consumerRoot/macos/Runner.xcodeproj/project.pbxproj')
          .writeAsStringSync('''
				MACOSX_DEPLOYMENT_TARGET = 10.15;
				MACOSX_DEPLOYMENT_TARGET = 10.15;
				MACOSX_DEPLOYMENT_TARGET = 10.15;
''');

      final changes = applyMacosFixes(consumerRoot);

      expect(
          changes,
          contains(contains('raised 3 MACOSX_DEPLOYMENT_TARGET settings to '
              '10.15.4')));
      final fixedText =
          File('$consumerRoot/macos/Runner.xcodeproj/project.pbxproj')
              .readAsStringSync();
      expect('MACOSX_DEPLOYMENT_TARGET = 10.15.4;'.allMatches(fixedText).length,
          3);
    });

    test(
        'an already-at-minimum project.pbxproj (setUp fixture) -> not '
        'touched, not reported (already covered by the broader '
        'already-correct-project test, pinned again here for this '
        'specific fix)', () {
      final before =
          File('$consumerRoot/macos/Runner.xcodeproj/project.pbxproj')
              .readAsStringSync();
      final changes = applyMacosFixes(consumerRoot);
      expect(changes.where((c) => c.contains('project.pbxproj')), isEmpty);
      expect(
          File('$consumerRoot/macos/Runner.xcodeproj/project.pbxproj')
              .readAsStringSync(),
          before);
    });
  });

  group('renderDoctorMacosChecks', () {
    test('renders the same [TAG] message format as the iOS checks', () async {
      final results = await runDoctorMacosChecks(buildContext());
      final rendered = renderDoctorMacosChecks(results);
      expect(rendered, contains('[PASS]'));
      expect(rendered.split('\n').length, greaterThanOrEqualTo(results.length));
    });
  });
}
