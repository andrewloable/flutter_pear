import 'dart:io';

import 'package:flutter_pear/src/doctor_ios_checks.dart'
    show DoctorCheckStatus, ProcessRunner;
import 'package:flutter_pear/src/doctor_linux_checks.dart';
import 'package:flutter_test/flutter_test.dart';

/// A canned [ProcessResult] for a successful command.
ProcessResult _ok(String stdout, {int exitCode = 0}) =>
    ProcessResult(0, exitCode, stdout, '');

void main() {
  late Directory root;
  late String consumerRoot;
  late String flutterPearRoot;

  setUp(() {
    root = Directory.systemTemp.createTempSync('fp_doctor_linux');
    consumerRoot = '${root.path}/consumer';
    flutterPearRoot = '${root.path}/flutter_pear';
    Directory('$consumerRoot/linux').createSync(recursive: true);
    Directory('$flutterPearRoot/assets/desktop/linux-x64')
        .createSync(recursive: true);
    File('$flutterPearRoot/assets/desktop/linux-x64/pear-end.bundle')
        .writeAsBytesSync([1, 2, 3]);
  });

  tearDown(() => root.deleteSync(recursive: true));

  Future<ProcessResult> passingProcessRunner(
      String executable, List<String> args) async {
    if (executable == 'clang++') return _ok('Ubuntu clang version 18.1.3');
    if (executable == 'cmake') return _ok('cmake version 3.28.3');
    if (executable == 'ninja') return _ok('1.11.1');
    if (executable == 'pkg-config') return _ok('3.24.41');
    if (executable == 'bare') return _ok('1.16.0');
    throw StateError('unexpected executable: $executable');
  }

  DoctorLinuxContext buildContext({
    bool isLinux = true,
    ProcessRunner? processRunner,
  }) =>
      DoctorLinuxContext(
        consumerRoot: consumerRoot,
        flutterPearRoot: flutterPearRoot,
        isLinux: isLinux,
        processRunner: processRunner ?? passingProcessRunner,
      );

  group('runDoctorLinuxChecks gating', () {
    test('non-Linux yields a single "Linux: not applicable" skip, no other '
        'checks run', () async {
      final results =
          await runDoctorLinuxChecks(buildContext(isLinux: false));
      expect(results, hasLength(1));
      expect(results.single.status, DoctorCheckStatus.skip);
      expect(results.single.message, contains('Linux: not applicable'));
      expect(results.single.message, contains('not on Linux'));
    });

    test('a project with no linux/ directory yields a single "Linux: not '
        'applicable" skip', () async {
      Directory('$consumerRoot/linux').deleteSync(recursive: true);
      final results = await runDoctorLinuxChecks(buildContext());
      expect(results, hasLength(1));
      expect(results.single.status, DoctorCheckStatus.skip);
      expect(
          results.single.message, contains('no linux/ directory'));
    });
  });

  group('toolchain checks', () {
    test(
        'all 4 tools present, bare present, and the bundle exists -> every '
        'check passes', () async {
      final results = await runDoctorLinuxChecks(buildContext());
      expect(results, hasLength(6));
      expect(results.every((r) => r.status == DoctorCheckStatus.pass), isTrue,
          reason: results.map((r) => r.render()).join('\n'));
    });

    test('clang missing -> a FAIL naming clang specifically, other tools '
        'still individually reported', () async {
      final results = await runDoctorLinuxChecks(buildContext(
        processRunner: (executable, args) async {
          if (executable == 'clang++') {
            throw const ProcessException('clang++', []);
          }
          return passingProcessRunner(executable, args);
        },
      ));
      final clangResult = results.firstWhere((r) => r.message.contains('clang'));
      expect(clangResult.status, DoctorCheckStatus.fail);
      expect(clangResult.remediation, isNotNull);
      // The other 3 tool checks + the bundle check + the bare check still
      // ran and passed.
      expect(
          results.where((r) => r.status == DoctorCheckStatus.pass), hasLength(5));
    });

    test('GTK dev headers missing (pkg-config exits nonzero) -> a FAIL '
        'naming GTK, not a generic pkg-config error', () async {
      final results = await runDoctorLinuxChecks(buildContext(
        processRunner: (executable, args) async {
          if (executable == 'pkg-config') return _ok('', exitCode: 1);
          return passingProcessRunner(executable, args);
        },
      ));
      final gtkResult =
          results.firstWhere((r) => r.message.contains('GTK 3'));
      expect(gtkResult.status, DoctorCheckStatus.fail);
      expect(gtkResult.remediation, contains('libgtk-3-dev'));
    });
  });

  group('bare runtime (flutter_pear-bhv)', () {
    test('bare not found on PATH -> a FAIL naming npm i -g bare, not a '
        'silently-passing SKIP', () async {
      final results = await runDoctorLinuxChecks(buildContext(
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
      final results = await runDoctorLinuxChecks(buildContext(
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
    test('missing pear-end.bundle for linux-x64 -> FAIL with a '
        'maintainer-only remediation', () async {
      File('$flutterPearRoot/assets/desktop/linux-x64/pear-end.bundle')
          .deleteSync();
      final results = await runDoctorLinuxChecks(buildContext());
      final bundleResult =
          results.firstWhere((r) => r.message.contains('pear-end.bundle'));
      expect(bundleResult.status, DoctorCheckStatus.fail);
      expect(bundleResult.remediation, contains('pub cache repair'));
    });
  });

  test('renderDoctorLinuxChecks joins every result with a newline', () async {
    final results = await runDoctorLinuxChecks(buildContext());
    final rendered = renderDoctorLinuxChecks(results);
    expect(rendered.split('\n'), hasLength(results.length));
  });
}
