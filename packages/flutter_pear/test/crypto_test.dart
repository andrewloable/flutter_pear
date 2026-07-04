import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PearKey hex round-trips and equals by value', () {
    final k = PearCrypto.unsafeTopicFromString('room-42');
    expect(k.hex.length, 64);
    expect(PearKey.fromHex(k.hex), k);
    expect(PearKey.fromHex(k.hex).hashCode, k.hashCode);
  });

  test('unsafeTopicFromString is deterministic and 32 bytes', () {
    final a = PearCrypto.unsafeTopicFromString('same');
    expect(a.bytes.length, 32);
    expect(a, PearCrypto.unsafeTopicFromString('same'));
    expect(PearCrypto.unsafeTopicFromString('diff'), isNot(a));
  });

  test('PearKey.fromHex rejects wrong length', () {
    expect(() => PearKey.fromHex('abc'), throwsFormatException);
  });
}
