import 'package:flutter/services.dart';

/// Thin Dart wrapper around the native "flutter_pear_example/share_open"
/// method channel -- opens or shares a received file (or shares plain text)
/// via the platform's own affordance: `FileProvider` + `ACTION_VIEW`/
/// `ACTION_SEND` on Android, `UIDocumentInteractionController`/
/// `UIActivityViewController` on iOS. Hand-rolled and owned directly by this
/// app's native modules, same reasoning as [FilePickerChannel]'s doc (see
/// CLAUDE.md / bd `flutter_pear-jqe`).
///
/// Every method returns `false` (never throws) when the platform simply has
/// no app able to handle the request -- callers show a snackbar for that.
/// A [PlatformException] still travels through for a genuine native-side
/// failure (a bad path, a missing argument).
class ShareOpenChannel {
  ShareOpenChannel._();

  static const _channel = MethodChannel('flutter_pear_example/share_open');

  /// Opens the file at [path] in whatever app the platform resolves for it
  /// (a content preview on iOS, `ACTION_VIEW` via a `content://` URI on
  /// Android). Returns `false` if no app could handle it.
  static Future<bool> openFile(String path) async {
    final opened = await _channel.invokeMethod<bool>('openFile', {'path': path});
    return opened ?? false;
  }

  /// Shares the file at [path] via the platform's share sheet. Returns
  /// `false` if no app could handle it.
  static Future<bool> shareFile(String path) async {
    final shared = await _channel.invokeMethod<bool>('shareFile', {'path': path});
    return shared ?? false;
  }

  /// Shares plain [text] (an invite link, for example) via the platform's
  /// share sheet. Returns `false` if no app could handle it.
  static Future<bool> shareText(String text) async {
    final shared = await _channel.invokeMethod<bool>('shareText', {'text': text});
    return shared ?? false;
  }
}
