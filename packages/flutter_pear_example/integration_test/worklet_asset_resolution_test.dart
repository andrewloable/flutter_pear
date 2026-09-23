// Smoke test for the DEFAULT bundled-asset resolution path: starting a
// worklet with no explicit `bundlePath` must find the pear-end asset inside
// the built app and reach a running state.
//
// Worth its own file because that path is resolved by NATIVE code, differs
// per platform (each host locates the asset its own way), and no unit test
// can reach it -- the fake worklet in flutter_pear_test never touches a real
// bundle. It is also exactly the class of breakage that shipped broken
// before: an iOS release where the binary dependency could not be resolved
// at all got through because nothing built the real app on that platform.
//
// Passing an explicit `bundlePath` would skip asset resolution entirely and
// defeat the purpose, so this deliberately does not.
//
//   flutter test integration_test/worklet_asset_resolution_test.dart -d macos
//   (likewise -d <android-emulator> / -d <ios-simulator>)
import 'package:flutter_pear_bare/flutter_pear_bare.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'semantics_settle.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  settleSemanticsBeforeBaseline();

  testWidgets('the bundled pear-end asset resolves and the worklet starts',
      (tester) async {
    // No bundlePath on purpose -- see this file's header.
    final worklet =
        await BareWorklet.start().timeout(const Duration(seconds: 30));
    addTearDown(worklet.terminate);

    expect(worklet.state, WorkletState.running);
  });
}
