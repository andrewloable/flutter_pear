/// Whether the worklet keeps running while the app is backgrounded (DX2-55,
/// D17 — both this and [PearValidationTier] SHIP; do not relitigate).
///
/// Branch UX on THIS field, never [PearValidationTier] — it's the one that
/// describes what actually happens to a connection while backgrounded.
enum PearBackgroundExecution {
  /// The worklet only reliably stays connected while the app is in the
  /// foreground. Backgrounding may drop peer connections at any time, with
  /// no guarantee of how long a connection survives first — the OS, not
  /// this library, decides.
  foregroundOnly,

  /// The worklet is actively kept alive for some bounded window after
  /// backgrounding (see `PearLifecycle`'s `linger`), on a best-effort basis
  /// — the OS can still reclaim the process at any time; nothing here is a
  /// guarantee.
  bestEffort,

  /// The worklet keeps running exactly as if foregrounded, with no
  /// OS-imposed background execution limit at all (flutter_pear-iqp, E-D4)
  /// — desktop platforms, unlike mobile, do not suspend or throttle a
  /// backgrounded/minimized app's process. Still not an absolute guarantee:
  /// the user or OS can always quit the app outright.
  unrestricted,
}

/// The validation basis of THIS release on this platform — pinned per
/// platform, updated only at release time, never runtime-detected (it does
/// not describe the device this code happens to be running on right now).
///
/// This is a release-process fact, not a UX signal — branch app behavior on
/// [PearBackgroundExecution] instead; `COMPATIBILITY.md` is the source of
/// truth this field is gate-checked against.
enum PearValidationTier {
  /// Validated on a simulator only; no physical-device confirmation for
  /// this release.
  simulator,

  /// Validated on an emulator only; no physical-device confirmation for
  /// this release.
  emulator,

  /// Validated on physical hardware for this release.
  device,
}

/// This platform's pinned [PearBackgroundExecution] and [PearValidationTier]
/// — see [Pear.platformInfo].
class PearPlatformInfo {
  /// Const constructor — both fields are release-pinned platform constants.
  const PearPlatformInfo({
    required this.backgroundExecution,
    required this.validationTier,
  });

  /// Whether the worklet keeps running while backgrounded on this platform.
  final PearBackgroundExecution backgroundExecution;

  /// The validation basis of this release on this platform.
  final PearValidationTier validationTier;

  @override
  bool operator ==(Object other) =>
      other is PearPlatformInfo &&
      other.backgroundExecution == backgroundExecution &&
      other.validationTier == validationTier;

  @override
  int get hashCode => Object.hash(backgroundExecution, validationTier);

  @override
  String toString() => 'PearPlatformInfo(backgroundExecution: '
      '$backgroundExecution, validationTier: $validationTier)';
}
