import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Brand constants and text helpers that don't change with the theme.
/// Colours that do live in [TincanColors].
abstract final class Tc {
  /// Teal and orange verbatim from brand/logo-color.svg.
  static const brandTeal = Color(0xFF137C7A);
  static const brandOrange = Color(0xFFF08B3E);
  static const brandNavy = Color(0xFF1E2433);

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
      TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: color);
}

/// Phones get 48dp touch targets; a mouse is happy with 40.
bool get isTouchPlatform =>
    defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

double get minTap => isTouchPlatform ? 48 : 40;

/// Below this width the list and the thread take turns on screen.
const wideBreakpoint = 700.0;

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= wideBreakpoint;

/// Every colour the UI paints with, light and dark.
@immutable
class TincanColors extends ThemeExtension<TincanColors> {
  const TincanColors({
    required this.bg,
    required this.panel,
    required this.dialog,
    required this.border,
    required this.fieldBorder,
    required this.field,
    required this.fieldFill,
    required this.ink,
    required this.inkMuted,
    required this.inkFaint,
    required this.label,
    required this.accent,
    required this.accentInk,
    required this.accentSoft,
    required this.highlight,
    required this.disabled,
    required this.disabledInk,
    required this.sidebar,
    required this.sidebarCard,
    required this.sidebarCardBorder,
    required this.sidebarSelected,
    required this.sidebarText,
    required this.sidebarMuted,
    required this.sidebarFaint,
    required this.sidebarAddress,
    required this.online,
    required this.requestBg,
    required this.requestBorder,
    required this.acceptBg,
    required this.acceptInk,
    required this.refuseBg,
    required this.refuseInk,
    required this.bubbleIn,
    required this.bubbleInBorder,
    required this.bubbleOut,
    required this.bubbleOutInk,
    required this.mediaOut,
    required this.mediaOutBorder,
    required this.mediaPlaceholder,
    required this.videoBg,
    required this.directGreen,
    required this.directGreenInk,
    required this.directGreenBg,
    required this.directGreenBorder,
    required this.relayAmber,
    required this.relayAmberInk,
    required this.relayAmberBg,
    required this.relayAmberBorder,
    required this.offline,
    required this.danger,
    required this.dangerInk,
    required this.dangerBg,
    required this.dangerBorder,
    required this.shadow,
  });

  final Color bg, panel, dialog, border, fieldBorder, field, fieldFill;
  final Color ink, inkMuted, inkFaint, label;
  final Color accent, accentInk, accentSoft, highlight, disabled, disabledInk;
  final Color sidebar, sidebarCard, sidebarCardBorder, sidebarSelected;
  final Color sidebarText, sidebarMuted, sidebarFaint, sidebarAddress, online;
  final Color requestBg, requestBorder, acceptBg, acceptInk, refuseBg, refuseInk;
  final Color bubbleIn, bubbleInBorder, bubbleOut, bubbleOutInk;
  final Color mediaOut, mediaOutBorder, mediaPlaceholder, videoBg;
  final Color directGreen, directGreenInk, directGreenBg, directGreenBorder;
  final Color relayAmber, relayAmberInk, relayAmberBg, relayAmberBorder;
  final Color offline, danger, dangerInk, dangerBg, dangerBorder, shadow;

  /// QR codes scan best dark on white, whatever the theme.
  Color get qrBg => const Color(0xFFFFFFFF);
  Color get qrInk => Tc.brandNavy;

  /// Icons and text over photos and video, which stay dark in either theme.
  Color get onMedia => const Color(0xFFF4F5F7);

  static const light = TincanColors(
    bg: Color(0xFFF5F3EF),
    panel: Color(0xFFFBFAF7),
    dialog: Color(0xFFFDFCFA),
    border: Color(0xFFE4E0D8),
    fieldBorder: Color(0xFFDCD8D0),
    field: Color(0xFFFFFFFF),
    fieldFill: Color(0xFFF3F1EC),
    ink: Tc.brandNavy,
    inkMuted: Color(0xFF555C69),
    inkFaint: Color(0xFF6B7280),
    label: Color(0xFF6E7481),
    accent: Tc.brandTeal,
    accentInk: Color(0xFFF4FBFA),
    accentSoft: Color(0xFFE2F0EF),
    highlight: Tc.brandOrange,
    disabled: Color(0xFFD5D8DD),
    disabledInk: Color(0xFF8A909B),
    sidebar: Tc.brandNavy,
    sidebarCard: Color(0xFF29303F),
    sidebarCardBorder: Color(0xFF39414F),
    sidebarSelected: Color(0xFF333B4B),
    sidebarText: Color(0xFFEDEFF3),
    sidebarMuted: Color(0xFFA9B1BE),
    sidebarFaint: Color(0xFF959FAE),
    sidebarAddress: Color(0xFFDCE1E8),
    online: Color(0xFF6FBF8F),
    requestBg: Color(0xFF33302A),
    requestBorder: Color(0xFF4A4436),
    acceptBg: Color(0xFF275C48),
    acceptInk: Color(0xFFB9E2C8),
    refuseBg: Color(0xFF5A302B),
    refuseInk: Color(0xFFE9B8B2),
    bubbleIn: Color(0xFFFFFFFF),
    bubbleInBorder: Color(0xFFE7E3DA),
    bubbleOut: Tc.brandTeal,
    bubbleOutInk: Color(0xFFF4FBFA),
    mediaOut: Color(0xFFE2F0EF),
    mediaOutBorder: Color(0xFFC3DEDC),
    mediaPlaceholder: Color(0xFFEFEDE8),
    videoBg: Color(0xFF23282F),
    directGreen: Color(0xFF2F855A),
    directGreenInk: Color(0xFF276749),
    directGreenBg: Color(0xFFE8F3EC),
    directGreenBorder: Color(0xFFC6E2D1),
    relayAmber: Color(0xFFB7791F),
    relayAmberInk: Color(0xFF8A5A12),
    relayAmberBg: Color(0xFFF7EFDD),
    relayAmberBorder: Color(0xFFE6D3A8),
    offline: Color(0xFF6B7280),
    danger: Color(0xFFB03A2E),
    dangerInk: Color(0xFF8A2E24),
    dangerBg: Color(0xFFF3E4E1),
    dangerBorder: Color(0xFFE3C6C1),
    shadow: Color(0x24503C14),
  );

