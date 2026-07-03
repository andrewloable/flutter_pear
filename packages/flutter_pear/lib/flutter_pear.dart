/// Dart-idiomatic Flutter API for the Pear P2P stack.
///
/// Start with [Pear.start], join a topic with [Pear.join], and exchange bytes
/// over [PearConnection]. Everything is `Future`s and broadcast `Stream`s.
library;

// Low-level worklet handle re-exported so apps need a single import.
export 'package:flutter_pear_bare/flutter_pear_bare.dart'
    show BareWorklet, WorkletState;

export 'src/crypto.dart';
export 'src/exceptions.dart';
export 'src/pear.dart';
export 'src/swarm.dart';
