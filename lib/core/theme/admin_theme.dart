// lib/core/theme/admin_theme.dart
import 'package:flutter/material.dart';

class AdminColors {
  static const bg = Color(0xFF0F1117);
  static const surface = Color(0xFF1A1D27);
  static const surfaceHover = Color(0xFF21253A);
  static const border = Color(0xFF2A2D3E);
  static const accent = Color(0xFF00E5A0); // vert terminal
  static const accentDim = Color(0xFF00E5A026);
  static const textPrimary = Color(0xFFE8EAF0);
  static const textSecondary = Color(0xFF6B7280);
  static const danger = Color(0xFFEF4444);
  static const dangerDim = Color(0xFFEF444420);
  static const warning = Color(0xFFF59E0B);
  static const warningDim = Color(0xFFF59E0B20);
}

ThemeData buildAdminTheme() {
  return ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AdminColors.bg,
    colorScheme: const ColorScheme.dark(
      surface: AdminColors.surface,
      primary: AdminColors.accent,
      error: AdminColors.danger,
    ),
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: AdminColors.textPrimary,
        letterSpacing: -0.5,
      ),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AdminColors.textPrimary,
      ),
      bodyMedium: TextStyle(
        fontSize: 13,
        color: AdminColors.textSecondary,
        height: 1.5,
      ),
      labelSmall: TextStyle(
        fontSize: 11,
        color: AdminColors.textSecondary,
        letterSpacing: 0.8,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AdminColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AdminColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AdminColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AdminColors.accent, width: 1.5),
      ),
      hintStyle: const TextStyle(color: AdminColors.textSecondary, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AdminColors.accent,
        foregroundColor: AdminColors.bg,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
          letterSpacing: 0.2,
        ),
      ),
    ),
    dividerColor: AdminColors.border,
  );
}
