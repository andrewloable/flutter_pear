import 'package:flutter_pear/src/doctor_host_checks.dart';
import 'package:flutter_pear/src/doctor_ios_checks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('checkHostCapability', () {
    test('macOS reports both Android and iOS builds available', () {
      final result =
          checkHostCapability(const DoctorHostContext(operatingSystem: 'macos'));
      expect(result.status, DoctorCheckStatus.info);
      expect(result.message, contains('macOS'));
      expect(result.message, contains('Android'));
      expect(result.message, contains('iOS'));
      expect(result.message, contains('available'));
      expect(result.message, isNot(contains('unavailable')));
    });

    test('Linux reports Android available, iOS unavailable with the real '
        'reason (macOS + Xcode requirement, not a flutter_pear limitation)',
        () {
      final result =
          checkHostCapability(const DoctorHostContext(operatingSystem: 'linux'));
      expect(result.status, DoctorCheckStatus.info);
      expect(result.message, contains('Linux'));
      expect(result.message, contains('Android build available'));
      expect(result.message, contains('iOS build unavailable'));
      expect(result.message, contains('requires macOS + Xcode'));
      expect(result.message, contains('not a flutter_pear limitation'));
    });

    test('Windows reports Android available, iOS unavailable with the same '
        'reason as Linux', () {
      final result = checkHostCapability(
          const DoctorHostContext(operatingSystem: 'windows'));
      expect(result.status, DoctorCheckStatus.info);
      expect(result.message, contains('Windows'));
      expect(result.message, contains('Android build available'));
      expect(result.message, contains('iOS build unavailable'));
      expect(result.message, contains('requires macOS + Xcode'));
    });

    test('an unrecognized host OS still gets a sensible fallback verdict, '
        'not a crash or an empty message', () {
      final result = checkHostCapability(
          const DoctorHostContext(operatingSystem: 'fuchsia'));
      expect(result.status, DoctorCheckStatus.info);
      expect(result.message, contains('fuchsia'));
      expect(result.message, contains('Android'));
      expect(result.message, contains('iOS build unavailable'));
    });

    test('status is NEVER fail on any host -- this is a fact about the '
        'host, not a problem needing remediation, and must never fold '
        'into doctor\'s exit code the way a genuine check failure does',
        () {
      for (final os in ['macos', 'linux', 'windows', 'android', 'ios',
          'fuchsia', 'something-unheard-of']) {
        final result =
            checkHostCapability(DoctorHostContext(operatingSystem: os));
        expect(result.status, isNot(DoctorCheckStatus.fail),
            reason: 'checkHostCapability($os) must never FAIL');
        expect(result.remediation, isNull,
            reason: 'an info-status result should carry no remediation');
      }
    });

    test('render() produces the [INFO] tag matching the rest of doctor\'s '
        'output format', () {
      final result =
          checkHostCapability(const DoctorHostContext(operatingSystem: 'linux'));
      expect(result.render(), startsWith('[INFO] '));
    });

    test('Linux/Windows/unrecognized hosts point at doc/desktop-dev.md '
        '(flutter_pear-c8o) -- the full setup guide; macOS does not, since '
        'that guide is for non-macOS hosts specifically', () {
      const docUrl = 'https://github.com/andrewloable/flutter_pear/blob/'
          'main/packages/flutter_pear/doc/desktop-dev.md';
      for (final os in ['linux', 'windows', 'fuchsia']) {
        final result =
            checkHostCapability(DoctorHostContext(operatingSystem: os));
        expect(result.message, contains(docUrl),
            reason: '$os should point at the desktop dev setup guide');
      }
      final macResult =
          checkHostCapability(const DoctorHostContext(operatingSystem: 'macos'));
      expect(macResult.message, isNot(contains(docUrl)),
          reason: 'macOS needs no non-macOS setup guide pointer');
    });

    test('the Windows message is identical to the Linux message except for '
        'the OS name itself -- both hosts get the same reason and the same '
        'doc pointer, not two independently-drifting message strings', () {
      final linux = checkHostCapability(
          const DoctorHostContext(operatingSystem: 'linux'));
      final windows = checkHostCapability(
          const DoctorHostContext(operatingSystem: 'windows'));
      expect(linux.message.replaceAll('Linux', 'Windows'), windows.message);
    });
  });
}