  static const dark = TincanColors(
    bg: Color(0xFF181D29),
    panel: Color(0xFF1E2433),
    dialog: Color(0xFF212838),
    border: Color(0xFF313949),
    fieldBorder: Color(0xFF3D4657),
    field: Color(0xFF232A3A),
    fieldFill: Color(0xFF2A3142),
    ink: Color(0xFFE9ECF1),
    inkMuted: Color(0xFFB1B8C4),
    inkFaint: Color(0xFF959EAD),
    label: Color(0xFF9CA5B3),
    accent: Color(0xFF4DB6B2),
    accentInk: Color(0xFF0E1A1E),
    accentSoft: Color(0xFF1D3B3D),
    highlight: Tc.brandOrange,
    disabled: Color(0xFF353D4D),
    disabledInk: Color(0xFF8B94A3),
    sidebar: Color(0xFF131824),
    sidebarCard: Color(0xFF1E2433),
    sidebarCardBorder: Color(0xFF2E3646),
    sidebarSelected: Color(0xFF283041),
    sidebarText: Color(0xFFEDEFF3),
    sidebarMuted: Color(0xFFA9B1BE),
    sidebarFaint: Color(0xFF8E98A8),
    sidebarAddress: Color(0xFFDCE1E8),
    online: Color(0xFF6FBF8F),
    requestBg: Color(0xFF2E2B25),
    requestBorder: Color(0xFF4A4436),
    acceptBg: Color(0xFF275C48),
    acceptInk: Color(0xFFB9E2C8),
    refuseBg: Color(0xFF5A302B),
    refuseInk: Color(0xFFE9B8B2),
    bubbleIn: Color(0xFF252C3C),
    bubbleInBorder: Color(0xFF323A4B),
    bubbleOut: Color(0xFF17676A),
    bubbleOutInk: Color(0xFFEAF6F5),
    mediaOut: Color(0xFF173A3D),
    mediaOutBorder: Color(0xFF235254),
    mediaPlaceholder: Color(0xFF2A3142),
    videoBg: Color(0xFF10141B),
    directGreen: Color(0xFF48BB78),
    directGreenInk: Color(0xFF9AE6B4),
    directGreenBg: Color(0xFF1B3127),
    directGreenBorder: Color(0xFF2A4A3A),
    relayAmber: Color(0xFFE0A445),
    relayAmberInk: Color(0xFFF6CF8A),
    relayAmberBg: Color(0xFF362C18),
    relayAmberBorder: Color(0xFF5A4826),
    offline: Color(0xFF8C95A4),
    danger: Color(0xFFF08A7E),
    dangerInk: Color(0xFFF2B8B0),
    dangerBg: Color(0xFF3A2220),
    dangerBorder: Color(0xFF5A3430),
    shadow: Color(0x66000000),
  );

  static TincanColors of(BuildContext context) =>
      Theme.of(context).extension<TincanColors>() ?? light;

