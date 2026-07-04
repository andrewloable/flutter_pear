import 'bundle_version.dart';

/// A hex string of 32+ characters -- a full [PearKey] (topic, peer public
/// key, or hash; 64 hex chars) or any shorter key-shaped fragment (a truly
/// exact-64 pattern would let a 32- or 96-char hex run of key material
/// through untouched), rendered in full rather than through
/// [PearKey.toString]'s truncated-to-8-chars defense-in-depth (e.g. inside
/// a raw RPC frame dump or an error's [PearException.details]).
final _hexKey = RegExp(r'\b[0-9a-fA-F]{32,}\b');

/// A long base64-ish blob -- a `PearPairing` invite is exactly this shape.
final _base64Blob = RegExp(r'[A-Za-z0-9+/]{40,}={0,2}');

/// A chat-log-style `peer: <message>`/`sent: <message>` payload -- matches
/// this package's own quick-start snippet and the example app's
/// `tool/peer.js` (`print('peer: $text')` / `console.log('peer: ' + text)`),
/// wherever it appears in a line (a timestamp/level prefix is typical, not
/// assumed to be absent). Only ever matched against the ORIGINAL line (see
/// [sanitizeLogLine]) -- a message could otherwise contain something
/// hex/base64-shaped that gets redacted first and shifts this match.
final _chatLine = RegExp(r'(?:peer|sent): ');

/// Redacts sensitive-looking content from a single log [line]: a chat
/// line's message payload, full hex keys/topics/peer IDs, and long base64
/// invite-shaped blobs. All three rules are applied unconditionally and to
/// the WHOLE line -- including whatever comes before a chat prefix, e.g. a
/// connection-scoped logger's `topic=<hex> peer: <message>` -- rather than
/// returning early on the first match, which previously left everything
/// before a matched chat prefix un-redacted.
///
/// This is the mechanism behind [buildDoctorReport]'s LOCKED promise that
/// `flutter_pear` never phones home: the support bundle it assembles is
/// pasted by the user themselves into a bug report, never transmitted by
/// this package, and never contains anything that would identify a peer,
/// a room, an invite, or what was actually said.
///
/// Not airtight for a MULTI-LINE chat message split across several log
/// lines by [sanitizeLog] (this app's own chat UI and CLI peer only ever
/// send single-line messages, so this isn't reachable from anything this
/// package actually produces) -- a continuation line with no `peer:`/
/// `sent:` prefix of its own still gets the hex/base64 rules applied, just
/// not the message-payload rule.
String sanitizeLogLine(String line) {
  final chatMatch = _chatLine.firstMatch(line);
  final withoutMessage = chatMatch == null
      ? line
      : '${line.substring(0, chatMatch.end)}<redacted:message>';
  return withoutMessage
      .replaceAll(_hexKey, '<redacted:key>')
      .replaceAllMapped(_base64Blob, (m) => '<redacted:invite>');
}

/// The last [maxLines] lines of [log], each sanitized by [sanitizeLogLine].
List<String> sanitizeLog(String log, {int maxLines = 200}) {
  final lines = log.split('\n');
  final tail = lines.length > maxLines
      ? lines.sublist(lines.length - maxLines)
      : lines;
  return tail.map(sanitizeLogLine).toList();
}

/// Assembles `doctor --report`'s paste-ready markdown support bundle:
/// package versions, the pear-end bundle identifier, the host environment,
/// [doctorCheckOutput] (doctor's own PASS/FAIL/INFO/SKIP lines), and --
/// only if [rawLog] is given -- its sanitized tail (see [sanitizeLog]).
/// Never transmitted by this package (LOCKED: no runtime telemetry in a
/// privacy-first P2P library) -- the caller pastes this themselves.
String buildDoctorReport({
  required String flutterPearVersion,
  required String flutterPearBareVersion,
  required String hostOs,
  required String doctorCheckOutput,
  String? rawLog,
  int maxLogLines = 200,
}) {
  final buffer = StringBuffer()
    ..writeln('## flutter_pear support bundle')
    ..writeln()
    ..writeln('- flutter_pear: $flutterPearVersion')
    ..writeln('- flutter_pear_bare: $flutterPearBareVersion')
    ..writeln('- pear-end bundle: $kPearEndBundleVersion')
    ..writeln('- Bare Kit version: not yet tracked (pinned in M1)')
    ..writeln('- Host: $hostOs')
    ..writeln()
    ..writeln('### Doctor checks')
    ..writeln()
    ..writeln('```')
    ..writeln(doctorCheckOutput.trim())
    ..writeln('```');

  buffer
    ..writeln()
    ..writeln('### Log (sanitized)')
    ..writeln();
  if (rawLog == null) {
    buffer.writeln('_No log file provided -- pass `--log <path>`._');
  } else {
    buffer.writeln('```');
    for (final line in sanitizeLog(rawLog, maxLines: maxLogLines)) {
      buffer.writeln(line);
    }
    buffer.writeln('```');
  }

  return buffer.toString();
}
