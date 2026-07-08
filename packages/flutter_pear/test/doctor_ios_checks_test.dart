import 'dart:convert';
import 'dart:io';

import 'package:flutter_pear/src/doctor_ios_checks.dart';
import 'package:flutter_test/flutter_test.dart';

/// A canned [ProcessResult] for a successful command.
ProcessResult _ok(String stdout, {int exitCode = 0}) =>
    ProcessResult(0, exitCode, stdout, '');

void main() {
  late Directory root;
  late String consumerRoot;
  late String bareRoot;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fp_doctor_ios');
    consumerRoot = '${root.path}/consumer';
    bareRoot = '${root.path}/bare';
    Directory('$consumerRoot/ios/Runner').createSync(recursive: true);
    Directory('$consumerRoot/ios/Runner.xcodeproj').createSync(recursive: true);
    Directory('$bareRoot/ios/addons/sodium-native.5.1.0.xcframework')
        .createSync(recursive: true);
    Directory('$bareRoot/ios/flutter_pear_bare').createSync(recursive: true);

    File('$consumerRoot/ios/Runner/Info.plist').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Test app uses the local network.</string>
</dict>
</plist>
''');
    File('$consumerRoot/ios/Runner.xcodeproj/project.pbxproj')
        .writeAsStringSync('''
				IPHONEOS_DEPLOYMENT_TARGET = 13.0;
''');
    File('$bareRoot/barekit-pin.json').writeAsStringSync(jsonEncode({
      'bareKitVersion': '2.3.0',
      'upstreamUrl':
          'https://github.com/holepunchto/bare-kit/releases/download/v2.3.0/prebuilds.zip',
      'upstreamSha256':
          'a386063fa405b0bb4967490e84745075f007f95359c9871c5b7a45c18c2f49e2',
      'repackedUrl':
          'https://github.com/andrewloable/flutter_pear/releases/download/barekit-v2.3.0/BareKit-2.3.0-ios.xcframework.zip',
      'repackedSha256':
          'bb54259f54078cca69f54d868f36b3c2f72c95fcf5bca29db862f695f05a4ba7',
    }));
    File('$bareRoot/ios/flutter_pear_bare/Package.swift').writeAsStringSync('''
// swift-tools-version:5.9
let package = Package(
    name: "flutter_pear_bare",
    platforms: [.iOS(.v13)],
    targets: []
)
''');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> passingProcessRunner(
      String executable, List<String> args) async {
    if (executable == 'xcodebuild') return _ok('Xcode 26.6\nBuild version 17F113');
    if (executable == 'xcrun') {
      return _ok(jsonEncode({
        'runtimes': [
          {'platform': 'iOS', 'isAvailable': true, 'name': 'iOS 26.5'},
        ],
      }));
    }
    if (executable == 'flutter') {
      return _ok(jsonEncode({'frameworkVersion': '3.44.4'}));
    }
    throw StateError('unexpected executable: $executable');
  }

  Future<int> passingHttpHeadChecker(Uri url, Duration timeout) async => 200;

  DoctorIosContext buildContext({
    bool isMacOs = true,
    ProcessRunner? processRunner,
    HttpHeadChecker? httpHeadChecker,
  }) =>
      DoctorIosContext(
        consumerRoot: consumerRoot,
        flutterPearBareRoot: bareRoot,
        isMacOs: isMacOs,
        processRunner: processRunner ?? passingProcessRunner,
        httpHeadChecker: httpHeadChecker ?? passingHttpHeadChecker,
      );

  group('runDoctorIosChecks gating', () {
    test('non-macOS yields a single "iOS: not applicable" skip, no other '
        'checks run', () async {
      final results = await runDoctorIosChecks(buildContext(isMacOs: false));
      expect(results, hasLength(1));
      expect(results.single.status, DoctorCheckStatus.skip);
      expect(results.single.message, contains('iOS: not applicable'));
      expect(results.single.message, contains('not on macOS'));
    });

    test('a project with no ios/ directory yields a single "iOS: not '
        'applicable" skip', () async {
      Directory('$consumerRoot/ios').deleteSync(recursive: true);
      final results = await runDoctorIosChecks(buildContext());
      expect(results, hasLength(1));
      expect(results.single.status, DoctorCheckStatus.skip);
      expect(results.single.message, contains('no ios/ directory'));
    });
  });

  group('a fully self-consistent fixture', () {
    test('every check passes or is informational, none fail', () async {
      final results = await runDoctorIosChecks(buildContext());
      final fails =
          results.where((r) => r.status == DoctorCheckStatus.fail).toList();
      expect(fails, isEmpty,
          reason: fails.map((f) => f.render()).join('\n'));
      expect(results.any((r) => r.status == DoctorCheckStatus.pass), isTrue);
    });
  });

  group('Info.plist NSLocalNetworkUsageDescription', () {
    test('missing the key FAILs naming it, with the copy-paste block as '
        'remediation', () async {
      File('$consumerRoot/ios/Runner/Info.plist').writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>LSRequiresIPhoneOS</key>
	<true/>
</dict>
</plist>
''');
      final results = await runDoctorIosChecks(buildContext());
      final plistResult = results.firstWhere(
          (r) => r.message.contains('Info.plist') && r.message.contains('NSLocalNetworkUsageDescription'));
      expect(plistResult.status, DoctorCheckStatus.fail);
      expect(plistResult.message, contains('NSLocalNetworkUsageDescription'));
      expect(plistResult.remediation, contains('NSLocalNetworkUsageDescription'));
      expect(plistResult.remediation, isNot(contains(':pack')));
    });

    test('no ios/Runner/Info.plist at all SKIPs rather than FAILs', () async {
      File('$consumerRoot/ios/Runner/Info.plist').deleteSync();
      final results = await runDoctorIosChecks(buildContext());
      final plistResult =
          results.firstWhere((r) => r.message.contains('Info.plist'));
      expect(plistResult.status, DoctorCheckStatus.skip);
    });

    test('present passes', () async {
      final results = await runDoctorIosChecks(buildContext());
      final plistResult = results.firstWhere(
          (r) => r.message.contains('Info.plist') && r.message.contains('NSLocalNetworkUsageDescription'));
      expect(plistResult.status, DoctorCheckStatus.pass);
    });
  });

  group('barekit-pin.json integrity', () {
    test('well-formed pin passes', () async {
      final results = await runDoctorIosChecks(buildContext());
      final pinResult =
          results.firstWhere((r) => r.message.contains('barekit-pin.json'));
      expect(pinResult.status, DoctorCheckStatus.pass);
    });

    test('a malformed checksum FAILs naming the field, remediation never '
        'mentions :pack', () async {
      File('$bareRoot/barekit-pin.json').writeAsStringSync(jsonEncode({
        'bareKitVersion': '2.3.0',
        'upstreamUrl':
            'https://github.com/holepunchto/bare-kit/releases/download/v2.3.0/prebuilds.zip',
        'upstreamSha256': 'not-a-real-checksum',
        'repackedUrl':
            'https://github.com/andrewloable/flutter_pear/releases/download/barekit-v2.3.0/BareKit-2.3.0-ios.xcframework.zip',
        'repackedSha256':
            'bb54259f54078cca69f54d868f36b3c2f72c95fcf5bca29db862f695f05a4ba7',
      }));
      final results = await runDoctorIosChecks(buildContext());
      final pinResult =
          results.firstWhere((r) => r.message.contains('barekit-pin.json'));
      expect(pinResult.status, DoctorCheckStatus.fail);
      expect(pinResult.message, contains('upstreamSha256'));
      expect(pinResult.remediation, isNot(contains(':pack')));
      expect(pinResult.remediation, contains('GitHub issue'));
    });

    test('a non-https URL FAILs naming the field', () async {
      File('$bareRoot/barekit-pin.json').writeAsStringSync(jsonEncode({
        'bareKitVersion': '2.3.0',
        'upstreamUrl': 'http://example.com/insecure.zip',
        'upstreamSha256':
            'a386063fa405b0bb4967490e84745075f007f95359c9871c5b7a45c18c2f49e2',
        'repackedUrl':
            'https://github.com/andrewloable/flutter_pear/releases/download/barekit-v2.3.0/BareKit-2.3.0-ios.xcframework.zip',
        'repackedSha256':
            'bb54259f54078cca69f54d868f36b3c2f72c95fcf5bca29db862f695f05a4ba7',
      }));
      final results = await runDoctorIosChecks(buildContext());
      final pinResult =
          results.firstWhere((r) => r.message.contains('barekit-pin.json'));
      expect(pinResult.status, DoctorCheckStatus.fail);
      expect(pinResult.message, contains('upstreamUrl'));
    });

    test('missing entirely FAILs with a maintainer-only remediation, never '
        ':pack', () async {
      File('$bareRoot/barekit-pin.json').deleteSync();
      final results = await runDoctorIosChecks(buildContext());
      final pinResult =
          results.firstWhere((r) => r.message.contains('barekit-pin.json'));
      expect(pinResult.status, DoctorCheckStatus.fail);
      expect(pinResult.remediation, isNot(contains(':pack')));
    });
  });

  group('pin URL reachability', () {
    test('simulated-offline (httpHeadChecker throws) SKIPs, never FAILs',
        () async {
      final results = await runDoctorIosChecks(buildContext(
        httpHeadChecker: (url, timeout) async =>
            throw const SocketException('simulated offline'),
      ));
      final reachabilityResults =
          results.where((r) => r.message.contains('reachable') || r.message.contains('reachability')).toList();
      expect(reachabilityResults, isNotEmpty);
      for (final r in reachabilityResults) {
        expect(r.status, DoctorCheckStatus.skip);
      }
    });

    test('a non-2xx/3xx status FAILs naming the status code', () async {
      final results = await runDoctorIosChecks(buildContext(
        httpHeadChecker: (url, timeout) async => 404,
      ));
      final failed = results.where((r) =>
          r.status == DoctorCheckStatus.fail &&
          r.message.contains('HTTP 404'));
      expect(failed, isNotEmpty);
    });

    test('reachable URLs pass', () async {
      final results = await runDoctorIosChecks(buildContext());
      final reachable = results.where((r) => r.message.contains('reachable ('));
      expect(reachable, hasLength(2)); // upstreamUrl + repackedUrl
      for (final r in reachable) {
        expect(r.status, DoctorCheckStatus.pass);
      }
    });
  });

  group('Xcode presence', () {
    test('not found (ProcessException) FAILs with a consumer remediation',
        () async {
      final results = await runDoctorIosChecks(buildContext(
        processRunner: (executable, args) async {
          if (executable == 'xcodebuild') {
            throw const ProcessException('xcodebuild', []);
          }
          return passingProcessRunner(executable, args);
        },
      ));
      final xcodeResult =
          results.firstWhere((r) => r.message.contains('Xcode'));
      expect(xcodeResult.status, DoctorCheckStatus.fail);
      expect(xcodeResult.remediation, contains('Install Xcode'));
    });

    test('below the minimum version FAILs naming both versions', () async {
      final results = await runDoctorIosChecks(buildContext(
        processRunner: (executable, args) async {
          if (executable == 'xcodebuild') {
            return _ok('Xcode 14.3\nBuild version 14E222b');
          }
          return passingProcessRunner(executable, args);
        },
      ));
      final xcodeResult =
          results.firstWhere((r) => r.message.startsWith('Xcode 14.3'));
      expect(xcodeResult.status, DoctorCheckStatus.fail);
      expect(xcodeResult.message, contains('14.3'));
      expect(xcodeResult.message, contains('>=15.0'));
    });

    test('a sufficient version passes', () async {
      final results = await runDoctorIosChecks(buildContext());
      final xcodeResult = results.firstWhere((r) => r.message.startsWith('Xcode'));
      expect(xcodeResult.status, DoctorCheckStatus.pass);
    });
  });

  group('simulator runtime', () {
    test('none available FAILs', () async {
      final results = await runDoctorIosChecks(buildContext(
        processRunner: (executable, args) async {
          if (executable == 'xcrun') {
            return _ok(jsonEncode({
              'runtimes': [
                {'platform': 'tvOS', 'isAvailable': true, 'name': 'tvOS 26.5'},
              ],
            }));
          }
          return passingProcessRunner(executable, args);
        },
      ));
      final simResult =
          results.firstWhere((r) => r.message.contains('Simulator runtime'));
      expect(simResult.status, DoctorCheckStatus.fail);
    });
  });

  group('packaging path + Flutter version', () {
    test('SwiftPM path with a too-old Flutter FAILs', () async {
      final results = await runDoctorIosChecks(buildContext(
        processRunner: (executable, args) async {
          if (executable == 'flutter') {
            return _ok(jsonEncode({'frameworkVersion': '3.19.0'}));
          }
          return passingProcessRunner(executable, args);
        },
      ));
      final flutterResult =
          results.firstWhere((r) => r.message.contains('Flutter 3.19.0'));
      expect(flutterResult.status, DoctorCheckStatus.fail);
      expect(flutterResult.remediation, contains('flutter upgrade'));
    });

    test('CocoaPods path (ios/Podfile present) is detected and named',
        () async {
      File('$consumerRoot/ios/Podfile').writeAsStringSync('''
platform :ios, '13.0'
''');
      final results = await runDoctorIosChecks(buildContext());
      final pathResult =
          results.firstWhere((r) => r.status == DoctorCheckStatus.info);
      expect(pathResult.message, contains('CocoaPods'));
    });
  });

  group('committed addon xcframeworks', () {
    test('none present FAILs with a maintainer-only remediation', () async {
      Directory('$bareRoot/ios/addons').deleteSync(recursive: true);
      Directory('$bareRoot/ios/addons').createSync(recursive: true);
      final results = await runDoctorIosChecks(buildContext());
      final addonResult =
          results.firstWhere((r) => r.message.contains('xcframework'));
      expect(addonResult.status, DoctorCheckStatus.fail);
      expect(addonResult.remediation, isNot(contains(':pack')));
    });
  });

  group('deployment target', () {
    test('below the plugin minimum FAILs naming both values', () async {
      File('$consumerRoot/ios/Runner.xcodeproj/project.pbxproj')
          .writeAsStringSync('''
				IPHONEOS_DEPLOYMENT_TARGET = 12.0;
''');
      final results = await runDoctorIosChecks(buildContext());
      final deployResult =
          results.firstWhere((r) => r.message.contains('deployment target'));
      expect(deployResult.status, DoctorCheckStatus.fail);
      expect(deployResult.message, contains('12.0'));
      expect(deployResult.message, contains('13.0'));
    });

    test('at or above the minimum passes', () async {
      final results = await runDoctorIosChecks(buildContext());
      final deployResult =
          results.firstWhere((r) => r.message.contains('deployment target'));
      expect(deployResult.status, DoctorCheckStatus.pass);
    });
  });

  test('renderDoctorIosChecks matches the [TAG] message line format', () {
    const results = [
      DoctorCheckResult(DoctorCheckStatus.pass, 'ok'),
      DoctorCheckResult(DoctorCheckStatus.fail, 'bad', remediation: 'fix it'),
      DoctorCheckResult(DoctorCheckStatus.skip, 'n/a'),
      DoctorCheckResult(DoctorCheckStatus.info, 'fyi'),
    ];
    expect(
      renderDoctorIosChecks(results),
      '[PASS] ok\n[FAIL] bad\nfix it\n[SKIP] n/a\n[INFO] fyi',
    );
  });
}
