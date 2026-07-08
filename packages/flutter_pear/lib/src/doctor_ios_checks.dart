import 'dart:convert';
import 'dart:io';

/// Status of a single iOS environment/pin-consistency check.
enum DoctorCheckStatus {
  /// The check ran and found nothing wrong.
  pass,

  /// The check ran and found a real problem -- folds into the doctor
  /// process's exit code.
  fail,

  /// The check could not meaningfully run (wrong OS, offline, a
  /// prerequisite file absent) -- never folds into the exit code.
  skip,

  /// Informational only -- neither a pass nor a failure signal, e.g. which
  /// packaging path was detected.
  info,
}

/// One check's outcome. [message] is the single-line summary rendered next
/// to the `[PASS]`/`[FAIL]`/`[SKIP]`/`[INFO]` tag. [remediation], when
/// present, is the actionable fix text -- for a consumer-fixable [status]
/// of [DoctorCheckStatus.fail] this names the exact command or edit to
/// make; for a maintainer-only condition (a corrupted install of this
/// plugin itself) it always says to file a GitHub issue, and NEVER tells a
/// pub.dev consumer to run `:pack` -- that tooling doesn't exist outside
/// this repo's own checkout.
class DoctorCheckResult {
  /// Creates a check result.
  const DoctorCheckResult(this.status, this.message, {this.remediation});

  /// This check's outcome.
  final DoctorCheckStatus status;

  /// A single-line human-readable summary.
  final String message;

  /// Actionable fix text, or `null` if [status] needs none (e.g. a pass).
  final String? remediation;

  /// Renders this result in the exact `[PASS]`/`[FAIL]`/`[SKIP]`/`[INFO]`
  /// line format `tool/doctor-checks.js` already uses, so Dart- and
  /// Node-produced lines read as one consistent stream regardless of which
  /// side printed which line.
  String render() {
    final tag = switch (status) {
      DoctorCheckStatus.pass => '[PASS]',
      DoctorCheckStatus.fail => '[FAIL]',
      DoctorCheckStatus.skip => '[SKIP]',
      DoctorCheckStatus.info => '[INFO]',
    };
    final line = '$tag $message';
    return remediation == null ? line : '$line\n$remediation';
  }
}

/// Runs an external [executable] with [args] and returns its result -- the
/// same shape as [Process.run]. Injectable so tests never need a real
/// Xcode/Flutter/`xcrun` installation.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> args,
);

Future<ProcessResult> _realProcessRunner(
        String executable, List<String> args) =>
    Process.run(executable, args);

/// Performs an HTTP HEAD request against [url] with [timeout] and returns
/// its status code. Injectable so tests never need real network access.
/// Implementations must throw on any network-level failure (DNS,
/// connection refused, timeout) -- callers treat a thrown error as
/// "offline", never as "the URL itself is broken" (that's a real HTTP
/// status code, handled separately).
typedef HttpHeadChecker = Future<int> Function(Uri url, Duration timeout);

