import 'package:flutter/material.dart';

abstract final class AppColors {
  static const gold = Color(0xFFD4AF37);
  static const champagne = Color(0xFFE8D5A3);
  static const midnight = Color(0xFF0A0A0B);
  static const background = Color(0xFF18181B);
  static const surface = Color(0xFF242427);
  static const elevated = Color(0xFF2D2D30);
  static const selected = Color(0xFF44391F);
  static const text = Color(0xFFFAFAF9);
  static const muted = Color(0xFFA1A1AA);
  static const border = Color(0xFF3F3F46);
  static const success = Color(0xFF4ADE80);
  static const error = Color(0xFFF87171);
  static const warning = Color(0xFFFBBF24);
}

abstract final class AppSpacing {
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

abstract final class AppRadius {
  static const control = 14.0;
  static const card = 20.0;
}

abstract final class AppTypography {
  static const heading = TextStyle(
    fontSize: 36,
    height: 1.12,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.2,
  );
  static const section = TextStyle(
    fontSize: 22,
    height: 1.25,
    fontWeight: FontWeight.w700,
  );
  static const body = TextStyle(fontSize: 15, height: 1.5);
  static const action = TextStyle(fontSize: 15, fontWeight: FontWeight.w700);
}

ThemeData darkTheme() {
  final colors = ColorScheme.fromSeed(
    seedColor: AppColors.gold,
    brightness: Brightness.dark,
    primary: AppColors.gold,
    onPrimary: AppColors.midnight,
    secondary: AppColors.champagne,
    surface: AppColors.surface,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.muted,
    outline: AppColors.border,
    error: AppColors.error,
  );
  const control = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppRadius.control)),
  );
  OutlineInputBorder outline(Color color) => OutlineInputBorder(
    borderSide: BorderSide(color: color),
    borderRadius: const BorderRadius.all(Radius.circular(AppRadius.control)),
  );
  final base = ThemeData(colorScheme: colors, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    dividerColor: AppColors.border,
    textTheme: base.textTheme
        .copyWith(
          headlineLarge: AppTypography.heading,
          titleLarge: AppTypography.section,
          bodyLarge: AppTypography.body,
          bodyMedium: AppTypography.body,
          labelLarge: AppTypography.action,
        )
        .apply(bodyColor: AppColors.text, displayColor: AppColors.text),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.text,
      centerTitle: false,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.all(AppSpacing.md),
      labelStyle: const TextStyle(color: AppColors.muted),
      floatingLabelStyle: const TextStyle(color: AppColors.champagne),
      enabledBorder: outline(AppColors.border),
      focusedBorder: outline(AppColors.gold),
      disabledBorder: outline(AppColors.border),
      errorBorder: outline(AppColors.error),
      focusedErrorBorder: outline(AppColors.error),
      errorMaxLines: 3,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        foregroundColor: AppColors.midnight,
        backgroundColor: AppColors.gold,
        disabledBackgroundColor: AppColors.elevated,
        disabledForegroundColor: AppColors.muted,
        minimumSize: const Size(48, 52),
        shape: control,
        elevation: 0,
        textStyle: AppTypography.action,
        padding: const EdgeInsets.all(AppSpacing.sm),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.champagne,
        minimumSize: const Size(48, 48),
        side: const BorderSide(color: AppColors.border),
        shape: control,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: AppColors.champagne,
        minimumSize: const Size(48, 48),
      ),
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: AppColors.border),
        borderRadius: BorderRadius.all(Radius.circular(AppRadius.card)),
      ),
    ),
    dialogTheme: const DialogThemeData(backgroundColor: AppColors.elevated),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.elevated,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    iconTheme: const IconThemeData(color: AppColors.champagne),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.champagne,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: AppColors.midnight,
      indicatorColor: AppColors.selected,
    ),
  );
}
