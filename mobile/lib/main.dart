import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router/app_router.dart';
import 'theme/app_theme.dart';

/// Sprint 10.0 — OpenE2EE root app.
///
/// Wires `ProviderScope` (Riverpod) at the root and `MaterialApp.router`
/// (go_router) for declarative navigation. The `themeMode` is
/// `system` so the OS-level dark mode switch is honored when we ship a
/// real dark theme; for now both modes resolve to the light theme.
void main() {
  runApp(const ProviderScope(child: OpenE2EEApp()));
}

class OpenE2EEApp extends StatelessWidget {
  const OpenE2EEApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'OpenE2EE',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      routerConfig: AppRouter.config,
      debugShowCheckedModeBanner: false,
    );
  }
}
