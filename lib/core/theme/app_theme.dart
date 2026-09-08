import 'package:flutter/material.dart';

/// KırtasiyePOS tasarım dili: lacivert + amber, slate zemin,
/// hairline border'lı beyaz kartlar (Stitch mockup'larından).
abstract class PosColors {
  static const navy = Color(0xFF1E3A8A);
  static const navyDark = Color(0xFF172554);
  static const royal = Color(0xFF2563EB);
  static const amber = Color(0xFFD97706);
  static const amberDark = Color(0xFFB45309);
  static const bg = Color(0xFFF8FAFC);
  static const cardBorder = Color(0xFFE2E8F0);
  static const ink = Color(0xFF0F172A);
  static const ink2 = Color(0xFF475569);

  static const okBg = Color(0xFFECFDF5);
  static const okBd = Color(0xFFA7F3D0);
  static const okTx = Color(0xFF065F46);

  static const warnBg = Color(0xFFFFFBEB);
  static const warnBd = Color(0xFFFDE68A);
  static const warnTx = Color(0xFF92400E);

  static const critBg = Color(0xFFFEF2F2);
  static const critBd = Color(0xFFFECACA);
  static const critTx = Color(0xFF991B1B);

  static const infoBg = Color(0xFFEFF6FF);
  static const infoBd = Color(0xFFBFDBFE);
  static const infoTx = Color(0xFF1E40AF);
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: PosColors.navy,
    surface: Colors.white,
  );
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: PosColors.bg,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: PosColors.navy,
      elevation: 0,
      scrolledUnderElevation: 1,
      titleTextStyle: TextStyle(
        color: PosColors.navy,
        fontSize: 20,
        fontWeight: FontWeight.w700,
      ),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: PosColors.cardBorder),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: PosColors.navy.withValues(alpha: 0.12),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final sel = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 12,
          fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
          color: sel ? PosColors.navy : PosColors.ink2,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>((states) {
        final sel = states.contains(WidgetState.selected);
        return IconThemeData(
            color: sel ? PosColors.navy : PosColors.ink2);
      }),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    ),
  );
}
