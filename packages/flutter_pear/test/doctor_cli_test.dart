import 'package:flutter_test/flutter_test.dart';

import '../bin/doctor.dart';

// Found via a live /devex-review pass: a project with a broken macOS
// entitlements file (Dart-side FAIL) but a healthy network (JS-side DHT +
// loopback checks pass) printed "All checks passed." as the literal LAST
// line of `dart run flutter_pear:doctor`'s output -- a skimming developer
// reading only the bottom line would conclude the project is ready when
// it isn't. isMisleadingAllClear() is the pure decision behind the
// corrective note bin/doctor.dart now prints in that exact scenario.

void main() {
  test('flags the exact scenario that produced a false all-clear', () {
    expect(
      isMisleadingAllClear(dartChecksOk: false, jsExitCode: 0),
      isTrue,
    );
  });

  test('does not flag when everything genuinely passed', () {
    expect(
      isMisleadingAllClear(dartChecksOk: true, jsExitCode: 0),
      isFalse,
    );
  });

  test(
      'does not flag when the JS side already reported its own failure -- '
      'no extra note needed, "Some checks failed" is already accurate', () {
    expect(
      isMisleadingAllClear(dartChecksOk: false, jsExitCode: 1),
      isFalse,
    );
  });

  test('does not flag when only the JS side failed', () {
    expect(
      isMisleadingAllClear(dartChecksOk: true, jsExitCode: 1),
      isFalse,
    );
  });
}
