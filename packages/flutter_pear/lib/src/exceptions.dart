import 'schema.dart';

/// Base class for all errors surfaced from the Pear worklet.
///
/// Worklet-side (JS) exceptions serialize across RPC into one of these, with the
/// original JS [stack] attached when available.
class PearException implements Exception {
  /// Creates a Pear exception with a [message] and optional [code]/[stack].
  PearException(this.message, {this.code, this.stack});

  /// Human-readable description.
  final String message;

  /// Optional machine-readable error code from the worklet.
  final String? code;

  /// The JS stack trace from the worklet, when available.
  final String? stack;

  @override
  String toString() => '$runtimeType${code == null ? '' : '($code)'}: $message';
}

/// A swarm connection failed or dropped.
class PearConnectionException extends PearException {
  /// Creates a connection exception.
  PearConnectionException(super.message, {super.code, super.stack});
}

/// A storage/replication operation (Corestore, Hypercore, …) failed.
class PearStorageException extends PearException {
  /// Creates a storage exception.
  PearStorageException(super.message, {super.code, super.stack});
}

/// Constructs the [PearException] subtype registered for [code] in
/// [PearErrorCode.categories], preserving [message]/[code]/[stack].
///
/// A [code] that's null or not in the registry (including one this version
/// of the schema doesn't recognize) falls back to the base [PearException]
/// — an unrecognized code is never a reason to throw something other than
/// what the worklet actually reported.
PearException pearExceptionFor(String message, {String? code, String? stack}) {
  final category = code == null ? null : PearErrorCode.categories[code];
  return switch (category) {
    PearErrorCategory.connection =>
      PearConnectionException(message, code: code, stack: stack),
    PearErrorCategory.storage =>
      PearStorageException(message, code: code, stack: stack),
    null => PearException(message, code: code, stack: stack),
  };
}
