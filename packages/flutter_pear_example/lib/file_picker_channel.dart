import 'package:flutter/services.dart';

/// A file picked via [FilePickerChannel.pickFile].
///
/// [path] is a *local* absolute file path (the picked document's content
/// copied into this app's cache directory), never a `content://` URI --
/// this is what [PearDrive.put] requires, since it streams by local file
/// path rather than in-memory bytes.
///
/// [name] is the picked file's original display name, independent of
/// whatever name it was copied under on disk.
class PickedFile {
  /// Creates a picked-file record.
  const PickedFile({required this.path, required this.name});

  /// The local absolute path to the copied file.
  final String path;

  /// The original display name of the picked file.
  final String name;
}

/// Thin Dart wrapper around the native "flutter_pear_example/file_picker"
/// method channel -- the hand-rolled Storage Access Framework file picker
/// owned directly by this app's own `android/app` module, not a Flutter
/// plugin (see CLAUDE.md / bd `flutter_pear-jqe` for why: this project's
/// AGP/Kotlin toolchain has a confirmed structural incompatibility with
/// every camera/permission Flutter plugin found, including `file_picker`
/// itself). Unlike the QR scanner's camera permission, SAF file picking
/// needs no runtime permission at all -- the system document picker handles
/// the access grant transparently.
class FilePickerChannel {
  FilePickerChannel._();

  /// The channel this wrapper talks to. `static const` so it costs nothing
  /// until first use and never needs disposal.
  static const _channel = MethodChannel('flutter_pear_example/file_picker');

  /// Launches the system's SAF document picker (any file type selectable)
  /// and returns the picked file's local copy path and original name, or
  /// `null` if the user backed out without picking anything.
  ///
  /// Throws a [PlatformException] if the native side fails to resolve the
  /// picked document (for example, if copying its content into this app's
  /// cache directory fails).
  static Future<PickedFile?> pickFile() async {
    final raw = await _channel.invokeMapMethod<String, String>('pickFile');
    if (raw == null) return null;
    return PickedFile(path: raw['path']!, name: raw['name']!);
  }
}
