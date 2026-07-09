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
				MACOSX_DEPLOYMENT_TARGET = 10.15;
''');
    File('$bareRoot/macos/flutter_pear_bare/Package.swift')
        .writeAsStringSync('''
// swift-tools-version: 5.9
let package = Package(
    name: "flutter_pear_bare",
    platforms: [
        .macOS("10.15")
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
      expect(targetResult.remediation, contains('10.15'));
    });

    test('at the minimum passes', () async {
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

  group('renderDoctorMacosChecks', () {
    test('renders the same [TAG] message format as the iOS checks', () async {
      final results = await runDoctorMacosChecks(buildContext());
      final rendered = renderDoctorMacosChecks(results);
      expect(rendered, contains('[PASS]'));
      expect(rendered.split('\n').length, greaterThanOrEqualTo(results.length));
    });
  });
}
