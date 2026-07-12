import 'package:flutter/foundation.dart';
import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android: bestEffort + device', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(Pear.platformInfo.backgroundExecution,
        PearBackgroundExecution.bestEffort);
    expect(Pear.platformInfo.validationTier, PearValidationTier.device);
  });

  test('iOS: foregroundOnly + simulator (D11)', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(Pear.platformInfo.backgroundExecution,
        PearBackgroundExecution.foregroundOnly);
    expect(Pear.platformInfo.validationTier, PearValidationTier.simulator);
  });

  test('macOS: unrestricted + device (E-D4, flutter_pear-iqp)', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(Pear.platformInfo.backgroundExecution,
        PearBackgroundExecution.unrestricted);
    expect(Pear.platformInfo.validationTier, PearValidationTier.device);
  });

  test('Linux: unrestricted + device (E-D2c, flutter_pear-65g) -- same '
      'pin as macOS, same subprocess-with-no-OS-suspension rationale', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(Pear.platformInfo.backgroundExecution,
        PearBackgroundExecution.unrestricted);
    expect(Pear.platformInfo.validationTier, PearValidationTier.device);
  });

  test('Windows: unrestricted + device (E-D2b, flutter_pear-pfp) -- same '
      'pin as macOS/Linux, same subprocess-with-no-OS-suspension rationale',
      () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(Pear.platformInfo.backgroundExecution,
        PearBackgroundExecution.unrestricted);
    expect(Pear.platformInfo.validationTier, PearValidationTier.device);
  });

  test(
      'an unsupported platform throws, naming android, iOS, macOS, Linux, '
      'and Windows', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;
    expect(
      () => Pear.platformInfo,
      throwsA(isA<UnsupportedError>().having(
        (e) => e.message,
        'message',
        allOf(
          contains('android'),
          contains('iOS'),
          contains('macOS'),
          contains('linux'),
          contains('windows'),
        ),
      )),
    );
  });

  test('PearPlatformInfo equality/hashCode/toString', () {
    const a = PearPlatformInfo(
      backgroundExecution: PearBackgroundExecution.bestEffort,
      validationTier: PearValidationTier.device,
    );
    const b = PearPlatformInfo(
      backgroundExecution: PearBackgroundExecution.bestEffort,
      validationTier: PearValidationTier.device,
    );
    const c = PearPlatformInfo(
      backgroundExecution: PearBackgroundExecution.foregroundOnly,
      validationTier: PearValidationTier.simulator,
    );
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
    expect(a.toString(), contains('bestEffort'));
    expect(a.toString(), contains('device'));
  });
}
