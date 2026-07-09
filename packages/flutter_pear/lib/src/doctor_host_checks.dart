import 'doctor_ios_checks.dart' show DoctorCheckResult, DoctorCheckStatus;

/// Host-capability check (flutter_pear-l0w): tells a developer, in their own
/// terminal, which flutter_pear build targets their CURRENT machine can
/// build for -- Android works on any host; iOS needs a real Mac with Xcode
/// (Apple's own platform constraint, not a flutter_pear limitation).
/// Complements [runDoctorIosChecks]'s "iOS: not applicable" skip (which only
/// covers the iOS half) with the missing "Android still works" half -- a
/// Windows/Linux dev previously had no in-tool signal that their build path
/// is fine.
///
/// Everything [checkHostCapability] needs, gathered so it never touches
/// `dart:io`'s `Platform` directly -- tests supply a fake operating system
/// name instead of needing three real machines to cover macOS/Linux/Windows.
class DoctorHostContext {
  /// Creates a context. [operatingSystem] is `Platform.operatingSystem` in
  /// production (`"macos"`, `"linux"`, `"windows"`, ...).
  const DoctorHostContext({required this.operatingSystem});

  /// The current host's OS name, lowercase -- `Platform.operatingSystem`'s
  /// own format in production.
  final String operatingSystem;
}

const _iosConstraint = 'iOS build unavailable (requires macOS + Xcode -- an '
    'Apple platform constraint, not a flutter_pear limitation)';

/// doc/desktop-dev.md (flutter_pear-c8o) -- the full Windows/Linux dev
/// setup guide this message points a non-macOS host at. A GitHub blob URL,
/// not a relative path: a real pub.dev consumer's own project has no
/// predictable local copy of this repo's doc/ tree to link to.
const _desktopDevDocUrl = 'https://github.com/andrewloable/flutter_pear/'
    'blob/main/packages/flutter_pear/doc/desktop-dev.md';

/// Reports which flutter_pear build targets [ctx]'s host can build for.
/// Always [DoctorCheckStatus.info] -- this states a fact about the host, not
/// a problem to fix, so it can never fold into doctor's exit code the way a
/// genuine [DoctorCheckStatus.fail] does (unlike the iOS section's own
/// checks, this never requires Xcode/network/a real Mac to evaluate).
DoctorCheckResult checkHostCapability(DoctorHostContext ctx) {
  final message = switch (ctx.operatingSystem) {
    'macos' => 'Host: macOS -> Android + iOS builds available',
    'linux' => 'Host: Linux -> Android build available; $_iosConstraint. '
        'See $_desktopDevDocUrl for the full dev setup guide.',
    'windows' =>
      'Host: Windows -> Android build available; $_iosConstraint. '
          'See $_desktopDevDocUrl for the full dev setup guide.',
    final other =>
      'Host: $other -> Android build likely available; $_iosConstraint. '
          'See $_desktopDevDocUrl for the full dev setup guide.',
  };
  return DoctorCheckResult(DoctorCheckStatus.info, message);
}
