// T1 exit gate test (flutter_pear-ovt.1.7): proves the REAL, iOS-capable
// pear-end bundle (all 12 native addons embedded, see BareKitShim/Package.swift)
// boots on the iOS simulator and the version handshake passes -- Pear.start()
// completing without a bundleVersionMismatch IS the assertion, since
// Pear.start already fetches attach.info and compares kPearEndBundleVersion
// internally (see pear.dart). Superseded T0's ios_spike_test.dart, which
// exercised the native-addon-free spike bundle instead.
import 'package:flutter_pear/flutter_pear.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'T1: Pear.start() boots the real pear-end bundle with all addons resolving',
      (tester) async {
    final pear = await Pear.start();
    addTearDown(pear.dispose);

    expect(pear.worklet.state, WorkletState.running);
  });
}
