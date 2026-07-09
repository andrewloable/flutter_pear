import 'dart:convert';
import 'dart:io';

import 'doctor_ios_checks.dart'
    show DoctorCheckResult, DoctorCheckStatus, ProcessRunner;

Future<ProcessResult> _realProcessRunner(
        String executable, List<String> args) =>
    Process.run(executable, args);

/// Minimum Xcode version -- same requirement as iOS (see
/// `doctor_ios_checks.dart`'s own constant); both platforms build through
/// the same Xcode toolchain.
const _minXcodeVersion = (major: 15, minor: 0);

/// Same SwiftPM-default-resolution threshold as iOS -- Flutter's own
/// SwiftPM plugin resolution path, not a macOS-specific requirement.
const _minFlutterVersionForSpm = (3, 44, 0);

/// Minimum `MACOSX_DEPLOYMENT_TARGET` -- mirrors
/// `flutter_pear_bare/macos/flutter_pear_bare/Package.swift`'s own
/// `.macOS("10.15")` pin, kept in sync by hand (a consumer's pub.dev
/// install never has this repo's own COMPATIBILITY.md).
const _minDeploymentTargetFallback = 10.15;

const _plistRemediationBlock = '''
Add this to macos/Runner/Info.plist:
  <key>NSLocalNetworkUsageDescription</key>
  <string>Describe your app's own use of the local network here.</string>''';

const _sandboxRemediationBlock = '''
Set com.apple.security.app-sandbox to false in BOTH
macos/Runner/DebugProfile.entitlements and macos/Runner/Release.entitlements
-- the macOS host spawns the real `bare` runtime as an external, non-bundled
subprocess (flutter_pear-71g), which the App Sandbox blocks unconditionally.
A sandboxed distribution story is a documented follow-up, not yet available.''';

/// Everything a single doctor macOS check run needs, gathered in one place
/// (same shape as `DoctorIosContext`) so every check function takes exactly
/// one argument, and tests can swap every environment-touching piece for a
/// fake without a real Xcode install.
class DoctorMacosContext {
  /// Creates a context. Every field beyond [consumerRoot] and
  /// [flutterPearRoot] defaults to the real, environment-touching
  /// implementation -- tests override what they need to fake.
  const DoctorMacosContext({
    required this.consumerRoot,
    required this.flutterPearRoot,
    required this.flutterPearBareRoot,
    this.isMacOs = true,
    this.processRunner = _realProcessRunner,
  });

  /// The consumer Flutter project's root directory (contains `macos/`,
  /// `pubspec.yaml`, ...) -- `Directory.current.path` in production.
  final String consumerRoot;

  /// The resolved `flutter_pear` package's own root directory -- where the
  /// committed `assets/desktop/<host>/pear-end.bundle` files live.
  final String flutterPearRoot;

  /// The resolved `flutter_pear_bare` package's own root directory -- where
  /// `macos/flutter_pear_bare/Package.swift` lives.
  final String flutterPearBareRoot;

  /// Whether this run is on macOS -- `Platform.isMacOS` in production.
  /// Every macOS check needs a real Mac (Xcode); on any other OS
  /// [runDoctorMacosChecks] returns a single explanatory skip instead of
  /// running any of them.
  final bool isMacOs;

  /// Runs external processes (`xcodebuild`, `flutter`).
  final ProcessRunner processRunner;
}

/// Runs every macOS environment/pin-consistency check and returns their
/// results in a fixed, stable order. On a non-macOS host, or a project with
/// no `macos/` directory, returns a single `macOS: not applicable` skip
/// instead of running anything else.
Future<List<DoctorCheckResult>> runDoctorMacosChecks(
    DoctorMacosContext ctx) async {
  if (!ctx.isMacOs) {
    return const [
      DoctorCheckResult(DoctorCheckStatus.skip,
          'macOS: not applicable (this doctor run is not on macOS)'),
    ];
  }
  if (!Directory('${ctx.consumerRoot}/macos').existsSync()) {
    return const [
      DoctorCheckResult(DoctorCheckStatus.skip,
          'macOS: not applicable (no macos/ directory in this project)'),
    ];
  }
  return [
    await _checkXcodePresent(ctx),
    ...await _checkPackagingPathAndFlutterVersion(ctx),
    await _checkInfoPlist(ctx),
    ..._checkEntitlements(ctx),
    await _checkCommittedDesktopBundle(ctx),
    await _checkDeploymentTarget(ctx),
  ];
}

/// Renders [results] as one newline-joined block of `[PASS]`/`[FAIL]`/
/// `[SKIP]`/`[INFO]` lines, matching `doctor_ios_checks.dart`'s own format.
String renderDoctorMacosChecks(List<DoctorCheckResult> results) =>
    results.map((r) => r.render()).join('\n');

