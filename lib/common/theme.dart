// Adapted from PiliPlus lib/utils/theme_utils.dart::getThemeData and
// lib/common/style.dart, commit d9e9626f1a3f89cd9ca85e18f61aaba02634e12a.
// Original source: https://github.com/bggRGjQaUbCoE/PiliPlus (GNU GPL v3).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent;

import '../storage/app_storage.dart';

class AppAppearance extends ChangeNotifier {
  static const defaultSeedColor = 0xFFE57373;

  AppAppearance(this.storage) {
    _load();
  }

  final AppStorage storage;
  ThemeMode _themeMode = ThemeMode.system;
  Color _seedColor = const Color(defaultSeedColor);
  double _textScale = 1;
  bool _oledBlack = false;
  final _pending = <String, Object>{};
  String? error;

  void reload() {
    _load();
    notifyListeners();
  }

  void _load() {
    final settings = storage.state['settings'] as Map;
    final value = settings['appearance'] as Map? ?? const {};
    final mode = value['themeMode'] ?? 'system';
    _themeMode = ThemeMode.values.firstWhere((item) => item.name == mode);
    final color = value['seedColor'] ?? defaultSeedColor;
    final scale = value['textScale'] ?? 1;
    final oledBlack = value['oledBlack'] ?? false;
    if (color is! int ||
        color < 0 ||
        color > 0xFFFFFFFF ||
        scale is! num ||
        !scale.isFinite ||
        scale < 0.8 ||
        scale > 1.5 ||
        oledBlack is! bool) {
      throw const FormatException('外观设置无效，请恢复有效备份');
    }
    _seedColor = Color(color);
    _textScale = scale.toDouble();
    _oledBlack = oledBlack;
  }

  Future<void> _save(Map<String, dynamic> changes) async {
    final request = Object();
    for (final key in changes.keys) {
      _pending[key] = request;
    }
    try {
      await storage.transaction((state) {
        final settings = state['settings'] as Map;
        final appearance = Map<String, dynamic>.from(
          settings['appearance'] as Map? ?? const {},
        );
        settings['appearance'] = appearance..addAll(changes);
      });
      _load();
      error = null;
    } catch (_) {
      error = '设置保存失败，原设置已保留';
    } finally {
      for (final key in changes.keys) {
        if (identical(_pending[key], request)) _pending.remove(key);
      }
    }
    notifyListeners();
  }

  ThemeMode get themeMode => _themeMode;
  Color get seedColor => _seedColor;
  double get textScale => _textScale;
  bool get oledBlack => _oledBlack;

  set themeMode(ThemeMode value) {
    if (!_pending.containsKey('themeMode') && _themeMode == value) return;
    unawaited(_save({'themeMode': value.name}));
  }

  set seedColor(Color value) {
    if (!_pending.containsKey('seedColor') && _seedColor == value) return;
    unawaited(_save({'seedColor': value.toARGB32()}));
  }

  set textScale(double value) {
    if (!value.isFinite || value < 0.8 || value > 1.5) {
      throw RangeError.value(
        value,
        'textScale',
        'Expected a finite value from 0.8 to 1.5',
      );
    }
    if (!_pending.containsKey('textScale') && _textScale == value) return;
    unawaited(_save({'textScale': value}));
  }

  set oledBlack(bool value) {
    if (!_pending.containsKey('oledBlack') && _oledBlack == value) return;
    unawaited(_save({'oledBlack': value}));
  }
}

class AppTextScaler extends TextScaler {
  const AppTextScaler(this.systemScaler, this.appScale);

  final TextScaler systemScaler;
  final double appScale;

  @override
  double scale(double fontSize) => systemScaler.scale(fontSize) * appScale;

  @override
  double get textScaleFactor => scale(14) / 14;
}

