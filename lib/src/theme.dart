import 'package:flutter/material.dart';

/// Brand palette (see brand/): teal is the identity, orange the accent,
/// navy the dark surfaces, on the original warm paper backgrounds.
abstract final class Tc {
  /// Teal and orange verbatim from brand/logo-color.svg.
  static const brandTeal = Color(0xFF137C7A);
  static const brandOrange = Color(0xFFF08B3E);
  static const brandNavy = Color(0xFF1E2433);

  static const bg = Color(0xFFF5F3EF);
  static const panel = Color(0xFFFBFAF7);
  static const border = Color(0xFFE4E0D8);
  static const fieldBorder = Color(0xFFDCD8D0);
  static const ink = brandNavy;
  static const inkMuted = Color(0xFF6B7280);
  static const inkFaint = Color(0xFF9CA3AF);
  static const label = Color(0xFF8A8F9A);

  /// Primary actions and outgoing messages.
  static const accent = brandTeal;
  static const accentInk = Color(0xFFF4FBFA);

  /// Used sparingly, for things that must catch the eye.
  static const highlight = brandOrange;

  static const sidebar = brandNavy;
  static const sidebarCard = Color(0xFF29303F);
  static const sidebarCardBorder = Color(0xFF39414F);
  static const sidebarSelected = Color(0xFF333B4B);
  static const sidebarText = Color(0xFFEDEFF3);
  static const sidebarMuted = Color(0xFF9AA3B2);
  static const sidebarFaint = Color(0xFF7A8494);

  static const bubbleIn = Color(0xFFFFFFFF);
  static const bubbleInBorder = Color(0xFFE7E3DA);
  static const bubbleOut = brandTeal;
  static const bubbleOutInk = Color(0xFFF4FBFA);

  // Not brand colours on purpose: these mean something, and must not
  // read as chrome.
  static const directGreen = Color(0xFF2F855A);
  static const directGreenInk = Color(0xFF276749);
  static const directGreenBg = Color(0xFFE8F3EC);
  static const directGreenBorder = Color(0xFFC6E2D1);
  static const relayAmber = Color(0xFFB7791F);
  static const relayAmberInk = Color(0xFF8A5A12);
  static const relayAmberBg = Color(0xFFF7EFDD);
  static const relayAmberBorder = Color(0xFFE6D3A8);
  static const offline = Color(0xFF6B7280);
  static const danger = Color(0xFFB03A2E);

  static const avatarPalette = [
    Color(0xFF137C7A),
    Color(0xFFF08B3E),
    Color(0xFF4C6FA5),
    Color(0xFF8A6BA8),
    Color(0xFF5B8C6A),
  ];

  static Color avatarColor(String id) =>
      avatarPalette[id.hashCode.abs() % avatarPalette.length];

  /// Navy reads on every swatch above except the darkest.
  static Color onAvatar(Color swatch) =>
      swatch.computeLuminance() > 0.42 ? brandNavy : const Color(0xFFF7F8FA);

  static TextStyle mono(double size, Color color, {FontWeight? weight}) =>
      TextStyle(fontFamily: 'IBMPlexMono', fontSize: size, color: color, fontWeight: weight);

  /// Small-caps section label.
  static TextStyle caps(Color color) =>
      TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: color);

  /// Compact outlined action in an accent ink (Unblock, Reconnect, Change…).
  static final accentOutline = OutlinedButton.styleFrom(
    foregroundColor: accent,
    side: const BorderSide(color: border),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
    padding: const EdgeInsets.symmetric(horizontal: 24),
  );
}

/// A button child that turns into a spinner while [busy].
Widget busyOr(bool busy, Widget child, {double size = 16}) => busy
    ? SizedBox(
        width: size,
        height: size,
        child: const CircularProgressIndicator(strokeWidth: 2, color: Tc.accentInk))
    : child;

ThemeData tincanTheme() {
  final base = ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: Tc.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Tc.brandTeal,
      surface: Tc.bg,
    ),
  );
  return base.copyWith(
    // Fonts are bundled, not fetched: google_fonts downloads from
    // Google at runtime, which this app has no business doing.
    textTheme: base.textTheme
        .apply(fontFamily: 'SchibstedGrotesk', bodyColor: Tc.ink, displayColor: Tc.ink),
    dialogTheme: const DialogThemeData(
      backgroundColor: Color(0xFFFDFCFA),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(18)),
        side: BorderSide(color: Tc.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Tc.fieldBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Tc.accent),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: Tc.ink,
        side: const BorderSide(color: Tc.fieldBorder),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Tc.accent,
        foregroundColor: Tc.accentInk,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
  );
}
