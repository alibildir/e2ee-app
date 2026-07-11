import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../screens/active_pool_screen.dart';
import '../screens/bilgilendirme_screen.dart';
import '../screens/home_screen.dart';
import '../screens/skorlar_screen.dart';
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
///   /home/skorlar                      → SkorlarScreen (Sprint 11.0C)
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
        // Sprint 11.0C — the Sprint 10.2+ placeholder is
        // replaced by the real Skorlar screen. The new screen
        // hits `GET /api/v1/sessions?status=completed` and
        // renders the per-session score card list. The route
        // path is unchanged so the bottom-nav 3rd tab still
        // lands here.
        path: '/home/skorlar',
        builder: (context, state) => const SkorlarScreen(),
      ),
    ],
  );
}