Future<int> _realHttpHeadChecker(Uri url, Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.headUrl(url).timeout(timeout);
    final response = await request.close().timeout(timeout);
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// Minimum Xcode version flutter_pear's iOS support requires -- mirrors
/// this repo's own `COMPATIBILITY.md` "Xcode" column (kept in sync by
/// hand: a consumer's pub.dev install never has `COMPATIBILITY.md` at all,
/// so this constant, not that file, is the real runtime source of truth).
const _minXcodeVersion = (major: 15, minor: 0);

/// Minimum Flutter SDK version for Flutter's SwiftPM-default plugin
/// resolution path (the v0.2 iOS spike's own PREREQ-EVIDENCE finding).
/// Below this, `flutter pub add flutter_pear` still works, but iOS plugin
/// resolution falls back to a path this plugin has not been validated
/// against.
const _Version _minFlutterVersionForSpm = (3, 44, 0);

const _plistRemediationBlock = '''
Add this to ios/Runner/Info.plist:
  <key>NSLocalNetworkUsageDescription</key>
  <string>Describe your app's own use of the local network here.</string>''';

/// Everything a single doctor iOS check run needs, gathered in one place so
/// every check function takes exactly one argument -- and so tests can
/// swap every environment-touching piece ([processRunner], [httpHeadChecker],
/// [isMacOs]) for a fake without touching a real Xcode install or network.
class DoctorIosContext {
  /// Creates a context. Every field beyond [consumerRoot] and
  /// [flutterPearBareRoot] defaults to the real, environment-touching
  /// implementation -- tests override what they need to fake.
  const DoctorIosContext({
    required this.consumerRoot,
    required this.flutterPearBareRoot,
    this.isMacOs = true,
    this.processRunner = _realProcessRunner,
    this.httpHeadChecker = _realHttpHeadChecker,
    this.httpTimeout = const Duration(seconds: 5),
  });

  /// The consumer Flutter project's root directory (contains `ios/`,
  /// `pubspec.yaml`, ...) -- `Directory.current.path` in production.
  final String consumerRoot;

  /// The resolved `flutter_pear_bare` package's own root directory (its
  /// `pubspec.yaml`'s directory), found via `Isolate.resolvePackageUri` in
  /// production -- the same mechanism `bin/doctor.dart` already uses to
  /// locate `tool/doctor-checks.js` -- so these checks work identically
  /// from a real consumer install, not only inside this monorepo.
  final String flutterPearBareRoot;

  /// Whether this run is on macOS -- `Platform.isMacOS` in production.
  /// Every iOS check needs a real Mac (Xcode, simulators); on any other OS
  /// [runDoctorIosChecks] returns a single explanatory skip instead of
  /// running any of them.
  final bool isMacOs;

  /// Runs external processes (`xcodebuild`, `xcrun`, `flutter`).
  final ProcessRunner processRunner;

  /// Checks HTTP reachability of the pinned BareKit release URLs.
  final HttpHeadChecker httpHeadChecker;

  /// Timeout for each [httpHeadChecker] call.
  final Duration httpTimeout;
}

/// Runs every iOS environment/pin-consistency check and returns their
/// results in a fixed, stable order. On a non-macOS host, or a project with
/// no `ios/` directory, returns a single `iOS: not applicable` skip instead
/// of running anything else -- every other check assumes a real Mac with a
/// real `ios/` runner and would otherwise report a wall of confusing
/// failures for a condition that isn't actually a problem.
Future<List<DoctorCheckResult>> runDoctorIosChecks(
    DoctorIosContext ctx) async {
  if (!ctx.isMacOs) {
    return const [
      DoctorCheckResult(DoctorCheckStatus.skip,
          'iOS: not applicable (this doctor run is not on macOS)'),
    ];
  }
  if (!Directory('${ctx.consumerRoot}/ios').existsSync()) {
    return const [
      DoctorCheckResult(DoctorCheckStatus.skip,
          'iOS: not applicable (no ios/ directory in this project)'),
    ];
  }
  return [
    await _checkXcodePresent(ctx),
    await _checkSimulatorRuntime(ctx),
    ...await _checkPackagingPathAndFlutterVersion(ctx),
    await _checkInfoPlist(ctx),
    await _checkBarekitPinJson(ctx),
    ...await _checkPinUrlsReachable(ctx),
    await _checkCommittedAddons(ctx),
    await _checkDeploymentTarget(ctx),
  ];
}

/// Renders [results] as one newline-joined block of `[PASS]`/`[FAIL]`/
/// `[SKIP]`/`[INFO]` lines, matching `tool/doctor-checks.js`'s own format
/// exactly so the two sources read as one consistent stream.
String renderDoctorIosChecks(List<DoctorCheckResult> results) =>
    results.map((r) => r.render()).join('\n');

Future<DoctorCheckResult> _checkXcodePresent(DoctorIosContext ctx) async {
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
  return DoctorCheckResult(DoctorCheckStatus.pass, 'Xcode $major.$minor found');
}

Future<DoctorCheckResult> _checkSimulatorRuntime(DoctorIosContext ctx) async {
  final ProcessResult result;
  try {
    result =
        await ctx.processRunner('xcrun', ['simctl', 'list', 'runtimes', '-j']);
  } on ProcessException {
    return const DoctorCheckResult(
      DoctorCheckStatus.fail,
      'Could not run xcrun simctl (is Xcode installed and licensed?)',
      remediation: 'Run xcode-select --install, accept the Xcode license '
          '(sudo xcodebuild -license), then retry.',
    );
  }
  if (result.exitCode != 0) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'xcrun simctl list runtimes exited ${result.exitCode}',
      remediation: 'Run that command yourself to see the real error.',
    );
  }
  final Map<String, dynamic> json;
  try {
    json = jsonDecode('${result.stdout}') as Map<String, dynamic>;
  } catch (e) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'Could not parse xcrun simctl list runtimes -j output: $e',
      remediation: 'File a GitHub issue with this doctor output.',
    );
  }
  final runtimes = (json['runtimes'] as List?) ?? const [];
  final iosRuntimes = runtimes
      .cast<Map<String, dynamic>>()
      .where((r) => r['platform'] == 'iOS' && r['isAvailable'] == true)
      .toList();
  if (iosRuntimes.isEmpty) {
    return const DoctorCheckResult(
      DoctorCheckStatus.fail,
      'No available iOS Simulator runtime installed',
      remediation: 'Install one via Xcode > Settings > Platforms, or run '
          'xcodebuild -downloadPlatform iOS.',
    );
  }
  final names = iosRuntimes.map((r) => r['name']).join(', ');
  return DoctorCheckResult(
      DoctorCheckStatus.pass, 'iOS Simulator runtime(s) available: $names');
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