Future<DoctorCheckResult> _checkXcodePresent(DoctorMacosContext ctx) async {
  final ProcessResult result;
  try {
    result = await ctx.processRunner('xcodebuild', ['-version']);
  } on ProcessException {
    return const DoctorCheckResult(
      DoctorCheckStatus.fail,
      'Xcode not found (xcodebuild -version failed to run)',
      remediation: 'Install Xcode from the App Store, then run '
          'xcode-select --install to accept the license.',
    );
  }
  if (result.exitCode != 0) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'xcodebuild -version exited ${result.exitCode}',
      remediation: 'Run xcodebuild -version yourself to see the real '
          'error, then fix your Xcode install.',
    );
  }
  final match = RegExp(r'Xcode (\d+)\.(\d+)').firstMatch('${result.stdout}');
  if (match == null) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'Could not parse an Xcode version from: ${'${result.stdout}'.trim()}',
      remediation: 'File a GitHub issue with this doctor output -- '
          "xcodebuild's output format may have changed.",
    );
  }
  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  if (major < _minXcodeVersion.major ||
      (major == _minXcodeVersion.major && minor < _minXcodeVersion.minor)) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'Xcode $major.$minor found, but flutter_pear needs '
          '>=${_minXcodeVersion.major}.${_minXcodeVersion.minor}',
      remediation: 'Update Xcode via the App Store or developer.apple.com.',
    );
  }
  return DoctorCheckResult(
      DoctorCheckStatus.pass, 'Xcode $major.$minor found');
}

Future<List<DoctorCheckResult>> _checkPackagingPathAndFlutterVersion(
    DoctorMacosContext ctx) async {
  final usesCocoaPods =
      File('${ctx.consumerRoot}/macos/Podfile').existsSync();
  final pathInfo = DoctorCheckResult(
    DoctorCheckStatus.info,
    usesCocoaPods
        ? 'CocoaPods compat path detected (macos/Podfile present)'
        : 'SwiftPM path detected (default -- no macos/Podfile)',
  );

  final ProcessResult result;
  try {
    result = await ctx.processRunner('flutter', ['--version', '--machine']);
  } on ProcessException {
    return [
      pathInfo,
      const DoctorCheckResult(
        DoctorCheckStatus.fail,
        'Could not run flutter --version --machine',
        remediation: 'Confirm flutter is on PATH.',
      ),
    ];
  }
  if (result.exitCode != 0) {
    return [
      pathInfo,
      DoctorCheckResult(DoctorCheckStatus.fail,
          'flutter --version --machine exited ${result.exitCode}'),
    ];
  }
  final Map<String, dynamic> json;
  try {
    json = jsonDecode('${result.stdout}') as Map<String, dynamic>;
  } catch (e) {
    return [
      pathInfo,
      DoctorCheckResult(DoctorCheckStatus.fail,
          'Could not parse flutter --version --machine output: $e'),
    ];
  }
  final versionStr = json['frameworkVersion'] as String?;
  final parsed = versionStr == null ? null : _parseVersion(versionStr);
  if (parsed == null) {
    return [
      pathInfo,
      DoctorCheckResult(DoctorCheckStatus.fail,
          'Could not parse a Flutter framework version from: $versionStr'),
    ];
  }
  if (!usesCocoaPods && _versionLessThan(parsed, _minFlutterVersionForSpm)) {
    return [
      pathInfo,
      DoctorCheckResult(
        DoctorCheckStatus.fail,
        'Flutter $versionStr found, but SwiftPM plugin resolution needs '
            '>=${_minFlutterVersionForSpm.$1}.'
            '${_minFlutterVersionForSpm.$2}.'
            '${_minFlutterVersionForSpm.$3}',
        remediation: 'Upgrade Flutter (flutter upgrade), or add a '
            'macos/Podfile to use the CocoaPods compat path instead.',
      ),
    ];
  }
  return [
    pathInfo,
    DoctorCheckResult(DoctorCheckStatus.pass,
        'Flutter $versionStr is compatible with the detected packaging path'),
  ];
}

typedef _Version = (int major, int minor, int patch);

