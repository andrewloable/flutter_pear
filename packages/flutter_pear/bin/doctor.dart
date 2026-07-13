import 'dart:io';
import 'dart:isolate';

import 'package:flutter_pear/src/doctor_host_checks.dart';
import 'package:flutter_pear/src/doctor_ios_checks.dart';
import 'package:flutter_pear/src/doctor_linux_checks.dart';
import 'package:flutter_pear/src/doctor_macos_checks.dart';
import 'package:flutter_pear/src/doctor_report.dart';
import 'package:flutter_pear/src/doctor_windows_checks.dart';

/// Runtime connectivity doctor (E7.4, X5) -- `dart run flutter_pear:doctor`.
///
/// Desktop-side network diagnostics only: connectivity/DHT/NAT checks that
/// answer "will this network let flutter_pear's Hyperswarm connections
/// work", run directly against the real Hyperswarm DHT. Does NOT boot the
/// real Android/iOS worklet -- a plain `dart run` CLI has no Flutter
/// engine, so it can't drive `BareWorklet`'s platform channels the way a
/// real app does; there is no way for pure Dart to do that here. Doctor is
/// explicitly a RUNTIME diagnostic (install-time failures are the error
/// catalog + troubleshooting docs' job, not this tool's).
///
/// `--report [--log <path>]` (E7.5) prints a paste-ready markdown support
/// bundle instead -- package versions, the pear-end bundle identifier, the
/// host environment, these same checks' output, and (if `--log` is given) a
/// sanitized tail of that log file. Nothing here is ever transmitted
/// (LOCKED: no runtime telemetry in a privacy-first P2P library) -- the
/// bundle is meant to be pasted into a GitHub issue by hand.
///
/// `--fix` (flutter_pear-jxf) applies the macOS section's run-blocking/
/// LAN-breaking fixes it already detects: the App Sandbox entitlement in
/// BOTH `macos/Runner/DebugProfile.entitlements` and
/// `macos/Runner/Release.entitlements`, Info.plist's
/// `NSLocalNetworkUsageDescription`, and a below-minimum
/// `MACOSX_DEPLOYMENT_TARGET` in project.pbxproj -- instead of a developer
/// hand-editing XML/project settings -- then exits WITHOUT running the
/// normal check-and-report flow below -- re-run `dart run flutter_pear:doctor`
/// (no `--fix`) afterward to confirm.
/// Idempotent and safe to re-run: a file needing no change is silently left
/// alone, never touched or re-reported. `bare` on `PATH` is a SEPARATE
/// precondition this does not and cannot fix (flutter_pear-a4p/-8f6) --
/// installing a runtime isn't a file edit.
///
/// Runs a pure-Dart host-capability line FIRST (`doctor_host_checks.dart`,
/// flutter_pear-l0w) -- a one-line verdict naming which build targets THIS
/// host can build for (Android: any host; iOS/macOS: macOS + Xcode only, an
/// Apple constraint) -- then the pure-Dart iOS section
/// (`doctor_ios_checks.dart`), macOS section (`doctor_macos_checks.dart`,
/// flutter_pear-b6g), Linux section (`doctor_linux_checks.dart`,
/// flutter_pear-65g), and Windows section (`doctor_windows_checks.dart`,
/// flutter_pear-pfp): toolchain/simulator presence, packaging-path
/// detection, the consumer `Info.plist`/entitlements (Apple only), the
/// committed desktop bundle assets, and this plugin's own installed-package
/// pin integrity -- none of which needs Node at all, so all four run even
/// when Node is absent. Every desktop section (macOS/Linux/Windows) only
/// runs its real checks on that SAME OS -- there is no cross-compilation
/// story, so a doctor run on this Mac always skips the Linux/Windows
/// sections with a one-line "not applicable", by design.
/// Everything else lives in `tool/doctor-checks.js`, run as a plain Node
/// process afterward -- see that file's own doc comment. Exits nonzero if
/// either side found a real failure (0 only if both the Dart-side checks
/// and the JS side found none) whether or not `--report` was passed, so
/// this is usable as a CI gate either way. The JS side's own final
/// "All checks passed."/"Some checks failed" line only speaks for itself
/// (DHT reachability + loopback) -- [isMisleadingAllClear] catches the one
/// case where that would read as a false all-clear (a Dart-side `[FAIL]`
/// above it, but a healthy network) and prints a corrective note, found via
/// a live /devex-review pass.
///
/// `--help`/`-h` prints usage and exits immediately -- no diagnostics run,
/// no network touched.
Future<void> main(List<String> args) async {
  if (args.contains('--help') || args.contains('-h')) {
    stdout.writeln(_usage.trim());
    return;
  }
  if (args.contains('--fix')) {
    final changes = applyMacosFixes(Directory.current.path);
    if (changes.isEmpty) {
      stdout.writeln('Nothing to fix.');
    } else {
      for (final change in changes) {
        stdout.writeln('Fixed: $change');
      }
    }
    return;
  }

  final report = args.contains('--report');
  final logIndex = args.indexOf('--log');
  if (logIndex != -1 && logIndex + 1 >= args.length) {
    stderr.writeln('--log needs a path, e.g. --log /path/to/app.log');
    exit(2);
  }
  final logPath = logIndex == -1 ? null : args[logIndex + 1];
  if (logPath != null && !File(logPath).existsSync()) {
    stderr.writeln('--log path not found: $logPath');
    exit(2);
  }
  // doctor-checks.js only understands its own flags -- strip this script's.
  final checksArgs = [
    for (var i = 0; i < args.length; i++)
      if (args[i] != '--report' && args[i] != '--log' && i != logIndex + 1)
        args[i],
  ];

  final libUri = await Isolate.resolvePackageUri(
    Uri.parse('package:flutter_pear/'),
  );
  if (libUri == null) {
    stderr.writeln(
      'Could not resolve package:flutter_pear/ -- this needs a '
      '.dart_tool/package_config.json (e.g. `dart run`), not a standalone '
      '`dart compile exe` binary.',
    );
    exit(1);
  }
  final packageRoot = Directory.fromUri(libUri).parent;
  final checksJs =
      File('${packageRoot.path}/tool/doctor-checks.js').absolute.path;

  // Pure Dart, no Node dependency -- runs first, and runs even if Node
  // turns out to be missing entirely (the try/catch below).
  final bareLibUri = await Isolate.resolvePackageUri(
    Uri.parse('package:flutter_pear_bare/'),
  );
  final hostResult = checkHostCapability(
    DoctorHostContext(operatingSystem: Platform.operatingSystem),
  );
  final resolvedBareRoot = bareLibUri == null
      ? '${packageRoot.path}/../flutter_pear_bare'
      : Directory.fromUri(bareLibUri).parent.path;
  final iosResults = await runDoctorIosChecks(DoctorIosContext(
    consumerRoot: Directory.current.path,
    flutterPearBareRoot: resolvedBareRoot,
    isMacOs: Platform.isMacOS,
  ));
  final macosResults = await runDoctorMacosChecks(DoctorMacosContext(
    consumerRoot: Directory.current.path,
    flutterPearRoot: packageRoot.path,
    flutterPearBareRoot: resolvedBareRoot,
    isMacOs: Platform.isMacOS,
  ));
  final linuxResults = await runDoctorLinuxChecks(DoctorLinuxContext(
    consumerRoot: Directory.current.path,
    flutterPearRoot: packageRoot.path,
    isLinux: Platform.isLinux,
  ));
  final windowsResults = await runDoctorWindowsChecks(DoctorWindowsContext(
    consumerRoot: Directory.current.path,
    flutterPearRoot: packageRoot.path,
    isWindows: Platform.isWindows,
  ));
  final allResults = [
    hostResult,
    ...iosResults,
    ...macosResults,
    ...linuxResults,
    ...windowsResults,
  ];
  final dartCheckOutput = renderDoctorIosChecks(allResults);
  final dartChecksOk =
      !allResults.any((r) => r.status == DoctorCheckStatus.fail);
  if (!report) {
    stdout.writeln(dartCheckOutput);
  }

  try {
    final process = await Process.start(
      'node',
      [checksJs, ...checksArgs],
      mode: report ? ProcessStartMode.normal : ProcessStartMode.inheritStdio,
    );
    final String checkOutput;
    if (report) {
      // Captured (not inherited) so it can be embedded in the report below
      // instead of also printing twice.
      checkOutput =
          await process.stdout.transform(systemEncoding.decoder).join();
      await process.stderr.drain<void>();
    } else {
      checkOutput = '';
    }
    final jsExitCode = await process.exitCode;
    exitCode = (jsExitCode != 0 || !dartChecksOk) ? 1 : 0;
    final misleadingAllClear =
        isMisleadingAllClear(dartChecksOk: dartChecksOk, jsExitCode: jsExitCode);

    if (report) {
      stdout.write(buildDoctorReport(
        flutterPearVersion: _packageVersion(packageRoot, 'flutter_pear'),
        flutterPearBareVersion:
            _packageVersion(packageRoot, 'flutter_pear_bare'),
        hostOs:
            '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
        doctorCheckOutput: '$dartCheckOutput\n\n$checkOutput'
            '${misleadingAllClear ? '\n\n$_misleadingAllClearNote' : ''}',
        rawLog: logPath == null ? null : File(logPath).readAsStringSync(),
      ));
    } else if (misleadingAllClear) {
      stdout.writeln();
      stdout.writeln(_misleadingAllClearNote);
    }
  } on ProcessException catch (e) {
    stderr.writeln('Could not run doctor-checks.js: $e');
    stderr.writeln('Is Node.js installed and on PATH?');
    exit(1);
  }
}

