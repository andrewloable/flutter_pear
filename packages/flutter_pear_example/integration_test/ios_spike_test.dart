// THROWAWAY T0 spike test (flutter_pear-ovt.1.4): proves BareKit + IPC +
// bare-rpc ping through the REAL BareWorklet channel stack on the iOS
// simulator, against the minimal native-addon-free spike bundle (see
// flutter_pear-ovt.1.3's packages/flutter_pear/pear-end/spike/ios-spike.js).
// Not part of the real test suite -- exercises no packaging/host formalization.
import 'package:flutter_pear/src/rpc.dart';
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear_bare/flutter_pear_bare.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Skipped: flutter_pear-ovt.1.7 switched SpikeBareHost to load the REAL
  // assets/pear-end.bundle -- this spike bundle is no longer wired up. Kept
  // for T0 historical evidence; see ios_real_bundle_test.dart for T1.
  testWidgets('T0: attach.info round-trips against the ios-spike bundle, twice',
      skip: true, (tester) async {
    // bundlePath is a no-op on both native hosts today (E1's custom-worklet
    // advanced path isn't wired up yet) -- the spike host hardcodes its own
    // asset lookup instead, same as the real hosts hardcode assets/pear-end.bundle.
    final worklet = await BareWorklet.start();
    final rpc = PearRpc(worklet);

    final first = await rpc.call(PearMethod.attachInfo) as Map;
    expect(first[PearHandshakeField.bundleVersion], 'ios-spike');

    final second = await rpc.call(PearMethod.attachInfo) as Map;
    expect(second[PearHandshakeField.bundleVersion], 'ios-spike');
  });
}
