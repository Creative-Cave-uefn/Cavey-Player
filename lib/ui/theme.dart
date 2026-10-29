import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Палитра «ночная полка»: глубокий чернильно-синий и жёлтый, как маркер
/// на кассетной наклейке. У каждого друга свой цвет — по нему видно,
/// кто принёс трек и кому он нравится.
class C {
  static const bg = Color(0xFF12162A);
  static const surface = Color(0xFF181D36);
  static const raised = Color(0xFF222947);
  static const hover = Color(0xFF283058);
  static const line = Color(0xFF2D3459);
  static const text = Color(0xFFEDE9E1);
  static const muted = Color(0xFF9399B8);
  static const faint = Color(0xFF626A8F);
  static const accent = Color(0xFFF2C14E);
  static const accentInk = Color(0xFF241C06);
  static const danger = Color(0xFFFF8A80);
}

const friendPalette = [
  Color(0xFFFF8A80),
  Color(0xFF7CD3B8),
  Color(0xFF8AB4FF),
  Color(0xFFE2A6FF),
  Color(0xFFFFB463),
  Color(0xFFA6E37D),
  Color(0xFFFF9EC7),
  Color(0xFF6FD6F0),
];

Color friendColor(String email) {
  var h = 0;
  for (final c in email.toLowerCase().codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return friendPalette[h % friendPalette.length];
}

TextStyle _font(String family, TextStyle base) {
  try {
    return GoogleFonts.getFont(family, textStyle: base);
  } catch (_) {
    return base;
  }
}

/// Заголовочный шрифт — широкий Unbounded
TextStyle display(double size, {FontWeight weight = FontWeight.w600, Color color = C.text, double? height}) =>
    _font('Unbounded', TextStyle(fontSize: size, fontWeight: weight, color: color, height: height ?? 1.15, letterSpacing: -0.3));

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: C.bg,
    colorScheme: const ColorScheme.dark(
      primary: C.accent,
      onPrimary: C.accentInk,
      secondary: C.accent,
      onSecondary: C.accentInk,
      surface: C.surface,
      onSurface: C.text,
      error: C.danger,
      outline: C.line,
    ),
    dividerColor: C.line,
    splashFactory: NoSplash.splashFactory,
  );
  TextTheme textTheme;
  try {
    textTheme = GoogleFonts.getTextTheme('Golos Text', base.textTheme);
  } catch (_) {
    textTheme = base.textTheme;
  }
  textTheme = textTheme.apply(bodyColor: C.text, displayColor: C.text);

  return base.copyWith(
    textTheme: textTheme,
    hoverColor: C.hover.withValues(alpha: 0.6),
    highlightColor: Colors.transparent,
    iconTheme: const IconThemeData(color: C.muted, size: 20),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(6), border: Border.all(color: C.line)),
      textStyle: textTheme.bodySmall?.copyWith(color: C.text),
      waitDuration: const Duration(milliseconds: 400),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.raised,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      hintStyle: const TextStyle(color: C.faint),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: C.accent, width: 1.5)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: C.accent,
        foregroundColor: C.accentInk,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: C.text,
        side: const BorderSide(color: C.line),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: const StadiumBorder(),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: C.accent)),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      activeTrackColor: C.text,
      inactiveTrackColor: C.line,
      thumbColor: C.text,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: C.raised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: C.line)),
      textStyle: textTheme.bodyMedium,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: C.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.raised,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: C.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: C.accent, linearTrackColor: C.line),
  );
}
