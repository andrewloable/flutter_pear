import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A 32-byte Pear key — a public key, discovery topic, or hash.
///
/// Value type: two keys with the same bytes are equal and hash alike. Only
/// ever holds a PUBLIC key from Dart's side — private keys are generated
/// and held entirely inside the worklet's own Corestore storage, never
/// crossing the RPC boundary (E5.9, see `SECURITY_POSTURE.md` for the full
/// key-persistence/backup/reinstall posture). [toString] deliberately
/// truncates to the first 8 hex characters as defense-in-depth against an
/// accidental future log call exposing the full key.
class PearKey {
  /// Wraps 32 raw bytes.
  PearKey(this.bytes) : assert(bytes.length == 32, 'Pear keys are 32 bytes');

  /// Parses a 64-character lower/upper-case hex string.
  factory PearKey.fromHex(String hex) {
    if (hex.length != 64) {
      throw FormatException('expected 64 hex chars, got ${hex.length}', hex);
    }
    final out = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return PearKey(out);
  }

  /// The raw 32 bytes.
  final Uint8List bytes;

  /// Lower-case hex encoding (64 chars).
  String get hex {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  @override
  bool operator ==(Object other) => other is PearKey && _eq(other.bytes, bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'PearKey(${hex.substring(0, 8)}…)';

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Key, topic, and hash helpers.
///
/// ponytail: [unsafeTopicFromString] uses SHA-256 so two peers derive the
/// same topic from a shared string today. Real per-device keypairs would
/// come from the worklet's hypercore-crypto (async) but aren't exposed on
/// the Dart side yet — untracked, not part of any current epic (`PearPairing`
/// already covers real key exchange for invites). This class is only the
/// deterministic-topic convenience for now; z-base-32 key helpers are
/// planned but not yet implemented (hex is the only [PearKey] encoding
/// today).
class PearCrypto {
  PearCrypto._();

  /// Deterministic 32-byte discovery topic from a human-chosen [name] —
  /// SHA-256 of it, so two peers who pass the same string land on the same
  /// topic.
  ///
  /// **Unsafe for real apps:** this topic is global, not private. Every
  /// device worldwide that calls this with the same [name] joins the exact
  /// same swarm — there's no way to scope it to just the peers you intend,
  /// and anyone who guesses or reuses your string joins silently. Real apps
  /// should hand out a `PearPairing` invite instead, which derives a topic
  /// actually scoped to that one pairing session. This helper exists only
  /// for demos/prototyping where a quick, deterministic topic and that
  /// tradeoff are acceptable and understood — never for a real room a
  /// stranger shouldn't be able to walk into. See `doc/concepts.md`'s
  /// "Topics vs. invites" section for the full picture before you ship
  /// this anywhere real.
  static PearKey unsafeTopicFromString(String name) =>
      PearKey(Uint8List.fromList(sha256.convert(utf8.encode(name)).bytes));

  /// SHA-256 of arbitrary [data] as a [PearKey].
  static PearKey hash(Uint8List data) =>
      PearKey(Uint8List.fromList(sha256.convert(data).bytes));
}
