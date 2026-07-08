import 'dart:convert';
import 'dart:typed_data';

/// The transfer envelope's current wire version (Eng review round 2 item
/// 4). This is app-layer message content sent over an existing
/// `PearConnection`'s data channel — same layer as the chat demo's plain
/// text messages, never a protocol change; all P2P logic stays in the JS
/// worklet.
const envelopeVersion = 1;

/// One message in the versioned JSON transfer envelope — see
/// [decodeEnvelope] for the decode-side contract.
sealed class TransferMessage {
  const TransferMessage();

  /// Encodes this message as UTF-8 JSON bytes: `{v, type, ...fields}`.
  Uint8List toBytes();
}

/// Announces the sender's drive key so the receiver can open/mirror it.
final class DriveAnnounce extends TransferMessage {
  /// [driveKeyHex] is the announcing peer's drive key, hex-encoded.
  const DriveAnnounce(this.driveKeyHex);

  /// The announcing peer's drive key, hex-encoded.
  final String driveKeyHex;

  @override
  Uint8List toBytes() => _encode({
        'v': envelopeVersion,
        'type': 'driveAnnounce',
        'driveKey': driveKeyHex,
      });

  @override
  bool operator ==(Object other) =>
      other is DriveAnnounce && other.driveKeyHex == driveKeyHex;

  @override
  int get hashCode => driveKeyHex.hashCode;

  @override
  String toString() => 'DriveAnnounce($driveKeyHex)';
}

/// Announces one file now available on the sender's already-announced
/// drive, so the receiver can trigger an automatic receive — the ONLY
/// signal that does, since `PearDrive` exposes no watch/progress stream
/// (put/get/exists/list/mirrorToDisk are plain `Future`s).
final class FileAnnounce extends TransferMessage {
  /// [name] is the file's name; [size] is its size in bytes.
  const FileAnnounce(this.name, this.size);

  /// The file's name.
  final String name;

  /// The file's size in bytes.
  final int size;

  @override
  Uint8List toBytes() => _encode({
        'v': envelopeVersion,
        'type': 'fileAnnounce',
        'name': name,
        'size': size,
      });

  @override
  bool operator ==(Object other) =>
      other is FileAnnounce && other.name == name && other.size == size;

  @override
  int get hashCode => Object.hash(name, size);

  @override
  String toString() => 'FileAnnounce($name, $size bytes)';
}

/// Confirms the sender finished receiving one file, by name.
final class FileReceived extends TransferMessage {
  /// [name] is the received file's name.
  const FileReceived(this.name);

  /// The received file's name.
  final String name;

  @override
  Uint8List toBytes() => _encode({
        'v': envelopeVersion,
        'type': 'received',
        'name': name,
      });

  @override
  bool operator ==(Object other) =>
      other is FileReceived && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'FileReceived($name)';
}

Uint8List _encode(Map<String, Object?> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

/// Decodes [bytes] as a [TransferMessage].
///
/// Two distinct failure modes, by design (a sending peer is untrusted, but
/// a NEWER version of this same app is not a bug):
/// - Malformed input — not valid UTF-8 JSON, not a JSON object, or missing
///   a field this decoder needs (including `v`/`type` themselves, or a
///   known type's own required fields) — throws [FormatException]. A
///   caller treats this as an untrusted peer sending garbage, never a
///   crash.
/// - Well-formed but unrecognized — an unknown `type` string, or `v`
///   greater than [envelopeVersion] — returns `null`. This is forward
///   compatibility: a future envelope version this build doesn't
///   understand yet is ignored gracefully, not treated as an error.
TransferMessage? decodeEnvelope(Uint8List bytes) {
  // utf8.decode and jsonDecode each already throw FormatException on
  // malformed input on their own -- nothing to translate here.
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) {
    throw FormatException('envelope is not a JSON object: $decoded');
  }

  final v = decoded['v'];
  if (v is! int) {
    throw FormatException('envelope missing an integer "v" field: $decoded');
  }
  if (v > envelopeVersion) return null;

  final type = decoded['type'];
  if (type is! String) {
    throw FormatException(
        'envelope missing a string "type" field: $decoded');
  }

  switch (type) {
    case 'driveAnnounce':
      final driveKey = decoded['driveKey'];
      if (driveKey is! String) {
        throw FormatException(
            'driveAnnounce missing a string "driveKey" field: $decoded');
      }
      return DriveAnnounce(driveKey);
    case 'fileAnnounce':
      final name = decoded['name'];
      final size = decoded['size'];
      if (name is! String) {
        throw FormatException(
            'fileAnnounce missing a string "name" field: $decoded');
      }
      if (size is! int) {
        throw FormatException(
            'fileAnnounce missing an integer "size" field: $decoded');
      }
      return FileAnnounce(name, size);
    case 'received':
      final name = decoded['name'];
      if (name is! String) {
        throw FormatException(
            'received missing a string "name" field: $decoded');
      }
      return FileReceived(name);
    default:
      return null;
  }
}