Future<List<DoctorCheckResult>> _checkPackagingPathAndFlutterVersion(
    DoctorIosContext ctx) async {
  final usesCocoaPods = File('${ctx.consumerRoot}/ios/Podfile').existsSync();
  final pathInfo = DoctorCheckResult(
    DoctorCheckStatus.info,
    usesCocoaPods
        ? 'CocoaPods compat path detected (ios/Podfile present)'
        : 'SwiftPM path detected (default -- no ios/Podfile)',
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
        remediation: 'Upgrade Flutter (flutter upgrade), or add an '
            'ios/Podfile to use the CocoaPods compat path instead.',
      ),
    ];
  }
  return [
    pathInfo,
    DoctorCheckResult(DoctorCheckStatus.pass,
        'Flutter $versionStr is compatible with the detected packaging path'),
  ];
}

Future<DoctorCheckResult> _checkInfoPlist(DoctorIosContext ctx) async {
  final plist = File('${ctx.consumerRoot}/ios/Runner/Info.plist');
  if (!plist.existsSync()) {
    return const DoctorCheckResult(
      DoctorCheckStatus.skip,
      'ios/Runner/Info.plist not found -- not a standard Flutter iOS '
          'project layout',
    );
  }
  final text = plist.readAsStringSync();
  if (!text.contains('NSLocalNetworkUsageDescription')) {
    return const DoctorCheckResult(
      DoctorCheckStatus.fail,
      'ios/Runner/Info.plist is missing NSLocalNetworkUsageDescription -- '
          'same-Wi-Fi peers will silently fail to connect on a real '
          'device (the simulator does not enforce this check)',
      remediation: _plistRemediationBlock,
    );
  }
  return const DoctorCheckResult(DoctorCheckStatus.pass,
      'ios/Runner/Info.plist has NSLocalNetworkUsageDescription');
}

const _maintainerOnlyRemediation = 'This indicates a corrupted install of '
    'flutter_pear_bare itself, not something fixable in your own project -- '
    'try dart pub cache repair, or file a GitHub issue if it persists.';

Future<DoctorCheckResult> _checkBarekitPinJson(DoctorIosContext ctx) async {
  final pinFile = File('${ctx.flutterPearBareRoot}/barekit-pin.json');
  if (!pinFile.existsSync()) {
    return const DoctorCheckResult(
      DoctorCheckStatus.fail,
      "flutter_pear_bare's barekit-pin.json is missing from the installed "
          'package',
      remediation: _maintainerOnlyRemediation,
    );
  }
  final Map<String, dynamic> json;
  try {
    json = jsonDecode(pinFile.readAsStringSync()) as Map<String, dynamic>;
  } catch (e) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'barekit-pin.json could not be parsed as JSON: $e',
      remediation: _maintainerOnlyRemediation,
    );
  }
  final problems = <String>[];
  for (final urlKey in ['upstreamUrl', 'repackedUrl']) {
    final value = json[urlKey] as String?;
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https') {
      problems.add('$urlKey is missing or not a well-formed https:// URL');
    }
  }
  for (final shaKey in ['upstreamSha256', 'repackedSha256']) {
    final value = json[shaKey] as String?;
    if (value == null || !RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
      problems
          .add('$shaKey is missing or not a 64-char lowercase hex string');
    }
  }
  if (problems.isNotEmpty) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'barekit-pin.json is malformed: ${problems.join('; ')}',
      remediation: _maintainerOnlyRemediation,
    );
  }
  return const DoctorCheckResult(
      DoctorCheckStatus.pass, 'barekit-pin.json is well-formed');
}

