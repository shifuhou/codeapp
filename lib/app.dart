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

const monoFamilies = [
  'JetBrains Mono', 'Fira Code', 'Cascadia Code', 'SF Mono', 'Menlo',
  'Consolas', 'DejaVu Sans Mono', 'Liberation Mono', 'monospace',
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
