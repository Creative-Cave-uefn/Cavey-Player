import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Палитра «стекло»: под всем окном — размытая обложка текущего трека,
/// панели поверх неё полупрозрачные, как матовое стекло. Жёлтый — фирменная точка:
/// главное действие и то, что включено. У каждого друга свой цвет.
class C {
  static const bg = Color(0xFF0E1122); // основа, пока нет обложки
  static const surface = Color(0x14FFFFFF); // стекло: боковая панель, плеер, карточки
  static const raised = Color(0x1FFFFFFF); // приподнятое стекло: поля, чипы, плашки
  static const hover = Color(0x29FFFFFF);
  static const line = Color(0x2EFFFFFF); // светлая обводка стекла
  static const divider = Color(0x14FFFFFF); // тонкие разделители строк

  /// Наведение и нажатие поверх стекла: лёгкая подсветка, а не белая плашка
  static const hoverOverlay = Color(0x14FFFFFF);
  static const pressOverlay = Color(0x24FFFFFF);

  /// Матовое стекло всплывающих окон, меню и уведомлений: под ним всё размыто (см. GlassPanel)
  static const glass = Color(0xA614141B);

  /// Плотные панели там, где размыть нельзя: подсказки, плашки поверх списков.
  /// Нейтральные тёмные, без синевы — подходят к любому цвету фона
  static const panel = Color(0xF0191920);
  static const panelRaised = Color(0xF5232330);
  static const text = Color(0xFFEDE9E1);
  // Вторичный текст — нейтральный белый с прозрачностью: читается на любой обложке под стеклом
  static const muted = Color(0xB8FFFFFF);
  static const faint = Color(0x8CFFFFFF);
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

/// Заголовки: тот же Golos, только жирнее и плотнее — спокойно, как в Apple Music.
/// Широкий Unbounded остался только у логотипа
TextStyle display(double size, {FontWeight weight = FontWeight.w600, Color color = C.text, double? height}) => _font(
    'Golos Text',
    TextStyle(
        fontSize: size,
        fontWeight: weight.index < FontWeight.w700.index ? FontWeight.w700 : weight,
        color: color,
        height: height ?? 1.15,
        letterSpacing: size >= 24 ? -0.6 : -0.2));

TextStyle brand(double size, {Color color = C.text}) =>
    _font('Unbounded', TextStyle(fontSize: size, fontWeight: FontWeight.w700, color: color, letterSpacing: -0.3));

ThemeData buildTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: C.panel,
    cardColor: C.panel,
    colorScheme: const ColorScheme.dark(
      primary: C.accent,
      onPrimary: C.accentInk,
      secondary: C.accent,
      onSecondary: C.accentInk,
      surface: C.panel,
      onSurface: C.text,
      error: C.danger,
      outline: C.line,
    ),
    dividerColor: C.divider,
    splashFactory: NoSplash.splashFactory,
    hoverColor: C.hoverOverlay,
    highlightColor: C.pressOverlay,
    focusColor: C.pressOverlay,
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
    // Раньше здесь был C.hover с прозрачностью 0.6: для прозрачного белого это давало почти белую плашку
    hoverColor: C.hoverOverlay,
    highlightColor: C.pressOverlay,
    focusColor: C.pressOverlay,
    dividerTheme: const DividerThemeData(color: C.divider, space: 1, thickness: 1),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        overlayColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.pressed)
            ? C.pressOverlay
            : (s.contains(WidgetState.hovered) || s.contains(WidgetState.focused) ? C.hoverOverlay : null)),
      ),
    ),
    chipTheme: const ChipThemeData(
      backgroundColor: C.raised,
      selectedColor: C.accent,
      disabledColor: C.surface,
      side: BorderSide(color: C.line),
      shape: StadiumBorder(),
      showCheckmark: false,
      labelStyle: TextStyle(color: C.text, fontWeight: FontWeight.w500),
      secondaryLabelStyle: TextStyle(color: C.accentInk, fontWeight: FontWeight.w600),
      iconTheme: IconThemeData(color: C.text, size: 18),
    ),
    listTileTheme: ListTileThemeData(
      selectedTileColor: C.hover,
      selectedColor: C.text,
      iconColor: C.muted,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    switchTheme: SwitchThemeData(
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.accent : C.raised),
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.accentInk : C.muted),
      trackOutlineColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.transparent : C.line),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.accent : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(C.accentInk),
      side: const BorderSide(color: C.muted, width: 1.5),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? C.accent : C.muted),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.dragged)
          ? const Color(0x59FFFFFF)
          : const Color(0x2EFFFFFF)),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(6),
    ),
    iconTheme: const IconThemeData(color: C.muted, size: 20),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: C.panelRaised, borderRadius: BorderRadius.circular(8), border: Border.all(color: C.line)),
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
    // Текстовые кнопки — светлые: жёлтый текст терялся на тёплых обложках. Жёлтый остался у главных действий
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: C.text,
        shape: const StadiumBorder(),
      ).copyWith(
        overlayColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.pressed)
            ? C.pressOverlay
            : (s.contains(WidgetState.hovered) ? C.hoverOverlay : null)),
      ),
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      activeTrackColor: C.text,
      inactiveTrackColor: C.line,
      thumbColor: C.text,
      overlayShape: RoundSliderOverlayShape(overlayRadius: 12),
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 5),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: C.panelRaised,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: C.line)),
      textStyle: textTheme.bodyMedium,
    ),
    dialogTheme: DialogThemeData(
      // Окна открываются через showGlassDialog: всё позади размыто, само окно — полупрозрачное стекло
      backgroundColor: C.glass,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: C.line)),
    ),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: C.panel),
    menuTheme: const MenuThemeData(style: MenuStyle(backgroundColor: WidgetStatePropertyAll(C.panelRaised))),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: C.panelRaised,
      contentTextStyle: textTheme.bodyMedium?.copyWith(color: C.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: C.accent, linearTrackColor: C.line),
  );
}