ThemeData getThemeData({
  required Color seedColor,
  required Brightness brightness,
  bool oledBlack = false,
}) {
  const fontFamily = 'HarmonyOS Sans SC';
  final isOled = brightness == Brightness.dark && oledBlack;
  var colorScheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
  );
  if (isOled) {
    colorScheme = colorScheme.copyWith(
      surface: Colors.black,
      surfaceDim: Colors.black,
      surfaceBright: const Color(0xFF202020),
      surfaceContainerLowest: Colors.black,
      surfaceContainerLow: const Color(0xFF0A0A0A),
      surfaceContainer: const Color(0xFF101010),
      surfaceContainerHigh: const Color(0xFF181818),
      surfaceContainerHighest: const Color(0xFF242424),
      outline: const Color(0xFF96908E),
      outlineVariant: const Color(0xFF45413F),
    );
  }
  final buttonStyle = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    shadowColor: const WidgetStatePropertyAll(Colors.transparent),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colorScheme,
    fontFamily: fontFamily,
    scaffoldBackgroundColor: colorScheme.surface,
    canvasColor: colorScheme.surface,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 15),
      bodyMedium: TextStyle(fontSize: 14),
      bodySmall: TextStyle(fontSize: 12),
      titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      headlineLarge: TextStyle(fontSize: 26),
      headlineMedium: TextStyle(fontSize: 24),
      headlineSmall: TextStyle(fontSize: 20),
      labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      labelMedium: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
    ),
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {
        ...const PageTransitionsTheme().builders,
        TargetPlatform.android: const _FadePageTransitionsBuilder(),
      },
    ),
    appBarTheme: AppBarTheme(
      elevation: 0,
      titleSpacing: 16,
      centerTitle: false,
      scrolledUnderElevation: 0,
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 16,
        fontWeight: FontWeight.normal,
        color: colorScheme.onSurface,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: isOled ? Colors.black : colorScheme.surfaceContainer,
      surfaceTintColor: Colors.transparent,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: colorScheme.surface,
    ),
    snackBarTheme: SnackBarThemeData(
      elevation: 0,
      actionTextColor: colorScheme.primary,
      closeIconColor: colorScheme.secondary,
      backgroundColor: colorScheme.secondaryContainer,
      contentTextStyle: TextStyle(
        fontFamily: fontFamily,
        color: colorScheme.onSecondaryContainer,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(surfaceTintColor: Colors.transparent),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colorScheme.surfaceContainerLow,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: colorScheme.outlineVariant),
      ),
    ),
    dialogTheme: DialogThemeData(
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 18,
        fontWeight: FontWeight.normal,
        color: colorScheme.onSurface,
      ),
      backgroundColor: colorScheme.surface,
      constraints: const BoxConstraints(minWidth: 280, maxWidth: 420),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colorScheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
    ),
    tooltipTheme: const TooltipThemeData(
      textStyle: TextStyle(
        fontFamily: fontFamily,
        fontSize: 14,
        color: Colors.white,
      ),
      decoration: BoxDecoration(
        color: Color(0xE6616161),
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
    ),
    listTileTheme: const ListTileThemeData(
      controlAffinity: ListTileControlAffinity.leading,
      minTileHeight: 48,
      minVerticalPadding: 10,
      horizontalTitleGap: 12,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colorScheme.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colorScheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colorScheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: colorScheme.primary, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    outlinedButtonTheme: OutlinedButtonThemeData(style: buttonStyle),
    textButtonTheme: TextButtonThemeData(style: buttonStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: buttonStyle.copyWith(elevation: const WidgetStatePropertyAll(0)),
    ),
  );
}

class _FadePageTransitionsBuilder extends PageTransitionsBuilder {
  const _FadePageTransitionsBuilder();

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _PredictiveBackFadeTransition(
    route: route,
    animation: animation,
    child: child,
  );
}

class _PredictiveBackFadeTransition extends StatefulWidget {
  const _PredictiveBackFadeTransition({
    required this.route,
    required this.animation,
    required this.child,
  });

  final PageRoute<dynamic> route;
  final Animation<double> animation;
  final Widget child;

  @override
  State<_PredictiveBackFadeTransition> createState() =>
      _PredictiveBackFadeTransitionState();
}

class _PredictiveBackFadeTransitionState
    extends State<_PredictiveBackFadeTransition>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent ||
        !widget.route.isCurrent ||
        !widget.route.popGestureEnabled) {
      return false;
    }
    widget.route.handleStartBackGesture(progress: 1 - backEvent.progress);
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) => widget
      .route
      .handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);

  @override
  void handleCancelBackGesture() => widget.route.handleCancelBackGesture();

  @override
  void handleCommitBackGesture() => widget.route.handleCommitBackGesture();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: widget.animation, child: widget.child);
}
