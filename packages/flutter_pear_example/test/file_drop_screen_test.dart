import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_pear_example/file_drop_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('drive-key announcement wire format', () {
    test('round-trips a real PearKey', () {
      final key = PearKey.fromHex('ab' * 32);
      final decoded = decodeDriveKeyAnnouncement(encodeDriveKeyAnnouncement(key));
      expect(decoded, key);
    });

    test('encodes as plain hex text, not binary -- matches what a peer '
        'reads back with decodeDriveKeyAnnouncement, and nothing else in '
        'this file writes to a connection', () {
      final key = PearKey.fromHex('ab' * 32);
      final bytes = encodeDriveKeyAnnouncement(key);
      expect(utf8.decode(bytes), key.hex);
    });

    test('a peer sending garbage throws FormatException, not a crash', () {
      expect(
        () => decodeDriveKeyAnnouncement(Uint8List.fromList(utf8.encode('not a key'))),
        throwsFormatException,
      );
    });

    test('a peer sending zero bytes throws FormatException', () {
      expect(
        () => decodeDriveKeyAnnouncement(Uint8List(0)),
        throwsFormatException,
      );
    });
  });
}
