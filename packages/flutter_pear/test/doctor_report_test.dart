import 'package:flutter_pear/src/doctor_report.dart';
import 'package:flutter_test/flutter_test.dart';

// A "poisoned" fixture -- one made-up value per sensitive category
// sanitizeLog is supposed to strip -- so the acceptance criterion ("a
// poisoned-fixture test proves keys/topics/invites/messages are redacted")
// is checked against something concrete rather than asserted in the
// abstract.
const _poisonedLog = '''
2026-07-04 12:00:00 [info] joining topic 3c07e0b6faa6dd67b2bfd465f7dde7ba3034695192d77b9a4e4ce1ad9ef80275
2026-07-04 12:00:01 [info] peer public key 661df9d24a7c2e5b9f0e3d1c8a6b5f4e2d1c0b9a8f7e6d5c4b3a2918f0e1d2c3
2026-07-04 12:00:02 [info] accepted invite AQEY2YYqFkjJZ86Y3mwTd2h9AnD7LHEZKDJjOSrh5nw8D4HtpujJOfqv7my+9khC1udwOSaswITvi2HJXLCGn9T1
2026-07-04 12:00:03 [chat] peer: my bank PIN is 4321, meet me at 5pm
2026-07-04 12:00:04 [chat] sent: reply with something equally sensitive
2026-07-04 12:00:05 [info] connection closed
''';

void main() {
  group('sanitizeLogLine', () {
    test('redacts a full 64-char hex key/topic/peer-id', () {
      final sanitized = sanitizeLogLine(
        'joining topic 3c07e0b6faa6dd67b2bfd465f7dde7ba3034695192d77b9a4e4ce1ad9ef80275',
      );
      expect(sanitized, 'joining topic <redacted:key>');
    });

    test('redacts a base64-shaped invite blob', () {
      final sanitized = sanitizeLogLine(
        'accepted invite AQEY2YYqFkjJZ86Y3mwTd2h9AnD7LHEZKDJjOSrh5nw8D4HtpujJOfqv7my+9khC1udwOSaswITvi2HJXLCGn9T1',
      );
      expect(sanitized, 'accepted invite <redacted:invite>');
    });

    test('redacts a peer: chat line\'s message content entirely', () {
      expect(
        sanitizeLogLine('peer: my bank PIN is 4321, meet me at 5pm'),
        'peer: <redacted:message>',
      );
    });

    test('redacts a sent: chat line\'s message content entirely', () {
      expect(
        sanitizeLogLine('sent: reply with something equally sensitive'),
        'sent: <redacted:message>',
      );
    });

    test('redacts a key sharing a line with a chat message (regression)', () {
      // A connection-scoped logger line -- the topic must not survive just
      // because a chat prefix appears later in the same line.
      final sanitized = sanitizeLogLine(
        'topic=3c07e0b6faa6dd67b2bfd465f7dde7ba3034695192d77b9a4e4ce1ad9ef80275 peer: hi',
      );
      expect(sanitized, 'topic=<redacted:key> peer: <redacted:message>');
    });

    test(
        'redacts a 32-char hex key, not just exactly-64-char ones '
        '(regression)', () {
      expect(
        sanitizeLogLine('short peer id abcdef0123456789abcdef0123456789'),
        'short peer id <redacted:key>',
      );
    });

    test(
        'redacts a 96-char hex value, not just exactly-64-char ones '
        '(regression)', () {
      final hex96 = 'a' * 96;
      expect(
        sanitizeLogLine('concatenated: $hex96'),
        'concatenated: <redacted:key>',
      );
    });

    test('leaves an unremarkable line untouched', () {
      expect(
        sanitizeLogLine('2026-07-04 12:00:05 [info] connection closed'),
        '2026-07-04 12:00:05 [info] connection closed',
      );
    });
  });

  group('sanitizeLog', () {
    test('every category in the poisoned fixture is fully redacted', () {
      final sanitized = sanitizeLog(_poisonedLog).join('\n');

      // Nothing sensitive survives, anywhere in the output.
      expect(sanitized, isNot(contains('3c07e0b6')));
      expect(sanitized, isNot(contains('661df9d2')));
      expect(sanitized, isNot(contains('AQEY2YYq')));
      expect(sanitized, isNot(contains('bank PIN')));
      expect(sanitized, isNot(contains('4321')));
      expect(sanitized, isNot(contains('equally sensitive')));

      // The redaction markers themselves are present -- proves the lines
      // were matched and transformed, not just coincidentally free of the
      // secrets (e.g. because the whole log was dropped).
      expect(sanitized, contains('<redacted:key>'));
      expect(sanitized, contains('<redacted:invite>'));
      expect(sanitized, contains('<redacted:message>'));

      // Unremarkable structure (timestamps, log level tags) is preserved --
      // this is a support bundle, so it should still be useful.
      expect(sanitized, contains('[info] connection closed'));
    });

    test('keeps only the last maxLines lines', () {
      final log = List.generate(10, (i) => 'line $i').join('\n');
      final sanitized = sanitizeLog(log, maxLines: 3);
      expect(sanitized, ['line 7', 'line 8', 'line 9']);
    });
  });

  group('buildDoctorReport', () {
    test('includes versions, bundle id, host, and check output', () {
      final report = buildDoctorReport(
        flutterPearVersion: '0.0.1',
        flutterPearBareVersion: '0.0.1',
        hostOs: 'macos 14.5',
        doctorCheckOutput: '[PASS] DHT bootstrap reachable',
      );
      expect(report, contains('flutter_pear: 0.0.1'));
      expect(report, contains('flutter_pear_bare: 0.0.1'));
      expect(report, contains('Host: macos 14.5'));
      expect(report, contains('[PASS] DHT bootstrap reachable'));
      expect(report, contains('No log file provided'));
    });

    test('a poisoned log passed in comes out fully sanitized', () {
      final report = buildDoctorReport(
        flutterPearVersion: '0.0.1',
        flutterPearBareVersion: '0.0.1',
        hostOs: 'macos 14.5',
        doctorCheckOutput: '[PASS] DHT bootstrap reachable',
        rawLog: _poisonedLog,
      );
      expect(report, isNot(contains('3c07e0b6')));
      expect(report, isNot(contains('AQEY2YYq')));
      expect(report, isNot(contains('bank PIN')));
      expect(report, contains('<redacted:key>'));
      expect(report, contains('<redacted:invite>'));
      expect(report, contains('<redacted:message>'));
    });
  });
}
