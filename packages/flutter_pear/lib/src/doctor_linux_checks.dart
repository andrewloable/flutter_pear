import 'dart:io';

import 'doctor_ios_checks.dart'
    show DoctorCheckResult, DoctorCheckStatus, ProcessRunner;

Future<ProcessResult> _realProcessRunner(
        String executable, List<String> args) =>
    Process.run(executable, args);

const _toolchainRemediation = 'Install the Flutter Linux desktop toolchain '
    '(clang, cmake, ninja, pkg-config, and GTK 3 development headers) -- '
    'on Debian/Ubuntu: sudo apt-get install clang cmake ninja-build '
    'pkg-config libgtk-3-dev. See https://flutter.dev/to/linux-install for '
    'other distributions.';

const _maintainerOnlyRemediation = 'This indicates a corrupted install of '
    'flutter_pear itself, not something fixable in your own project -- '
    'try dart pub cache repair, or file a GitHub issue if it persists.';

/// Everything a single doctor Linux check run needs, gathered in one place
/// (same shape as `DoctorMacosContext`) so every check function takes
/// exactly one argument, and tests can swap every environment-touching
/// piece for a fake without a real Linux toolchain install.
class DoctorLinuxContext {
  /// Creates a context. Every field beyond [consumerRoot] and
  /// [flutterPearRoot] defaults to the real, environment-touching
  /// implementation -- tests override what they need to fake.
  const DoctorLinuxContext({
    required this.consumerRoot,
    required this.flutterPearRoot,
    this.isLinux = true,
    this.processRunner = _realProcessRunner,
  });

  /// The consumer Flutter project's root directory (contains `linux/`,
  /// `pubspec.yaml`, ...) -- `Directory.current.path` in production.
  final String consumerRoot;

  /// The resolved `flutter_pear` package's own root directory -- where the
  /// committed `assets/desktop/<host>/pear-end.bundle` files live.
  final String flutterPearRoot;

  /// Whether this run is on Linux -- `Platform.isLinux` in production.
  /// Every Linux check needs the real, local build toolchain (clang, cmake,
  /// ninja, GTK dev headers); on any other OS [runDoctorLinuxChecks] returns
  /// a single explanatory skip instead of running any of them -- there is
  /// no cross-compilation story here, matching macOS's own Xcode-only-on-a-
  /// -Mac constraint (flutter_pear-65g).
  final bool isLinux;

  /// Runs external processes (`clang++`, `cmake`, `ninja`, `pkg-config`).
  final ProcessRunner processRunner;
}

/// Runs every Linux environment/pin-consistency check and returns their
/// results in a fixed, stable order. On a non-Linux host, or a project with
/// no `linux/` directory, returns a single `Linux: not applicable` skip
/// instead of running anything else.
Future<List<DoctorCheckResult>> runDoctorLinuxChecks(
    DoctorLinuxContext ctx) async {
  if (!ctx.isLinux) {
    return const [
      DoctorCheckResult(DoctorCheckStatus.skip,
          'Linux: not applicable (this doctor run is not on Linux)'),
    ];
  }
  if (!Directory('${ctx.consumerRoot}/linux').existsSync()) {
    return const [
      DoctorCheckResult(DoctorCheckStatus.skip,
          'Linux: not applicable (no linux/ directory in this project)'),
    ];
  }
  return [
    ...await _checkLinuxToolchain(ctx),
    await _checkCommittedDesktopBundle(ctx),
  ];
}

/// Renders [results] as one newline-joined block of `[PASS]`/`[FAIL]`/
/// `[SKIP]`/`[INFO]` lines, matching `doctor_ios_checks.dart`'s own format.
String renderDoctorLinuxChecks(List<DoctorCheckResult> results) =>
    results.map((r) => r.render()).join('\n');

/// Checks each of the 4 separately-installable tools flutter_pear_bare's
/// Linux host needs to build (flutter_pear-65g): unlike Xcode (one bundled
/// toolchain), a real Linux build needs clang, cmake, ninja, and GTK 3 dev
/// headers as independent packages -- reported individually so a consumer
/// missing just one gets a precise, actionable failure instead of a vague
/// "toolchain broken".
Future<List<DoctorCheckResult>> _checkLinuxToolchain(
    DoctorLinuxContext ctx) async {
  return [
    await _checkTool(ctx, 'clang++', ['--version'], 'clang'),
    await _checkTool(ctx, 'cmake', ['--version'], 'cmake'),
    await _checkTool(ctx, 'ninja', ['--version'], 'ninja'),
    await _checkPkgConfigGtk(ctx),
  ];
}

Future<DoctorCheckResult> _checkTool(DoctorLinuxContext ctx,
    String executable, List<String> args, String label) async {
  final ProcessResult result;
  try {
    result = await ctx.processRunner(executable, args);
  } on ProcessException {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      '$label not found ($executable ${args.join(' ')} failed to run)',
      remediation: _toolchainRemediation,
    );
  }
  if (result.exitCode != 0) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      '$executable ${args.join(' ')} exited ${result.exitCode}',
      remediation: _toolchainRemediation,
    );
  }
  final firstLine = '${result.stdout}'.trim().split('\n').first;
  return DoctorCheckResult(DoctorCheckStatus.pass, '$label found: $firstLine');
}

Future<DoctorCheckResult> _checkPkgConfigGtk(DoctorLinuxContext ctx) async {
  final ProcessResult result;
  try {
    result = await ctx.processRunner(
        'pkg-config', ['--modversion', 'gtk+-3.0']);
  } on ProcessException {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'pkg-config not found (pkg-config --modversion gtk+-3.0 failed to run)',
      remediation: _toolchainRemediation,
    );
  }
  if (result.exitCode != 0) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'GTK 3 development headers not found (pkg-config --modversion '
          'gtk+-3.0 exited ${result.exitCode})',
      remediation: _toolchainRemediation,
    );
  }
  return DoctorCheckResult(DoctorCheckStatus.pass,
      'GTK 3 development headers found: ${'${result.stdout}'.trim()}');
}

Future<DoctorCheckResult> _checkCommittedDesktopBundle(
    DoctorLinuxContext ctx) async {
  final bundle = File(
      '${ctx.flutterPearRoot}/assets/desktop/linux-x64/pear-end.bundle');
  if (!bundle.existsSync() || bundle.lengthSync() == 0) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'flutter_pear/assets/desktop/linux-x64/pear-end.bundle is missing',
      remediation: _maintainerOnlyRemediation,
    );
  }
  return const DoctorCheckResult(
      DoctorCheckStatus.pass, 'pear-end.bundle present for linux-x64');
}
