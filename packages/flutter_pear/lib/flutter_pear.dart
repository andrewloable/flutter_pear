/// Dart-idiomatic Flutter API for the Pear P2P stack.
///
/// Start with [Pear.start], join a topic with [Pear.join], and exchange bytes
/// over [PearConnection]. Everything is `Future`s and broadcast `Stream`s.
library;

// Low-level worklet handle re-exported so apps need a single import.
export 'package:flutter_pear_bare/flutter_pear_bare.dart'
    show BareWorklet, WorkletState;

export 'src/base.dart';
export 'src/bee.dart';
export 'src/crypto.dart';
export 'src/drive.dart';
export 'src/error_catalog.dart';
export 'src/exceptions.dart';
export 'src/lifecycle.dart';
export 'src/pairing.dart';
export 'src/pear.dart';
// Only the pieces of the RPC schema that already appear in other exported
// signatures (PearSwarm.state's PearSwarmStatus needs PearSwarmState to be
// nameable; PearBase.open requires a PearRecipe; PearException.code is
// compared against PearErrorCode) -- PearMethod/PearEventName/PearFrameType/
// PearHandshakeField are wire-protocol internals no app dev needs.
export 'src/schema.dart'
    show PearSwarmState, PearRecipe, PearErrorCode, PearErrorCategory;
export 'src/store.dart';
export 'src/swarm.dart';
