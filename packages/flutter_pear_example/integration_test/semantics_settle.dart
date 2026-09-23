// Workaround for flutter_pear-3dq, an UPSTREAM Flutter/macOS defect. Not a
// flutter_pear bug, and not a permanent fix -- delete this file and its call
// sites once upstream lands a real one.
//
// THE BUG: flutter_test's "A SemanticsHandle was active at the end of the
// test" check is a DELTA, not an absolute. _recordNumberOfSemanticsHandles()
// snapshots a baseline and _verifySemanticsHandlesWereDisposed() throws only
// if the count is HIGHER afterwards (see flutter_test/src/widget_tester.dart).
// A do-nothing macOS integration test sits at 2 handles and passes fine.
//
// The macOS embedder acquires one of those handles ASYNCHRONOUSLY during
// startup. Land it before the baseline and everything passes; land it inside
// a test body and the count rises and that test fails. Traced by polling
// SemanticsBinding.instance.debugOutstandingSemanticsHandles every 250ms:
//
//   failing run:  t=0 handles=1  ->  CHANGE 1 -> 2  ->  end 2
//   passing runs: t=0 handles=2  ->  (no change)    ->  end 2
//
// The handle is engine-owned: flutter_pear neither creates nor can dispose
// it, so no amount of cleanup or ordering in our own code prevents this.
// Upstream already hardcodes a correction for the same class of engine leak
// on web -- knownWebEngineLeakForLiveTestsCorrection, TODO(goderbauer),
// https://github.com/flutter/flutter/issues/121640 -- and macOS desktop needs
// the same treatment.
//
// THE FIX HERE: package:test runs setUpAll BEFORE the closure that captures
// the baseline, so waiting in setUpAll lets the embedder finish first. The
// baseline then already includes that handle and nothing rises mid-body.
//
// This does NOT suppress anything: no tester.ensureSemantics(), no dropped
// macOS leg, no caught or tolerated error. The assertion still runs and still
// catches a genuine handle leak introduced by test code.
//
// MEASURED on the same probe (25s of sustained worklet IPC, -d macos):
//   without this: 2 failures of 6   (baselines seen: 1 once, 2 five times)
//   with this:    0 failures of 14  (baseline 2 in all 14, never 1)
// Under an unchanged ~33% failure rate, 0-of-14 has p ~= 0.003.
//
// KNOWN LIMITS, do not oversell it: one failure without the workaround
// started at baseline 2 and rose to 3, which "wait for the startup handle"
// does not explain, so a second and rarer acquisition path may exist. And
// this is a fixed sleep tuned on one machine -- a slower or busier host could
// still lose the race. It is a mitigation, not a guarantee.
//
// REJECTED ALTERNATIVE: holding our own handle for the session
// (ensureSemantics in setUpAll) does nothing, because it raises the baseline
// and the end count equally and the engine's later acquisition still pushes
// the delta positive.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// How long to let the macOS embedder settle. 4s is what was validated
/// above; it is a race, so this is a margin rather than a known bound.
const _macosSemanticsSettle = Duration(seconds: 4);

/// Registers a `setUpAll` that lets macOS finish acquiring its startup
/// semantics handle before flutter_test captures its per-test baseline.
///
/// Call once at the top of `main()`, right after
/// `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`. A no-op off
/// macOS, so Android and iOS runs pay nothing.
void settleSemanticsBeforeBaseline() {
  if (!Platform.isMacOS) return;
  setUpAll(() async => Future<void>.delayed(_macosSemanticsSettle));
}
