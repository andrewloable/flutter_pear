import 'dart:io';

import 'doctor_ios_checks.dart'
    show DoctorCheckResult, DoctorCheckStatus, ProcessRunner;

Future<ProcessResult> _realProcessRunner(
        String executable, List<String> args) =>
    Process.run(executable, args);

/// The well-known, stable install path for `vswhere.exe` -- shipped by the
/// Visual Studio Installer itself since VS2017 and never moved since,
/// confirmed against a real VS2022 install (flutter_pear-pfp) before
/// writing this check.
const _vswhereDefaultPath =
    r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe';

/// The C++ desktop development workload component ID `vswhere` filters on
/// -- same ID Flutter's own tooling checks for, confirmed via a real
/// `vswhere -requires` run against a real VS2022 Community install.
const _vcToolsComponentId = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64';

const _vsRemediation = 'Install Visual Studio 2022 (any edition, including '
    'the free Community edition) with the "Desktop development with C++" '
    'workload -- see https://flutter.dev/to/windows-install.';

const _maintainerOnlyRemediation = 'This indicates a corrupted install of '
    'flutter_pear itself, not something fixable in your own project -- '
    'try dart pub cache repair, or file a GitHub issue if it persists.';

/// A missing `bare` runtime is a fatal precondition on every desktop host,
/// not a nice-to-have check -- see `doctor_macos_checks.dart`'s identically
/// named constant (flutter_pear-bhv) for the full rationale.
const _bareRuntimeRemediation = 'Install the Bare runtime globally with '
    '`npm i -g bare`, then restart your app. See '
    'ERRORS.md#BARE_RUNTIME_MISSING.';

/// Everything a single doctor Windows check run needs, gathered in one
/// place (same shape as `DoctorMacosContext`) so every check function takes
/// exactly one argument, and tests can swap every environment-touching
/// piece for a fake without a real Visual Studio install.
class DoctorWindowsContext {
  /// Creates a context. Every field beyond [consumerRoot] and
  /// [flutterPearRoot] defaults to the real, environment-touching
  /// implementation -- tests override what they need to fake.
  const DoctorWindowsContext({
    required this.consumerRoot,
    required this.flutterPearRoot,
    this.isWindows = true,
    this.vswherePath = _vswhereDefaultPath,
    this.processRunner = _realProcessRunner,
  });

  /// The consumer Flutter project's root directory (contains `windows/`,
  /// `pubspec.yaml`, ...) -- `Directory.current.path` in production.
  final String consumerRoot;

  /// The resolved `flutter_pear` package's own root directory -- where the
  /// committed `assets/desktop/<host>/pear-end.bundle` files live.
  final String flutterPearRoot;

  /// Whether this run is on Windows -- `Platform.isWindows` in production.
  /// Every Windows check needs the real, local build toolchain (Visual
  /// Studio's C++ workload); on any other OS [runDoctorWindowsChecks]
  /// returns a single explanatory skip instead of running any of them --
  /// there is no cross-compilation story here, matching macOS's own
  /// Xcode-only-on-a-Mac constraint (flutter_pear-pfp).
  final bool isWindows;

  /// Absolute path to `vswhere.exe` -- overridable for tests; production
  /// uses [_vswhereDefaultPath].
  final String vswherePath;

  /// Runs external processes (`vswhere.exe`).
  final ProcessRunner processRunner;
}

/// Runs every Windows environment/pin-consistency check and returns their
/// results in a fixed, stable order. On a non-Windows host, or a project
/// with no `windows/` directory, returns a single `Windows: not applicable`
/// skip instead of running anything else.
Future<List<DoctorCheckResult>> runDoctorWindowsChecks(
    DoctorWindowsContext ctx) async {
  if (!ctx.isWindows) {
    return const [
      DoctorCheckResult(DoctorCheckStatus.skip,
          'Windows: not applicable (this doctor run is not on Windows)'),
    ];
  }
  if (!Directory('${ctx.consumerRoot}/windows').existsSync()) {
    return const [
      DoctorCheckResult(DoctorCheckStatus.skip,
          'Windows: not applicable (no windows/ directory in this project)'),
    ];
  }
  return [
    await _checkVisualStudioPresent(ctx),
    await _checkCommittedDesktopBundle(ctx),
    await _checkBareRuntime(ctx),
  ];
}

