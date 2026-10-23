import 'package:flutter/material.dart';

/// Avora's look: brand green, Manrope type, soft rounded surfaces.
abstract final class Brand {
  static const green = Color(0xFF0B6E4F);
  static const deepGreen = Color(0xFF053D2C);
  static const mint = Color(0xFF3DDC97);
  static const lime = Color(0xFFC8F169);
  static const danger = Color(0xFFD64545);
  static const warning = Color(0xFFE8A317);

  static const cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF0E8A63), green, deepGreen],
  );
}

/// Manrope is a variable font, so each weight is set on the wght axis too.
TextStyle _w(double size, double weight, {double? height, double spacing = 0}) => TextStyle(
  fontFamily: 'Manrope',
  fontSize: size,
  height: height,
  letterSpacing: spacing,
  fontWeight: FontWeight.values[((weight ~/ 100) - 1).clamp(0, 8)],
  fontVariations: [FontVariation.weight(weight)],
);

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: Brand.green,
    brightness: brightness,
    primary: dark ? Brand.mint : Brand.green,
    onPrimary: dark ? Brand.deepGreen : Colors.white,
    error: Brand.danger,
    surface: dark ? const Color(0xFF0F1513) : Colors.white,
  );
  final background = dark ? const Color(0xFF080C0B) : const Color(0xFFF4F7F5);
  final textTheme = TextTheme(
    displaySmall: _w(36, 800, spacing: -1),
    headlineMedium: _w(28, 800, spacing: -0.5),
    headlineSmall: _w(24, 800, spacing: -0.5),
    titleLarge: _w(20, 700),
    titleMedium: _w(16, 700),
    titleSmall: _w(14, 700),
    bodyLarge: _w(16, 500, height: 1.45),
    bodyMedium: _w(14, 500, height: 1.45),
    bodySmall: _w(12.5, 500, height: 1.4),
    labelLarge: _w(15, 700),
    labelMedium: _w(13, 600),
    labelSmall: _w(11, 600, spacing: 0.3),
  ).apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

  final radius = BorderRadius.circular(16);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Manrope',
    textTheme: textTheme,
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: textTheme.titleMedium,
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: radius),
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: radius),
        side: BorderSide(color: scheme.outlineVariant),
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(textStyle: textTheme.labelLarge)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF17201D) : const Color(0xFFF0F3F1),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      border: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: radius, borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: Brand.danger),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: const BorderSide(color: Brand.danger, width: 1.5),
      ),
      labelStyle: textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      hintStyle: textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: scheme.primary.withValues(alpha: 0.12),
      height: 68,
      labelTextStyle: WidgetStatePropertyAll(textTheme.labelSmall),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5), space: 1),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      side: BorderSide.none,
      labelStyle: textTheme.labelMedium,
    ),
  );
}
