import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/pool_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/stat_pill.dart';

/// Sprint 10.0 — Aktif Nöbet (Active Pool) screen.
///
/// Orange hero ("Aktif Nöbet Modu") + "Alıcı Ol" toggle card +
/// 3-stat grid (İzlenen Paket / Bağlı Gönüllü / Test Edilenler).
/// The toggle is local UI state only — toggling does NOT change the
/// mock numbers. Bottom nav highlights the "Aktif Nöbet" tab.
///
/// S25 invariant: no "v-p-n" framing in the UI. See
/// `sprint10-wireframes.html` frame 4.
class ActivePoolScreen extends ConsumerWidget {
  const ActivePoolScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pool = ref.watch(poolProvider);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('Aktif Nöbet'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/home/gorevler'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          // Orange hero.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [AppTheme.accent, AppTheme.accentDark],
              ),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Aktif Nöbet Modu',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Gönüllü olarak test havuzunda bekle',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          // Toggle card.
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                border: Border.all(color: AppTheme.border),
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 20,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'Alıcı Ol',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.text,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Havuzda 15 dk bekle',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: pool.isAlici,
                    onChanged: (_) =>
                        ref.read(poolProvider.notifier).toggleAlici(),
                    activeThumbColor: Colors.white,
                    activeTrackColor: AppTheme.primary,
                  ),
                ],
              ),
            ),
          ),
          // 3-stat grid (2 + 1 full-width).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        label: 'İzlenen Paket',
                        value: pool.paketSayisi.toString(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        label: 'Bağlı Gönüllü',
                        value: pool.gonulluSayisi.toString(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _TestEdilenlerCard(
                  available: pool.testEdilenler,
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: const _PoolBottomNav(),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.muted,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: AppTheme.primary,
              fontFamily: 'monospace',
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _TestEdilenlerCard extends StatelessWidget {
  const _TestEdilenlerCard({required this.available});

  final Set<String> available;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TEST EDİLENLER',
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.muted,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (available.contains('rcs'))
                const StatPill(
                  label: 'RCS',
                  colorKey: StatPillColor.accent,
                ),
              if (available.contains('whatsapp'))
                const StatPill(
                  label: 'WhatsApp',
                  colorKey: StatPillColor.whatsapp,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PoolBottomNav extends StatelessWidget {
  const _PoolBottomNav();

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: 1,
      onTap: (i) {
        switch (i) {
          case 0:
            context.go('/home/gorevler');
            break;
          case 1:
            // already here
            break;
          case 2:
            context.go('/home/skorlar');
            break;
        }
      },
      items: const [
        BottomNavigationBarItem(
          icon: Icon(Icons.task_alt_outlined),
          activeIcon: Icon(Icons.task_alt),
          label: 'Görevler',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.people_outline),
          activeIcon: Icon(Icons.people),
          label: 'Aktif Nöbet',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.bar_chart_outlined),
          activeIcon: Icon(Icons.bar_chart),
          label: 'Skorlar',
        ),
      ],
    );
  }
}
