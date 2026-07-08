import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pear_example/transfer_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _json(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

void main() {
  test('DriveAnnounce round-trips through bytes', () {
    const msg = DriveAnnounce('deadbeef');
    expect(decodeEnvelope(msg.toBytes()), equals(msg));
  });

  test('FileAnnounce round-trips through bytes', () {
    const msg = FileAnnounce('photo.png', 12345);
    expect(decodeEnvelope(msg.toBytes()), equals(msg));
  });

  test('FileReceived round-trips through bytes', () {
    const msg = FileReceived('photo.png');
    expect(decodeEnvelope(msg.toBytes()), equals(msg));
  });

  test('a multi-MB size survives as an exact int, not a lossy double', () {
    const size = 5000000000; // 5 GB -- well past 32-bit, well within int64
    const msg = FileAnnounce('movie.mp4', size);
    final decoded = decodeEnvelope(msg.toBytes());
    expect(decoded, isA<FileAnnounce>());
    expect((decoded as FileAnnounce).size, equals(size));
    expect(decoded.size, isA<int>());
  });

  test('garbage (not JSON at all) throws FormatException', () {
    expect(() => decodeEnvelope(Uint8List.fromList(utf8.encode('not json'))),
        throwsFormatException);
  });

  test('valid JSON that is not an object throws FormatException', () {
    expect(() => decodeEnvelope(_json([1, 2, 3])), throwsFormatException);
    expect(() => decodeEnvelope(_json(42)), throwsFormatException);
  });

  test('an unrecognized type is ignored gracefully (null), never a throw',
      () {
    expect(
      decodeEnvelope(_json({'v': 1, 'type': 'somethingFromTheFuture'})),
      isNull,
    );
  });

  test('a newer version (v greater than envelopeVersion) returns null', () {
    expect(
      decodeEnvelope(
          _json({'v': envelopeVersion + 1, 'type': 'driveAnnounce'})),
      isNull,
    );
  });

  test('missing the v field throws FormatException', () {
    expect(
      () => decodeEnvelope(_json({'type': 'driveAnnounce', 'driveKey': 'x'})),
      throwsFormatException,
    );
  });

  test('missing the type field throws FormatException', () {
    expect(
      () => decodeEnvelope(_json({'v': 1, 'driveKey': 'x'})),
      throwsFormatException,
    );
  });

  test('driveAnnounce missing its driveKey field throws FormatException',
      () {
    expect(
      () => decodeEnvelope(_json({'v': 1, 'type': 'driveAnnounce'})),
      throwsFormatException,
    );
  });

  test('fileAnnounce missing its size field throws FormatException', () {
    expect(
      () => decodeEnvelope(
          _json({'v': 1, 'type': 'fileAnnounce', 'name': 'x'})),
      throwsFormatException,
    );
  });

  test('fileAnnounce with a wrong-typed size throws FormatException', () {
    expect(
      () => decodeEnvelope(_json(
          {'v': 1, 'type': 'fileAnnounce', 'name': 'x', 'size': 'not-a-number'})),
      throwsFormatException,
    );
  });

  test('received missing its name field throws FormatException', () {
    expect(
      () => decodeEnvelope(_json({'v': 1, 'type': 'received'})),
      throwsFormatException,
    );
  });
}
