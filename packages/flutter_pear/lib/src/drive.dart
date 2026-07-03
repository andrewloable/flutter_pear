import 'crypto.dart';
import 'rpc.dart';
import 'schema.dart';
import 'swarm.dart';

/// File counts from one [PearDrive.mirrorToDisk] call.
typedef PearDriveMirrorResult = ({int added, int changed, int removed});

/// A Hyperdrive file store opened via [PearDrive.open] (E5.5) — wrapper 3 of
/// 5 in the data-structure family, built on the same Corestore substrate as
/// [PearStore]/[PearBee].
///
/// Every [put]/[get] moves bytes by LOCAL FILE PATH, never by in-memory
/// `Uint8List` — this is the E5.1-benchmarked, LOCKED transport decision
/// (`BENCHMARK.md`: file-path is ~2-2.5x faster than in-channel at 1MB+, and
/// the gap widens with size). The worklet streams straight between the
/// local filesystem and the drive on both ends (`fs.createReadStream`/
/// `createWriteStream` piped into the drive's own stream methods) — a
/// payload of any size crosses the RPC envelope as two path strings, never
/// as file bytes, so a multi-hundred-MB transfer can't exhaust memory by
/// inflating through JSON/base64 the way an in-channel design would.
class PearDrive {
  PearDrive._(this._rpc, this.key);

  final PearRpc _rpc;

  /// This drive's public key.
  final PearKey key;

  /// Opens the drive known locally as [name] (creating it on first use), or
  /// attaches to an existing drive by its public [key] — exactly one of
  /// [name]/[key] must be given, same contract as `PearStore.get`/
  /// `PearBee.open`. Prefer `Pear.drive` over calling this directly.
  static Future<PearDrive> open(
    PearRpc rpc, {
    String? name,
    PearKey? key,
  }) async {
    assert((name == null) != (key == null),
        'PearDrive.open needs exactly one of name/key');
    final result = await rpc.call(PearMethod.driveOpen, {
      if (name != null) 'name': name,
      if (key != null) 'key': key.hex,
    }) as Map;
    return PearDrive._(rpc, PearKey.fromHex(result['key'] as String));
  }

  /// Streams the local file at [localSourcePath] into this drive at
  /// [virtualPath], overwriting any existing content there.
  Future<void> put(String virtualPath, String localSourcePath) => _rpc.call(
        PearMethod.drivePut,
        {'drive': key.hex, 'path': virtualPath, 'localSourcePath': localSourcePath},
      );

  /// Streams the content at [virtualPath] to the local file
  /// [destinationPath], then returns [destinationPath] for convenience
  /// (e.g. `File(await drive.get(...))`).
  ///
  /// Always requires an explicit destination rather than picking one for
  /// you: files are the app's own user-facing data (photos, documents, …),
  /// so this never guesses where they should land in your app's sandbox.
  /// Throws with [PearErrorCode.fileNotFound] if [virtualPath] doesn't
  /// exist.
  Future<String> get(String virtualPath, String destinationPath) async {
    await _rpc.call(PearMethod.driveGet, {
      'drive': key.hex,
      'path': virtualPath,
      'destinationPath': destinationPath,
    });
    return destinationPath;
  }

  /// Whether [virtualPath] exists in this drive.
  Future<bool> exists(String virtualPath) async {
    final result = await _rpc
        .call(PearMethod.driveExists, {'drive': key.hex, 'path': virtualPath}) as Map;
    return result['exists'] as bool;
  }

  /// Deletes [virtualPath]. A no-op, not an error, if it isn't present.
  Future<void> delete(String virtualPath) =>
      _rpc.call(PearMethod.driveDelete, {'drive': key.hex, 'path': virtualPath});

  /// Every virtual path under [folder] as a single bounded snapshot, taken
  /// at the moment this call reaches the worklet — same
  /// fetched-in-one-round-trip-then-emitted shape as `PearBee.range`, with
  /// the same caveat about very large listings.
  Stream<String> list({String folder = '/'}) async* {
    final result = await _rpc
        .call(PearMethod.driveList, {'drive': key.hex, 'folder': folder}) as Map;
    for (final path in (result['paths'] as List).cast<String>()) {
      yield path;
    }
  }

  /// Replicates this drive over [connection] — call on both peers, same
  /// contract as `PearCore.replicate`/`PearBee.replicate`. A drive's file
  /// content lives in a separate underlying core from its path listing, so
  /// this replicates both; nothing else needs to know that.
  Future<void> replicate(PearConnection connection) => _rpc.call(
        PearMethod.driveReplicate,
        {'drive': key.hex, 'peer': connection.remotePublicKey.hex},
      );

  /// Mirrors the ENTIRE drive to the local directory [localDir] — only
  /// changed files actually copy (diff-aware, via the Pear ecosystem's own
  /// `mirror-drive`, not a naive whole-drive re-copy).
  Future<PearDriveMirrorResult> mirrorToDisk(String localDir) async {
    final result = await _rpc
        .call(PearMethod.driveMirrorToDisk, {'drive': key.hex, 'localDir': localDir}) as Map;
    return (
      added: result['added'] as int,
      changed: result['changed'] as int,
      removed: result['removed'] as int,
    );
  }

  /// Closes this drive. Further [put]/[get]/[exists]/[delete]/[list]/
  /// [replicate]/[mirrorToDisk] calls fail with [PearErrorCode.driveClosed].
  Future<void> close() => _rpc.call(PearMethod.driveClose, {'drive': key.hex});
}
