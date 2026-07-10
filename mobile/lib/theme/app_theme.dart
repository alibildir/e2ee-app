import 'package:flutter/material.dart';

/// Sprint 10.0 — OpenE2EE design tokens.
///
/// Colors are taken verbatim from the approved wireframe
/// (`sprint10-wireframes.html`):
///   - primary  = #2f6f5e (deep teal, Bilgilendirme hero + buttons)
///   - accent   = #c97b3f (warm orange, FAB + RCS icon)
///   - whatsapp = #25d366 (WhatsApp brand green, button + WA icon)
///   - bg       = #fafaf7 (paper warm white, screen background)
///   - surface  = #ffffff (card / app bar)
///   - text     = #14171e
///   - muted    = #7c7a72
///   - border   = #e9e3d6
class AppTheme {
  AppTheme._();

  static const Color primary = Color(0xFF2F6F5E);
  static const Color primaryDark = Color(0xFF1F4D40);
  static const Color accent = Color(0xFFC97B3F);
  static const Color accentDark = Color(0xFFA05E2F);
  static const Color whatsapp = Color(0xFF25D366);
  static const Color whatsappBubble = Color(0xFFDCF8C6);
  static const Color bg = Color(0xFFFAFAF7);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color text = Color(0xFF14171E);
  static const Color muted = Color(0xFF7C7A72);
  static const Color border = Color(0xFFE9E3D6);
  static const Color danger = Color(0xFFB06367);

  static ThemeData light() {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: Brightness.light,
      primary: primary,
      onPrimary: Colors.white,
      secondary: accent,
      onSecondary: Colors.white,
      surface: surface,
      onSurface: text,
      error: danger,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: bg,
      fontFamily: 'Outfit',
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: text,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: text),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: border),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: primary,
        unselectedItemColor: muted,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
        showUnselectedLabels: true,
        selectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        unselectedLabelStyle: TextStyle(fontSize: 11),
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
    );
  }

  static ThemeData dark() {
    // Sprint 10.0 ships light only; dark is a minimal mirror so the system
    // theme toggle does not crash. Visual parity with light is not a goal.
    return light();
  }
}