const _usage = '''
flutter_pear doctor -- runtime + install-time diagnostics for this app.

Usage: dart run flutter_pear:doctor [options]

  (no options)   Run every check, printing [PASS]/[FAIL]/[INFO]/[SKIP] lines.
  --report       Print a paste-ready markdown support bundle instead.
  --log <path>   Include a sanitized tail of this log file in --report output.
  --fix          Apply macOS's known run-blocking fixes (App Sandbox
                 entitlement, Info.plist, deployment target), then exit --
                 no diagnostics run.
  --help, -h     Show this message and exit.

Run from your own app's root, not from inside the flutter_pear package --
it needs your project's macos/linux/windows directories to check anything
platform-specific. Exits nonzero if any check failed, whether or not
--report was passed, so it's usable as a CI/hand-run gate either way.''';

const _misleadingAllClearNote =
    'Note: the runtime diagnostics above passed, but an earlier check did '
    'not -- this project is NOT ready yet. See the [FAIL] line(s) above.';

/// True when `doctor-checks.js`'s own "All checks passed." verdict (which
/// only covers ITS OWN checks -- DHT reachability, loopback -- and is
/// printed as the very last line of the whole tool's output, the line a
/// skimming developer actually reads) would read as a false all-clear
/// because the Dart-side platform/packaging checks above it already found
/// a real `[FAIL]`, despite the tool's overall exit code correctly being
/// nonzero either way.
bool isMisleadingAllClear({required bool dartChecksOk, required int jsExitCode}) =>
    !dartChecksOk && jsExitCode == 0;

/// [name]'s package version, read straight from its `pubspec.yaml` --
/// avoids adding a YAML-parsing dependency for one `version:` line.
String _packageVersion(Directory flutterPearRoot, String name) {
  final pubspec = name == 'flutter_pear'
      ? File('${flutterPearRoot.path}/pubspec.yaml')
      : File('${flutterPearRoot.path}/../$name/pubspec.yaml');
  final match = RegExp(r'^version:\s*(.+)$', multiLine: true)
      .firstMatch(pubspec.readAsStringSync());
  return match?.group(1)?.trim() ?? 'unknown';
}
