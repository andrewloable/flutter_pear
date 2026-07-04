import 'package:flutter/services.dart';

/// The camera permission's current state, as reported by the native side of
/// the "flutter_pear_example/qr_scanner" method channel.
///
/// Android exposes no direct "permanently denied" signal -- [permanentlyDenied]
/// is inferred natively from `shouldShowRequestPermissionRationale` returning
/// false *after* a request has already been made once (the same heuristic
/// real permission-status libraries use). See [QrScannerChannel] for the
/// full contract this enum round-trips through.
enum CameraPermissionStatus {
  /// The permission is currently granted.
  granted,

  /// Not granted, but the OS will still show the request dialog again (the
  /// user hasn't checked "don't ask again" / device policy doesn't block it).
  denied,

  /// Not granted, and the OS will no longer show the request dialog --
  /// the only way forward is [QrScannerChannel.openAppSettings].
  permanentlyDenied,

  /// Never asked yet -- the OS permission dialog hasn't been shown to this
  /// user before.
  notDetermined,
}

/// Parses the raw strings the native side sends -- an unrecognized value
/// (there should never be one, but a channel contract is still a boundary)
/// surfaces as a [FormatException] rather than a silent wrong enum value or
/// a crash.
CameraPermissionStatus _parsePermissionStatus(String raw) => switch (raw) {
      'granted' => CameraPermissionStatus.granted,
      'denied' => CameraPermissionStatus.denied,
      'permanentlyDenied' => CameraPermissionStatus.permanentlyDenied,
      'notDetermined' => CameraPermissionStatus.notDetermined,
      _ => throw FormatException('unknown CameraPermissionStatus', raw),
    };

/// Thin Dart wrapper around the native "flutter_pear_example/qr_scanner"
/// method channel (E7.2) -- the hand-rolled CameraX + ML Kit QR scanner
/// owned directly by this app's own `android/app` module, not a Flutter
/// plugin (see CLAUDE.md / bd `flutter_pear-jqe` for why: this project's
/// AGP/Kotlin toolchain has a confirmed structural incompatibility with
/// every camera/permission Flutter plugin found).
class QrScannerChannel {
  QrScannerChannel._();

  /// The single channel every static method below talks to. `static const`
  /// so it costs nothing until first use and never needs disposal.
  static const _channel = MethodChannel('flutter_pear_example/qr_scanner');

  /// Checks the camera permission's current status without prompting the
  /// user.
  static Future<CameraPermissionStatus> checkPermission() async {
    final raw = await _channel.invokeMethod<String>('checkCameraPermission');
    return _parsePermissionStatus(raw!);
  }

  /// Requests the camera permission, resolving only once the OS dialog (if
  /// one was shown) closes. Resolves immediately with [CameraPermissionStatus.granted]
  /// if already granted -- never re-prompts a user who's already said yes.
  static Future<CameraPermissionStatus> requestPermission() async {
    final raw = await _channel.invokeMethod<String>('requestCameraPermission');
    return _parsePermissionStatus(raw!);
  }

  /// Launches the native full-screen QR scanner and returns the decoded
  /// string from the first QR code it reads, or `null` if the user backed
  /// out without scanning anything. Throws a [PlatformException] with code
  /// `"PERMISSION_DENIED"` if camera permission isn't currently granted --
  /// callers should always gate this behind [checkPermission] /
  /// [requestPermission] returning [CameraPermissionStatus.granted] first.
  static Future<String?> scanQrCode() =>
      _channel.invokeMethod<String>('scanQrCode');

  /// Opens this app's system settings page (for a user who's permanently
  /// denied camera access and needs to flip it back on manually).
  static Future<void> openAppSettings() =>
      _channel.invokeMethod<bool>('openAppSettings');
}
