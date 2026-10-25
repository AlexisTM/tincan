import 'dart:convert';

/// Name and address as a `tincan:` blob that survives chat apps, QR
/// codes and clipboards.
class ShareableProfile {
  const ShareableProfile({required this.name, required this.address});

  /// Matches the nickname field.
  static const maxNameLength = 40;

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
      if (addr is! String || !_isAddress(addr)) return null;
      final n = name is String ? String.fromCharCodes(name.runes.take(maxNameLength)) : '';
      return ShareableProfile(name: n, address: addr);
    } catch (_) {
      return null;
    }
  }

  /// vCard 3.0, so Google, Samsung and iOS Contacts can import it. The
  /// address rides in a custom field and a readable NOTE.
  String toVCard() {
    String esc(String s) => s
        .replaceAll('\\', '\\\\')
        .replaceAll(RegExp(r'\r\n?|\n'), '\\n')
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
    ].map(_fold).join('\r\n');
  }

  /// Folds at 75 octets as RFC 2425 asks, never inside a UTF-8 sequence.
  static String _fold(String line) {
    final out = StringBuffer();
    var octets = 0;
    for (final r in line.runes) {
      final ch = String.fromCharCode(r);
      final len = utf8.encode(ch).length;
      if (octets + len > 75) {
        out.write('\r\n ');
        octets = 1;
      }
      out.write(ch);
      octets += len;
    }
    return out.toString();
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
  if (_isAddress(s)) {
    return (token: s, name: null);
  }
  return null;
}

bool _isAddress(String s) => s.startsWith('tc') && !s.contains(RegExp(r'\s'));
