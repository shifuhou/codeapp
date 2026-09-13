import 'package:flutter/material.dart';

import 'features/hosts/hosts_page.dart';

class AppColors {
  static const bg = Color(0xFF1E1E1E);
  static const panel = Color(0xFF252526);
  static const panelAlt = Color(0xFF2D2D2D);
  static const border = Color(0xFF3C3C3C);
  static const accent = Color(0xFF4FC1FF);
  static const accentDim = Color(0xFF264F78);
  static const text = Color(0xFFD4D4D4);
  static const textDim = Color(0xFF9D9D9D);
  static const ok = Color(0xFF4EC9B0);
  static const warn = Color(0xFFDCDCAA);
  static const err = Color(0xFFF14C4C);
}

/// Chinese/Japanese/Korean fallbacks, best first per platform. Without an
/// explicit list Flutter may pick a bitmap-looking font such as SimSun.
const cjkFamilies = [
  'Microsoft YaHei UI', 'Microsoft YaHei', // Windows
  'PingFang SC', 'Hiragino Sans GB', // macOS / iOS
  'Noto Sans CJK SC', 'Noto Sans SC', 'Source Han Sans SC', // Linux / Android
  'WenQuanYi Micro Hei', 'Droid Sans Fallback',
];

/// UI text: the platform's system font, then CJK fallbacks.
const uiFamilies = [
  'Segoe UI', // Windows
  '.SF NS', 'SF Pro Text', 'Helvetica Neue', // macOS / iOS
  'Roboto', 'Noto Sans', 'Ubuntu', 'DejaVu Sans', // Android / Linux
  ...cjkFamilies,
];

/// Code and terminal: JetBrains Mono is bundled with the app, so it is the
/// same on every platform; the rest only matter for glyphs it lacks.
const monoFamilies = [
  'JetBrains Mono',
  'Cascadia Code', 'Consolas', 'SF Mono', 'Menlo', 'DejaVu Sans Mono', 'Liberation Mono',
  ...cjkFamilies,
];

class CodeApp extends StatelessWidget {
  const CodeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.accent,
      brightness: Brightness.dark,
      surface: AppColors.bg,
    );
    return MaterialApp(
      title: 'CodeApp',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        fontFamilyFallback: uiFamilies,
        scaffoldBackgroundColor: AppColors.bg,
        canvasColor: AppColors.panel,
        dividerColor: AppColors.border,
        visualDensity: VisualDensity.compact,
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.panel,
          foregroundColor: AppColors.text,
          elevation: 0,
          centerTitle: false,
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: AppColors.panel,
          indicatorColor: AppColors.accentDim,
          height: 60,
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 11, color: AppColors.text),
          ),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
        listTileTheme: const ListTileThemeData(dense: true),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      ),
      home: const HostsPage(),
    );
  }
}
