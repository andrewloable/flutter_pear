import 'dart:io';

import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wire constants match the documented protocol strings', () {
    expect(PearMethod.swarmJoin, 'swarm.join');
    expect(PearMethod.swarmLeave, 'swarm.leave');
    expect(PearMethod.connectionWrite, 'connection.write');
    expect(PearMethod.debugForceError, 'debug.forceError');
    expect(PearMethod.debugForceCrash, 'debug.forceCrash');
    expect(PearMethod.debugEcho, 'debug.echo');
    expect(PearMethod.attachInfo, 'attach.info');
    expect(PearMethod.bulkWriteFile, 'bulk.writeFile');
    expect(PearMethod.storeGet, 'store.get');
    expect(PearMethod.coreAppend, 'core.append');
    expect(PearMethod.coreGet, 'core.get');
    expect(PearMethod.coreReplicate, 'core.replicate');
    expect(PearMethod.coreClose, 'core.close');
    expect(PearMethod.beeOpen, 'bee.open');
    expect(PearMethod.beeGet, 'bee.get');
    expect(PearMethod.beePut, 'bee.put');
    expect(PearMethod.beeDel, 'bee.del');
    expect(PearMethod.beeReplicate, 'bee.replicate');
    expect(PearMethod.beeRange, 'bee.range');
    expect(PearMethod.beeWatch, 'bee.watch');
    expect(PearMethod.beeUnwatch, 'bee.unwatch');
    expect(PearMethod.beeClose, 'bee.close');
    expect(PearMethod.driveOpen, 'drive.open');
    expect(PearMethod.drivePut, 'drive.put');
    expect(PearMethod.driveGet, 'drive.get');
    expect(PearMethod.driveExists, 'drive.exists');
    expect(PearMethod.driveDelete, 'drive.delete');
    expect(PearMethod.driveList, 'drive.list');
    expect(PearMethod.driveReplicate, 'drive.replicate');
    expect(PearMethod.driveMirrorToDisk, 'drive.mirrorToDisk');
    expect(PearMethod.driveClose, 'drive.close');
    expect(PearMethod.pairingCreateInvite, 'pairing.createInvite');
    expect(PearMethod.pairingAcceptInvite, 'pairing.acceptInvite');
    expect(PearMethod.pairingConfirmCandidate, 'pairing.confirmCandidate');
    expect(PearMethod.pairingRevoke, 'pairing.revoke');
    expect(PearMethod.baseOpen, 'base.open');
    expect(PearMethod.baseReplicate, 'base.replicate');
    expect(PearMethod.baseAppend, 'base.append');
    expect(PearMethod.baseGet, 'base.get');
    expect(PearMethod.baseRange, 'base.range');
    expect(PearMethod.baseWatch, 'base.watch');
    expect(PearMethod.baseUnwatch, 'base.unwatch');
    expect(PearMethod.baseClose, 'base.close');

    expect(PearEventName.swarmConnection, 'swarm.connection');
    expect(PearEventName.connectionData, 'connection.data');
    expect(PearEventName.connectionClose, 'connection.close');
    expect(PearEventName.swarmLifecycle, 'swarm.lifecycle');
    expect(PearEventName.rpcDiagnostic, 'rpc.diagnostic');
    expect(PearEventName.workletCrash, 'worklet.crash');
    expect(PearEventName.coreUpdate, 'core.update');
    expect(PearEventName.beeUpdate, 'bee.update');
    expect(PearEventName.pairingCandidate, 'pairing.candidate');
    expect(PearEventName.baseUpdate, 'base.update');
    expect(PearEventName.driveMirrorWarning, 'drive.mirrorWarning');

    expect(PearErrorCode.unknownPeer, 'UNKNOWN_PEER');
    expect(PearErrorCode.unknownMethod, 'UNKNOWN_METHOD');
    expect(PearErrorCode.forcedError, 'FORCED_ERROR');
    expect(PearErrorCode.udpBlocked, 'UDP_BLOCKED');
    expect(PearErrorCode.storageUnavailable, 'STORAGE_UNAVAILABLE');
    expect(PearErrorCode.indexOutOfRange, 'INDEX_OUT_OF_RANGE');
    expect(PearErrorCode.coreClosed, 'CORE_CLOSED');
    expect(PearErrorCode.unknownCore, 'UNKNOWN_CORE');
    expect(PearErrorCode.unknownBee, 'UNKNOWN_BEE');
    expect(PearErrorCode.beeClosed, 'BEE_CLOSED');
    expect(PearErrorCode.unknownDrive, 'UNKNOWN_DRIVE');
    expect(PearErrorCode.driveClosed, 'DRIVE_CLOSED');
    expect(PearErrorCode.fileNotFound, 'FILE_NOT_FOUND');
    expect(PearErrorCode.invalidInvite, 'INVALID_INVITE');
    expect(PearErrorCode.inviteExpired, 'INVITE_EXPIRED');
    expect(PearErrorCode.pairingTimeout, 'PAIRING_TIMEOUT');
    expect(PearErrorCode.unknownInvite, 'UNKNOWN_INVITE');
    expect(PearErrorCode.unknownCandidate, 'UNKNOWN_CANDIDATE');
    expect(PearErrorCode.pairingFailed, 'PAIRING_FAILED');
    expect(PearErrorCode.malformedOp, 'MALFORMED_OP');
    expect(PearErrorCode.unknownRecipe, 'UNKNOWN_RECIPE');
    expect(PearErrorCode.unknownBase, 'UNKNOWN_BASE');
    expect(PearErrorCode.baseClosed, 'BASE_CLOSED');

    expect(PearSwarmState.discovering.name, 'discovering');
    expect(PearSwarmState.connecting.name, 'connecting');
    expect(PearSwarmState.connected.name, 'connected');
    expect(PearSwarmState.reconnecting.name, 'reconnecting');
    expect(PearSwarmState.suspended.name, 'suspended');
    expect(PearSwarmState.failed.name, 'failed');

    expect(PearRecipe.lww.name, 'lww');
    expect(PearRecipe.orderedLog.name, 'orderedLog');
    expect(PearRecipe.crdtMap.name, 'crdtMap');

    expect(PearFrameType.json, 0x00);
    expect(PearFrameType.raw, 0x01);

    expect(PearHandshakeField.nonce, 'nonce');
    expect(PearHandshakeField.bundleVersion, 'bundleVersion');
    expect(PearHandshakeField.envelopeNonce, 'n');
  });

  test('pear-end/schema.js mirrors every Dart constant value', () {
    // schema.js is hand-kept, not generated (LOCKED, E2.1) -- this is the
    // regression test that catches the two files drifting apart.
    final js =
        File('${Directory.current.path}/pear-end/schema.js').readAsStringSync();

    String jsValue(String key) {
      // Lookbehind guards against a shorter key matching as a suffix of a
      // longer one elsewhere in the file -- e.g. `jsValue('FAILED')`
      // (PearSwarmState) landing inside `PAIRING_FAILED: 'PAIRING_FAILED'`
      // (PearErrorCode) instead of the real `FAILED: 'FAILED'` entry,
      // since plain substring matching can't tell "FAILED" apart from
      // "...NG_FAILED" (caught when PAIRING_FAILED was added, E5.6 review).
      final match = RegExp("(?<![A-Za-z_])$key: '([^']*)'").firstMatch(js) ??
          RegExp('(?<![A-Za-z_])$key: (0x[0-9a-fA-F]+)').firstMatch(js);
      if (match == null) {
        fail('schema.js has no entry for `$key`');
      }
      return match.group(1)!;
    }

    expect(jsValue('SWARM_JOIN'), PearMethod.swarmJoin);
    expect(jsValue('SWARM_LEAVE'), PearMethod.swarmLeave);
    expect(jsValue('CONNECTION_WRITE'), PearMethod.connectionWrite);
    expect(jsValue('DEBUG_FORCE_ERROR'), PearMethod.debugForceError);
    expect(jsValue('DEBUG_FORCE_CRASH'), PearMethod.debugForceCrash);
    expect(jsValue('DEBUG_ECHO'), PearMethod.debugEcho);
    expect(jsValue('ATTACH_INFO'), PearMethod.attachInfo);
    expect(jsValue('BULK_WRITE_FILE'), PearMethod.bulkWriteFile);
    expect(jsValue('STORE_GET'), PearMethod.storeGet);
    expect(jsValue('CORE_APPEND'), PearMethod.coreAppend);
    expect(jsValue('CORE_GET'), PearMethod.coreGet);
    expect(jsValue('CORE_REPLICATE'), PearMethod.coreReplicate);
    expect(jsValue('CORE_CLOSE'), PearMethod.coreClose);
    expect(jsValue('BEE_OPEN'), PearMethod.beeOpen);
    expect(jsValue('BEE_GET'), PearMethod.beeGet);
    expect(jsValue('BEE_PUT'), PearMethod.beePut);
    expect(jsValue('BEE_DEL'), PearMethod.beeDel);
    expect(jsValue('BEE_REPLICATE'), PearMethod.beeReplicate);
    expect(jsValue('BEE_RANGE'), PearMethod.beeRange);
    expect(jsValue('BEE_WATCH'), PearMethod.beeWatch);
    expect(jsValue('BEE_UNWATCH'), PearMethod.beeUnwatch);
    expect(jsValue('BEE_CLOSE'), PearMethod.beeClose);
    expect(jsValue('DRIVE_OPEN'), PearMethod.driveOpen);
    expect(jsValue('DRIVE_PUT'), PearMethod.drivePut);
    expect(jsValue('DRIVE_GET'), PearMethod.driveGet);
    expect(jsValue('DRIVE_EXISTS'), PearMethod.driveExists);
    expect(jsValue('DRIVE_DELETE'), PearMethod.driveDelete);
    expect(jsValue('DRIVE_LIST'), PearMethod.driveList);
    expect(jsValue('DRIVE_REPLICATE'), PearMethod.driveReplicate);
    expect(jsValue('DRIVE_MIRROR_TO_DISK'), PearMethod.driveMirrorToDisk);
    expect(jsValue('DRIVE_CLOSE'), PearMethod.driveClose);
    expect(jsValue('PAIRING_CREATE_INVITE'), PearMethod.pairingCreateInvite);
    expect(jsValue('PAIRING_ACCEPT_INVITE'), PearMethod.pairingAcceptInvite);
    expect(jsValue('PAIRING_CONFIRM_CANDIDATE'),
        PearMethod.pairingConfirmCandidate);
    expect(jsValue('PAIRING_REVOKE'), PearMethod.pairingRevoke);
    expect(jsValue('BASE_OPEN'), PearMethod.baseOpen);
    expect(jsValue('BASE_REPLICATE'), PearMethod.baseReplicate);
    expect(jsValue('BASE_APPEND'), PearMethod.baseAppend);
    expect(jsValue('BASE_GET'), PearMethod.baseGet);
    expect(jsValue('BASE_RANGE'), PearMethod.baseRange);
    expect(jsValue('BASE_WATCH'), PearMethod.baseWatch);
    expect(jsValue('BASE_UNWATCH'), PearMethod.baseUnwatch);
    expect(jsValue('BASE_CLOSE'), PearMethod.baseClose);

    expect(jsValue('SWARM_CONNECTION'), PearEventName.swarmConnection);
    expect(jsValue('CONNECTION_DATA'), PearEventName.connectionData);
    expect(jsValue('CONNECTION_CLOSE'), PearEventName.connectionClose);
    expect(jsValue('SWARM_LIFECYCLE'), PearEventName.swarmLifecycle);
    expect(jsValue('RPC_DIAGNOSTIC'), PearEventName.rpcDiagnostic);
    expect(jsValue('WORKLET_CRASH'), PearEventName.workletCrash);
    expect(jsValue('CORE_UPDATE'), PearEventName.coreUpdate);
    expect(jsValue('BEE_UPDATE'), PearEventName.beeUpdate);
    expect(jsValue('PAIRING_CANDIDATE'), PearEventName.pairingCandidate);
    expect(jsValue('BASE_UPDATE'), PearEventName.baseUpdate);
    expect(jsValue('DRIVE_MIRROR_WARNING'), PearEventName.driveMirrorWarning);

    expect(jsValue('UNKNOWN_PEER'), PearErrorCode.unknownPeer);
    expect(jsValue('UNKNOWN_METHOD'), PearErrorCode.unknownMethod);
    expect(jsValue('FORCED_ERROR'), PearErrorCode.forcedError);
    expect(jsValue('UDP_BLOCKED'), PearErrorCode.udpBlocked);
    expect(jsValue('STORAGE_UNAVAILABLE'), PearErrorCode.storageUnavailable);
    expect(jsValue('INDEX_OUT_OF_RANGE'), PearErrorCode.indexOutOfRange);
    expect(jsValue('CORE_CLOSED'), PearErrorCode.coreClosed);
    expect(jsValue('UNKNOWN_CORE'), PearErrorCode.unknownCore);
    expect(jsValue('UNKNOWN_BEE'), PearErrorCode.unknownBee);
    expect(jsValue('BEE_CLOSED'), PearErrorCode.beeClosed);
    expect(jsValue('UNKNOWN_DRIVE'), PearErrorCode.unknownDrive);
    expect(jsValue('DRIVE_CLOSED'), PearErrorCode.driveClosed);
    expect(jsValue('FILE_NOT_FOUND'), PearErrorCode.fileNotFound);
    expect(jsValue('INVALID_INVITE'), PearErrorCode.invalidInvite);
    expect(jsValue('INVITE_EXPIRED'), PearErrorCode.inviteExpired);
    expect(jsValue('PAIRING_TIMEOUT'), PearErrorCode.pairingTimeout);
    expect(jsValue('UNKNOWN_INVITE'), PearErrorCode.unknownInvite);
    expect(jsValue('UNKNOWN_CANDIDATE'), PearErrorCode.unknownCandidate);
    expect(jsValue('PAIRING_FAILED'), PearErrorCode.pairingFailed);
    expect(jsValue('MALFORMED_OP'), PearErrorCode.malformedOp);
    expect(jsValue('UNKNOWN_RECIPE'), PearErrorCode.unknownRecipe);
    expect(jsValue('UNKNOWN_BASE'), PearErrorCode.unknownBase);
    expect(jsValue('BASE_CLOSED'), PearErrorCode.baseClosed);

    expect(jsValue('LWW'), PearRecipe.lww.name);
    expect(jsValue('ORDERED_LOG'), PearRecipe.orderedLog.name);
    expect(jsValue('CRDT_MAP'), PearRecipe.crdtMap.name);

    expect(jsValue('DISCOVERING'), PearSwarmState.discovering.name);
    expect(jsValue('CONNECTING'), PearSwarmState.connecting.name);
    expect(jsValue('CONNECTED'), PearSwarmState.connected.name);
    expect(jsValue('RECONNECTING'), PearSwarmState.reconnecting.name);
    expect(jsValue('SUSPENDED'), PearSwarmState.suspended.name);
    expect(jsValue('FAILED'), PearSwarmState.failed.name);

    expect(int.parse(jsValue('JSON')), PearFrameType.json);
    expect(int.parse(jsValue('RAW')), PearFrameType.raw);

    expect(jsValue('NONCE'), PearHandshakeField.nonce);
    expect(jsValue('BUNDLE_VERSION'), PearHandshakeField.bundleVersion);
    expect(jsValue('ENVELOPE_NONCE'), PearHandshakeField.envelopeNonce);
  });
}