  /// Compact outlined action in an accent ink (Unblock, Reconnect, Change…).
  ButtonStyle get accentOutline => OutlinedButton.styleFrom(
        foregroundColor: accent,
        side: BorderSide(color: border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        minimumSize: Size(0, minTap),
      );

  @override
  TincanColors copyWith() => this;

  @override
  TincanColors lerp(TincanColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return TincanColors(
      bg: mix(bg, other.bg),
      panel: mix(panel, other.panel),
      dialog: mix(dialog, other.dialog),
      border: mix(border, other.border),
      fieldBorder: mix(fieldBorder, other.fieldBorder),
      field: mix(field, other.field),
      fieldFill: mix(fieldFill, other.fieldFill),
      ink: mix(ink, other.ink),
      inkMuted: mix(inkMuted, other.inkMuted),
      inkFaint: mix(inkFaint, other.inkFaint),
      label: mix(label, other.label),
      accent: mix(accent, other.accent),
      accentInk: mix(accentInk, other.accentInk),
      accentSoft: mix(accentSoft, other.accentSoft),
      highlight: mix(highlight, other.highlight),
      disabled: mix(disabled, other.disabled),
      disabledInk: mix(disabledInk, other.disabledInk),
      sidebar: mix(sidebar, other.sidebar),
      sidebarCard: mix(sidebarCard, other.sidebarCard),
      sidebarCardBorder: mix(sidebarCardBorder, other.sidebarCardBorder),
      sidebarSelected: mix(sidebarSelected, other.sidebarSelected),
      sidebarText: mix(sidebarText, other.sidebarText),
      sidebarMuted: mix(sidebarMuted, other.sidebarMuted),
      sidebarFaint: mix(sidebarFaint, other.sidebarFaint),
      sidebarAddress: mix(sidebarAddress, other.sidebarAddress),
      online: mix(online, other.online),
      requestBg: mix(requestBg, other.requestBg),
      requestBorder: mix(requestBorder, other.requestBorder),
      acceptBg: mix(acceptBg, other.acceptBg),
      acceptInk: mix(acceptInk, other.acceptInk),
      refuseBg: mix(refuseBg, other.refuseBg),
      refuseInk: mix(refuseInk, other.refuseInk),
      bubbleIn: mix(bubbleIn, other.bubbleIn),
      bubbleInBorder: mix(bubbleInBorder, other.bubbleInBorder),
      bubbleOut: mix(bubbleOut, other.bubbleOut),
      bubbleOutInk: mix(bubbleOutInk, other.bubbleOutInk),
      mediaOut: mix(mediaOut, other.mediaOut),
      mediaOutBorder: mix(mediaOutBorder, other.mediaOutBorder),
      mediaPlaceholder: mix(mediaPlaceholder, other.mediaPlaceholder),
      videoBg: mix(videoBg, other.videoBg),
      directGreen: mix(directGreen, other.directGreen),
      directGreenInk: mix(directGreenInk, other.directGreenInk),
      directGreenBg: mix(directGreenBg, other.directGreenBg),
      directGreenBorder: mix(directGreenBorder, other.directGreenBorder),
      relayAmber: mix(relayAmber, other.relayAmber),
      relayAmberInk: mix(relayAmberInk, other.relayAmberInk),
      relayAmberBg: mix(relayAmberBg, other.relayAmberBg),
      relayAmberBorder: mix(relayAmberBorder, other.relayAmberBorder),
      offline: mix(offline, other.offline),
      danger: mix(danger, other.danger),
      dangerInk: mix(dangerInk, other.dangerInk),
      dangerBg: mix(dangerBg, other.dangerBg),
      dangerBorder: mix(dangerBorder, other.dangerBorder),
      shadow: mix(shadow, other.shadow),
    );
  }
}

/// A button child that turns into a spinner while [busy].
Widget busyOr(bool busy, Widget child, {double size = 16}) => busy
    ? Builder(
        builder: (context) => SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: TincanColors.of(context).accentInk)))
    : child;

ThemeData tincanTheme() => _theme(TincanColors.light, Brightness.light);

ThemeData tincanDarkTheme() => _theme(TincanColors.dark, Brightness.dark);

ThemeData _theme(TincanColors c, Brightness brightness) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: c.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Tc.brandTeal,
      brightness: brightness,
      primary: c.accent,
      onPrimary: c.accentInk,
      surface: c.bg,
      onSurface: c.ink,
      error: c.danger,
    ),
  );
  final radius10 = BorderRadius.circular(10);
  return base.copyWith(
    extensions: [c],
    // Fonts are bundled, not fetched: google_fonts downloads from
    // Google at runtime, which this app has no business doing.
    textTheme: base.textTheme
        .apply(fontFamily: 'SchibstedGrotesk', bodyColor: c.ink, displayColor: c.ink),
    dividerColor: c.border,
    dialogTheme: DialogThemeData(
      backgroundColor: c.dialog,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        side: BorderSide(color: c.border),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(color: c.dialog),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: c.sidebarCard, borderRadius: BorderRadius.circular(6)),
      textStyle: TextStyle(fontSize: 12, color: c.sidebarText),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.sidebarCard,
      contentTextStyle: TextStyle(color: c.sidebarText, fontSize: 13.5),
    ),
    inputDecorationTheme: InputDecorationTheme(
      labelStyle: TextStyle(color: c.inkMuted),
      hintStyle: TextStyle(color: c.inkFaint),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius10,
        borderSide: BorderSide(color: c.fieldBorder),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: radius10,
        borderSide: BorderSide(color: c.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius10,
        borderSide: BorderSide(color: c.accent),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.ink,
        side: BorderSide(color: c.fieldBorder),
        shape: RoundedRectangleBorder(borderRadius: radius10),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        minimumSize: Size(0, minTap),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.accentInk,
        disabledBackgroundColor: c.disabled,
        disabledForegroundColor: c.disabledInk,
        shape: RoundedRectangleBorder(borderRadius: radius10),
        minimumSize: Size(0, minTap),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.accent, minimumSize: Size(0, minTap)),
    ),
  );
}
