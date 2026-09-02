import 'package:flutter_test/flutter_test.dart';
import 'package:tincan/src/profile.dart';

void main() {
  test('profile blob round-trips name and address', () {
    const p = ShareableProfile(name: 'Nia Okafor 🏔️', address: 'tcABCdef123');
    final decoded = ShareableProfile.decode(p.encode())!;
    expect(decoded.name, 'Nia Okafor 🏔️');
    expect(decoded.address, 'tcABCdef123');
  });

  test('parseConnectInput accepts raw addresses and profile blobs', () {
    expect(parseConnectInput('  tcXYZ  ')!.token, 'tcXYZ');
    expect(parseConnectInput('tcXYZ')!.name, isNull);

    const p = ShareableProfile(name: 'sam', address: 'tcXYZ');
    final parsed = parseConnectInput(p.encode())!;
    expect(parsed.token, 'tcXYZ');
    expect(parsed.name, 'sam');

    expect(parseConnectInput(''), isNull);
    expect(parseConnectInput('hello world'), isNull);
    expect(parseConnectInput('tincan:%%%'), isNull);
  });

  test('vCard carries the address and escapes the name', () {
    const p = ShareableProfile(name: 'A;B,C', address: 'tcXYZ');
    final v = p.toVCard();
    expect(v, contains('BEGIN:VCARD'));
    expect(v, contains('FN:A\\;B\\,C'));
    expect(v, contains('X-TINCAN-ADDRESS:tcXYZ'));
    expect(v, contains('END:VCARD'));
  });
}
