import 'dart:convert';

/// Name and address as a `tincan:` blob that survives chat apps, QR
/// codes and clipboards.
class ShareableProfile {
  const ShareableProfile({required this.name, required this.address});

  final String name;
  final String address;

  String encode() {
    final json = jsonEncode({'v': 1, 'name': name, 'addr': address});
    return 'tincan:${base64Url.encode(utf8.encode(json)).replaceAll('=', '')}';
  }

  static ShareableProfile? decode(String input) {
    final body = input.trim();
    if (!body.startsWith('tincan:')) return null;
    try {
      final b64 = base64Url.normalize(body.substring('tincan:'.length));
      final map = jsonDecode(utf8.decode(base64Url.decode(b64)));
      final addr = map['addr'];
      final name = map['name'];
      if (addr is! String || !addr.startsWith('tc')) return null;
      return ShareableProfile(name: name is String ? name : '', address: addr);
    } catch (_) {
      return null;
    }
  }

  /// vCard 3.0, so Google, Samsung and iOS Contacts can import it. The
  /// address rides in a custom field and a readable NOTE.
  String toVCard() {
    String esc(String s) => s
        .replaceAll('\\', '\\\\')
        .replaceAll('\n', '\\n')
        .replaceAll(',', '\\,')
        .replaceAll(';', '\\;');
    return [
      'BEGIN:VCARD',
      'VERSION:3.0',
      'FN:${esc(name)}',
      'N:${esc(name)};;;;',
      'X-TINCAN-ADDRESS:$address',
      'NOTE:${esc('Tincan address: $address (paste it into Tincan to start a chat)')}',
      'END:VCARD',
      '',
    ].join('\r\n');
  }
}

/// What the connect box accepts: a raw tc… address or a profile blob.
({String token, String? name})? parseConnectInput(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final profile = ShareableProfile.decode(s);
  if (profile != null) {
    return (token: profile.address, name: profile.name.isEmpty ? null : profile.name);
  }
  if (s.startsWith('tc') && !s.contains(RegExp(r'\s'))) {
    return (token: s, name: null);
  }
  return null;
}