_Version? _parseVersion(String s) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(s);
  if (match == null) return null;
  return (
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

bool _versionLessThan(_Version a, _Version b) {
  if (a.$1 != b.$1) return a.$1 < b.$1;
  if (a.$2 != b.$2) return a.$2 < b.$2;
  return a.$3 < b.$3;
}

Future<DoctorCheckResult> _checkInfoPlist(DoctorMacosContext ctx) async {
  final plist = File('${ctx.consumerRoot}/macos/Runner/Info.plist');
  if (!plist.existsSync()) {
    return const DoctorCheckResult(
      DoctorCheckStatus.skip,
      'macos/Runner/Info.plist not found -- not a standard Flutter macOS '
          'project layout',
    );
  }
  final text = plist.readAsStringSync();
  if (!text.contains('NSLocalNetworkUsageDescription')) {
    return const DoctorCheckResult(
      DoctorCheckStatus.fail,
      'macos/Runner/Info.plist is missing NSLocalNetworkUsageDescription -- '
          'same-Wi-Fi peers can silently fail to connect (macOS 15+ gates '
          'LAN-unicast the same way iOS does, with no prompt at all when '
          'this key is missing)',
      remediation: _plistRemediationBlock,
    );
  }
  return const DoctorCheckResult(DoctorCheckStatus.pass,
      'macos/Runner/Info.plist has NSLocalNetworkUsageDescription');
}

/// Checks BOTH entitlements files -- a consumer who only fixes Debug (the
/// one they happen to be iterating against) and ships Release unfixed would
/// otherwise get a doctor pass that doesn't hold for their actual release
/// build.
List<DoctorCheckResult> _checkEntitlements(DoctorMacosContext ctx) {
  return [
    _checkOneEntitlementsFile(
        ctx, 'macos/Runner/DebugProfile.entitlements'),
    _checkOneEntitlementsFile(ctx, 'macos/Runner/Release.entitlements'),
  ];
}

DoctorCheckResult _checkOneEntitlementsFile(
    DoctorMacosContext ctx, String relativePath) {
  final file = File('${ctx.consumerRoot}/$relativePath');
  if (!file.existsSync()) {
    return DoctorCheckResult(DoctorCheckStatus.skip,
        '$relativePath not found -- not a standard Flutter macOS project layout');
  }
  final text = file.readAsStringSync();
  // A plist <dict> is an ordered flat list of alternating <key>/<value>
  // elements -- the sandbox key's own value is whatever boolean element
  // comes right after it, not necessarily <true/> literally adjacent in
  // the source text, but Xcode's own template writer always emits them on
  // consecutive lines, and every entitlements file in this repo (and every
  // one `flutter create` generates) follows that convention.
  final match = RegExp(
          r'<key>com\.apple\.security\.app-sandbox</key>\s*<(true|false)\s*/>')
      .firstMatch(text);
  if (match == null) {
    return DoctorCheckResult(
      DoctorCheckStatus.skip,
      '$relativePath: could not find com.apple.security.app-sandbox in the '
          'expected <key>/<value> layout -- skipping this check rather than '
          'guessing',
    );
  }
  if (match.group(1) == 'true') {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      '$relativePath has com.apple.security.app-sandbox set to true -- '
          'this blocks flutter_pear from spawning its bare subprocess',
      remediation: _sandboxRemediationBlock,
    );
  }
  return DoctorCheckResult(DoctorCheckStatus.pass,
      '$relativePath has com.apple.security.app-sandbox set to false');
}

const _maintainerOnlyRemediation = 'This indicates a corrupted install of '
    'flutter_pear itself, not something fixable in your own project -- '
    'try dart pub cache repair, or file a GitHub issue if it persists.';

Future<DoctorCheckResult> _checkCommittedDesktopBundle(
    DoctorMacosContext ctx) async {
  const hosts = ['darwin-arm64', 'darwin-x64'];
  final missing = <String>[];
  for (final host in hosts) {
    final bundle =
        File('${ctx.flutterPearRoot}/assets/desktop/$host/pear-end.bundle');
    if (!bundle.existsSync() || bundle.lengthSync() == 0) {
      missing.add(host);
    }
  }
  if (missing.isNotEmpty) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'flutter_pear/assets/desktop/ is missing a pear-end.bundle for: '
          '${missing.join(', ')}',
      remediation: _maintainerOnlyRemediation,
    );
  }
  return DoctorCheckResult(DoctorCheckStatus.pass,
      'pear-end.bundle present for every desktop host (${hosts.join(', ')})');
}

Future<DoctorCheckResult> _checkDeploymentTarget(
    DoctorMacosContext ctx) async {
  final packageSwift = File(
      '${ctx.flutterPearBareRoot}/macos/flutter_pear_bare/Package.swift');
  var minTarget = _minDeploymentTargetFallback;
  if (packageSwift.existsSync()) {
    final match =
        RegExp(r'\.macOS\("(\d+(?:\.\d+)?)"\)').firstMatch(packageSwift.readAsStringSync());
    if (match != null) minTarget = double.parse(match.group(1)!);
  }

  final pbxproj =
      File('${ctx.consumerRoot}/macos/Runner.xcodeproj/project.pbxproj');
  if (!pbxproj.existsSync()) {
    return const DoctorCheckResult(
      DoctorCheckStatus.skip,
      'Could not find macos/Runner.xcodeproj/project.pbxproj',
    );
  }
  final match = RegExp(r'MACOSX_DEPLOYMENT_TARGET = (\d+(?:\.\d+)?)')
      .firstMatch(pbxproj.readAsStringSync());
  if (match == null) {
    return const DoctorCheckResult(
      DoctorCheckStatus.skip,
      'Could not find MACOSX_DEPLOYMENT_TARGET in project.pbxproj',
    );
  }
  final actual = double.parse(match.group(1)!);
  if (actual < minTarget) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'macOS deployment target $actual (from project.pbxproj) is below '
          "flutter_pear's minimum ($minTarget)",
      remediation: 'Raise the macOS Deployment Target to $minTarget or '
          'higher in Xcode (Runner target > General).',
    );
  }
  return DoctorCheckResult(
    DoctorCheckStatus.pass,
    'macOS deployment target $actual (from project.pbxproj) meets the '
        'minimum ($minTarget)',
  );
}
