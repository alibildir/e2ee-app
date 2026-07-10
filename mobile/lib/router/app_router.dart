import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/active_pool_screen.dart';
import '../screens/bilgilendirme_screen.dart';
import '../screens/home_screen.dart';
import '../screens/whatsapp_task_detail_screen.dart';
import '../state/is_accepted_provider.dart';

/// Sprint 10.0 — go_router config.
///
/// Routes:
///   /                                  → redirect to /bilgilendirme or /home
///                                       (driven by isAcceptedProvider)
///   /bilgilendirme                     → BilgilendirmeScreen (initial consent)
///   /home                              → HomeScreen (Görevler tab)
///   /home/gorevler                     → HomeScreen (alias of /home)
///   /home/aktif-nobet                  → ActivePoolScreen
///   /home/skorlar                      → HomeScreen placeholder (Sprint 10.2+)
///   /home/gorevler/whatsapp            → WhatsAppTaskDetailScreen
class AppRouter {
  AppRouter._();

  static final GoRouter config = GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      // The redirect is evaluated against a fresh `ProviderContainer`
      // so we hand-roll a one-shot read to avoid coupling go_router
      // to WidgetRef.
      final container = ProviderScope.containerOf(context);
      final accepted = container.read(isAcceptedProvider);
      final goingToBilgi = state.matchedLocation == '/bilgilendirme';
      if (!accepted && !goingToBilgi) {
        return '/bilgilendirme';
      }
      if (accepted && goingToBilgi) {
        return '/home';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        redirect: (context, state) => '/bilgilendirme',
      ),
      GoRoute(
        path: '/bilgilendirme',
        builder: (context, state) => const BilgilendirmeScreen(),
      ),
      GoRoute(
        path: '/home/gorevler',
        builder: (context, state) => const HomeScreen(),
        routes: [
          GoRoute(
            path: 'whatsapp',
            builder: (context, state) => const WhatsAppTaskDetailScreen(),
          ),
        ],
      ),
      GoRoute(
        path: '/home',
        redirect: (context, state) => '/home/gorevler',
      ),
      GoRoute(
        path: '/home/aktif-nobet',
        builder: (context, state) => const ActivePoolScreen(),
      ),
      GoRoute(
        path: '/home/skorlar',
        builder: (context, state) => const _SkorlarPlaceholder(),
      ),
    ],
  );
}

/// Sprint 10.2+ placeholder. Today: same shell as HomeScreen with a
/// "Skorlar — Sprint 10.2+" message so the bottom-nav 3rd tab is
/// discoverable but does not lie about a missing screen.
class _SkorlarPlaceholder extends StatelessWidget {
  const _SkorlarPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Skorlar'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/home/gorevler'),
        ),
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bar_chart_outlined, size: 48, color: Color(0xFF7C7A72)),
              SizedBox(height: 12),
              Text(
                'Skorlar — Sprint 10.2+',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF14171E),
                ),
              ),
              SizedBox(height: 6),
              Text(
                'fl_chart entegrasyonu Sprint 10.2 ile gelecek.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF7C7A72),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