Future<List<DoctorCheckResult>> _checkPinUrlsReachable(
    DoctorIosContext ctx) async {
  final pinFile = File('${ctx.flutterPearBareRoot}/barekit-pin.json');
  if (!pinFile.existsSync()) {
    return const []; // already reported by _checkBarekitPinJson
  }
  final Map<String, dynamic> json;
  try {
    json = jsonDecode(pinFile.readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return const []; // already reported by _checkBarekitPinJson
  }
  final results = <DoctorCheckResult>[];
  for (final urlKey in ['upstreamUrl', 'repackedUrl']) {
    final value = json[urlKey] as String?;
    final uri = value == null ? null : Uri.tryParse(value);
    if (uri == null || uri.scheme != 'https') {
      continue; // already reported by _checkBarekitPinJson
    }
    results.add(await _checkOneUrlReachable(ctx, urlKey, uri));
  }
  return results;
}

Future<DoctorCheckResult> _checkOneUrlReachable(
    DoctorIosContext ctx, String label, Uri uri) async {
  try {
    final status = await ctx.httpHeadChecker(uri, ctx.httpTimeout);
    if (status >= 200 && status < 400) {
      return DoctorCheckResult(
          DoctorCheckStatus.pass, '$label reachable (HTTP $status)');
    }
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      '$label returned HTTP $status',
      remediation: status == 404
          ? 'The pinned release asset may have been deleted -- file a '
              'GitHub issue.'
          : 'Retry later; if this persists, file a GitHub issue.',
    );
  } catch (_) {
    return DoctorCheckResult(
      DoctorCheckStatus.skip,
      '$label reachability check skipped -- could not reach the network '
          '(offline, or this host blocks outbound HTTPS)',
    );
  }
}

Future<DoctorCheckResult> _checkCommittedAddons(DoctorIosContext ctx) async {
  final addonsDir = Directory('${ctx.flutterPearBareRoot}/ios/addons');
  if (!addonsDir.existsSync()) {
    return const DoctorCheckResult(
      DoctorCheckStatus.fail,
      'flutter_pear_bare/ios/addons/ is missing from the installed package',
      remediation: _maintainerOnlyRemediation,
    );
  }
  final xcframeworks = addonsDir
      .listSync()
      .whereType<Directory>()
      .where((d) => d.path.endsWith('.xcframework'))
      .toList();
  if (xcframeworks.isEmpty) {
    return const DoctorCheckResult(
      DoctorCheckStatus.fail,
      'flutter_pear_bare/ios/addons/ has no .xcframework bundles',
      remediation: _maintainerOnlyRemediation,
    );
  }
  return DoctorCheckResult(DoctorCheckStatus.pass,
      '${xcframeworks.length} addon xcframework(s) present');
}

Future<DoctorCheckResult> _checkDeploymentTarget(DoctorIosContext ctx) async {
  final packageSwift =
      File('${ctx.flutterPearBareRoot}/ios/flutter_pear_bare/Package.swift');
  var minMajor = 13; // fallback if Package.swift isn't resolvable
  if (packageSwift.existsSync()) {
    final match = RegExp(r'\.iOS\(\.v(\d+)\)')
        .firstMatch(packageSwift.readAsStringSync());
    if (match != null) minMajor = int.parse(match.group(1)!);
  }

  final pbxproj =
      File('${ctx.consumerRoot}/ios/Runner.xcodeproj/project.pbxproj');
  final podfile = File('${ctx.consumerRoot}/ios/Podfile');
  String? source;
  double? actual;
  if (pbxproj.existsSync()) {
    final match = RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = (\d+(?:\.\d+)?)')
        .firstMatch(pbxproj.readAsStringSync());
    if (match != null) {
      actual = double.parse(match.group(1)!);
      source = 'ios/Runner.xcodeproj/project.pbxproj';
    }
  }
  if (actual == null && podfile.existsSync()) {
    final match = RegExp("platform\\s*:ios,\\s*'(\\d+(?:\\.\\d+)?)'")
        .firstMatch(podfile.readAsStringSync());
    if (match != null) {
      actual = double.parse(match.group(1)!);
      source = 'ios/Podfile';
    }
  }
  if (actual == null) {
    return const DoctorCheckResult(
      DoctorCheckStatus.skip,
      'Could not find an iOS deployment target in project.pbxproj or '
          'Podfile',
    );
  }
  if (actual < minMajor) {
    return DoctorCheckResult(
      DoctorCheckStatus.fail,
      'iOS deployment target $actual (from $source) is below '
          "flutter_pear's minimum ($minMajor.0)",
      remediation: 'Raise the iOS Deployment Target to $minMajor.0 or '
          'higher in Xcode (Runner target > General), or in '
          "ios/Podfile's platform line.",
    );
  }
  return DoctorCheckResult(
    DoctorCheckStatus.pass,
    'iOS deployment target $actual (from $source) meets the minimum '
        '($minMajor.0)',
  );
}