/// Confirms the real `bare` runtime is on `PATH` -- flutter_pear-a4p's own
/// fix makes a missing `bare` a catchable Dart exception at `Pear.start()`
/// instead of a hard crash, but doctor should still catch it as a real
/// [DoctorCheckStatus.fail] ahead of time (flutter_pear-bhv).
Future<DoctorCheckResult> _checkBareRuntime(DoctorWindowsContext ctx) async {
  final ProcessResult result;
  try {
    result = await ctx.processRunner('bare', ['--version']);
  } on ProcessException {
    return const DoctorCheckResult(
      DoctorCheckStatus.fail,
      'the `bare` runtime was not found on PATH (bare --version failed to run)',
      remediation: _bareRuntimeRemediation,
    );
  }
  if (result.exitCode != 0) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'bare --version exited ${result.exitCode}',
      remediation: _bareRuntimeRemediation,
    );
  }
  return DoctorCheckResult(
      DoctorCheckStatus.pass, "'bare' runtime found: ${'${result.stdout}'.trim()}");
}

/// Renders [results] as one newline-joined block of `[PASS]`/`[FAIL]`/
/// `[SKIP]`/`[INFO]` lines, matching `doctor_ios_checks.dart`'s own format.
String renderDoctorWindowsChecks(List<DoctorCheckResult> results) =>
    results.map((r) => r.render()).join('\n');

/// Confirms Visual Studio with the C++ desktop workload is installed --
/// the same requirement `flutter doctor` itself checks for, verified
/// independently here (mirroring macOS's own independent `xcodebuild`
/// check rather than delegating to `flutter doctor`'s own line) via
/// `vswhere -requires`, which prints an install path ONLY when a matching
/// installation exists (empty stdout otherwise -- confirmed against a real
/// VS2022 install before writing this check).
Future<DoctorCheckResult> _checkVisualStudioPresent(
    DoctorWindowsContext ctx) async {
  if (!File(ctx.vswherePath).existsSync()) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'vswhere.exe not found at ${ctx.vswherePath} -- Visual Studio does '
          'not appear to be installed',
      remediation: _vsRemediation,
    );
  }
  final ProcessResult result;
  try {
    result = await ctx.processRunner(ctx.vswherePath, [
      '-latest',
      '-products',
      '*',
      '-requires',
      _vcToolsComponentId,
      '-property',
      'installationPath',
    ]);
  } on ProcessException {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'Could not run vswhere.exe at ${ctx.vswherePath}',
      remediation: _vsRemediation,
    );
  }
  final installPath = '${result.stdout}'.trim();
  if (result.exitCode != 0 || installPath.isEmpty) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'No Visual Studio installation with the "Desktop development with '
          'C++" workload was found',
      remediation: _vsRemediation,
    );
  }
  return DoctorCheckResult(
      DoctorCheckStatus.pass, 'Visual Studio (C++ workload) found at $installPath');
}

Future<DoctorCheckResult> _checkCommittedDesktopBundle(
    DoctorWindowsContext ctx) async {
  final bundle = File(
      '${ctx.flutterPearRoot}/assets/desktop/win32-x64/pear-end.bundle');
  if (!bundle.existsSync() || bundle.lengthSync() == 0) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'flutter_pear/assets/desktop/win32-x64/pear-end.bundle is missing',
      remediation: _maintainerOnlyRemediation,
    );
  }
  return const DoctorCheckResult(
      DoctorCheckStatus.pass, 'pear-end.bundle present for win32-x64');
}
