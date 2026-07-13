import 'dart:io';

import 'package:flutter_pear/src/doctor_ios_checks.dart'
    show DoctorCheckStatus, ProcessRunner;
import 'package:flutter_pear/src/doctor_windows_checks.dart';
import 'package:flutter_test/flutter_test.dart';

/// A canned [ProcessResult] for a successful command.
ProcessResult _ok(String stdout, {int exitCode = 0}) =>
    ProcessResult(0, exitCode, stdout, '');

void main() {
  late Directory root;
  late String consumerRoot;
  late String flutterPearRoot;
  late String vswherePath;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fp_doctor_windows');
    consumerRoot = '${root.path}/consumer';
    flutterPearRoot = '${root.path}/flutter_pear';
    vswherePath = '${root.path}/vswhere.exe';
    Directory('$consumerRoot/windows').createSync(recursive: true);
    Directory('$flutterPearRoot/assets/desktop/win32-x64')
        .createSync(recursive: true);
    File('$flutterPearRoot/assets/desktop/win32-x64/pear-end.bundle')
        .writeAsBytesSync([1, 2, 3]);
    // The check only needs this file to EXIST (its own existence gates
    // whether vswhere is even invoked) -- content is irrelevant since the
    // fake processRunner below never actually reads it.
    File(vswherePath).writeAsStringSync('');
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> passingProcessRunner(
      String executable, List<String> args) async {
    if (executable == vswherePath) {
      return _ok(r'C:\Program Files\Microsoft Visual Studio\2022\Community');
    }
    if (executable == 'bare') {
      return _ok('1.16.0');
    }
    throw StateError('unexpected executable: $executable');
  }

  DoctorWindowsContext buildContext({
    bool isWindows = true,
    String? vswherePathOverride,
    ProcessRunner? processRunner,
  }) =>
      DoctorWindowsContext(
        consumerRoot: consumerRoot,
        flutterPearRoot: flutterPearRoot,
        isWindows: isWindows,
        vswherePath: vswherePathOverride ?? vswherePath,
        processRunner: processRunner ?? passingProcessRunner,
      );

  group('runDoctorWindowsChecks gating', () {
    test('non-Windows yields a single "Windows: not applicable" skip, no '
        'other checks run', () async {
      final results =
          await runDoctorWindowsChecks(buildContext(isWindows: false));
      expect(results, hasLength(1));
      expect(results.single.status, DoctorCheckStatus.skip);
      expect(results.single.message, contains('Windows: not applicable'));
      expect(results.single.message, contains('not on Windows'));
    });

    test('a project with no windows/ directory yields a single "Windows: '
        'not applicable" skip', () async {
      Directory('$consumerRoot/windows').deleteSync(recursive: true);
      final results = await runDoctorWindowsChecks(buildContext());
      expect(results, hasLength(1));
      expect(results.single.status, DoctorCheckStatus.skip);
      expect(results.single.message, contains('no windows/ directory'));
    });
  });

  group('Visual Studio check', () {
    test(
        'vswhere present and reports an install path, bundle exists, bare '
        'present -> every check passes', () async {
      final results = await runDoctorWindowsChecks(buildContext());
      expect(results, hasLength(3));
      expect(results.every((r) => r.status == DoctorCheckStatus.pass), isTrue,
          reason: results.map((r) => r.render()).join('\n'));
    });

    test('vswhere.exe does not exist at all -> FAIL without even trying to '
        'run it', () async {
      final results = await runDoctorWindowsChecks(buildContext(
        vswherePathOverride: '${root.path}/does-not-exist.exe',
        processRunner: (executable, args) async {
          // The bare-runtime check (flutter_pear-bhv) is unrelated to
          // vswhere's own existence guard and still legitimately runs.
          if (executable == 'bare') return _ok('1.16.0');
          throw StateError('should not run: $executable');
        },
      ));
      final vsResult =
          results.firstWhere((r) => r.message.contains('Visual Studio') ||
              r.message.contains('vswhere'));
      expect(vsResult.status, DoctorCheckStatus.fail);
      expect(vsResult.remediation, contains('Desktop development with C++'));
    });

    test('vswhere runs but finds no matching install (empty stdout) -> '
        'FAIL, not a false pass', () async {
      final results = await runDoctorWindowsChecks(buildContext(
        processRunner: (executable, args) async => _ok(''),
      ));
      final vsResult =
          results.firstWhere((r) => r.message.contains('Visual Studio'));
      expect(vsResult.status, DoctorCheckStatus.fail);
    });
  });

  group('bare runtime (flutter_pear-bhv)', () {
    test('bare not found on PATH -> a FAIL naming npm i -g bare, not a '
        'silently-passing SKIP', () async {
      final results = await runDoctorWindowsChecks(buildContext(
        processRunner: (executable, args) async {
          if (executable == 'bare') throw const ProcessException('bare', []);
          return passingProcessRunner(executable, args);
        },
      ));
      final bareResult =
          results.firstWhere((r) => r.message.contains('bare'));
      expect(bareResult.status, DoctorCheckStatus.fail);
      expect(bareResult.remediation, contains('npm i -g bare'));
      expect(bareResult.remediation, contains('BARE_RUNTIME_MISSING'));
    });

    test('bare --version exits nonzero -> a FAIL', () async {
      final results = await runDoctorWindowsChecks(buildContext(
        processRunner: (executable, args) async {
          if (executable == 'bare') return _ok('', exitCode: 1);
          return passingProcessRunner(executable, args);
        },
      ));
      final bareResult =
          results.firstWhere((r) => r.message.contains('bare --version'));
      expect(bareResult.status, DoctorCheckStatus.fail);
    });
  });

  group('committed desktop bundle', () {
    test('missing pear-end.bundle for win32-x64 -> FAIL with a '
        'maintainer-only remediation', () async {
      File('$flutterPearRoot/assets/desktop/win32-x64/pear-end.bundle')
          .deleteSync();
      final results = await runDoctorWindowsChecks(buildContext());
      final bundleResult =
          results.firstWhere((r) => r.message.contains('pear-end.bundle'));
      expect(bundleResult.status, DoctorCheckStatus.fail);
      expect(bundleResult.remediation, contains('pub cache repair'));
    });
  });

  test('renderDoctorWindowsChecks joins every result with a newline',
      () async {
    final results = await runDoctorWindowsChecks(buildContext());
    final rendered = renderDoctorWindowsChecks(results);
    expect(rendered.split('\n'), hasLength(results.length));
  });
}
