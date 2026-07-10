import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/tasks_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/task_card.dart';

/// Sprint 10.0 — Home (Görevler) screen.
///
/// Two task cards (RCS + WhatsApp), a 3-tab bottom nav (Görevler /
/// Aktif Nöbet / Skorlar), and an orange FAB that jumps to
/// `/home/aktif-nobet` ("Alıcı Ol (Nöbet)").
///
/// S25 invariant: no "v-p-n" framing in the UI; the Ağ Güvenliği
/// Aracı copy replaces it. RCS start shows a snackbar (Sprint
/// 10.1+ wires the real connection); WhatsApp start navigates to
/// `/home/gorevler/whatsapp` (the deep-link screen).
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(tasksListProvider);
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: Row(
          children: const [
            Icon(Icons.shield_outlined, size: 22, color: AppTheme.primary),
            SizedBox(width: 8),
            Text('OpenE2EE'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () {
              // Placeholder — settings is out of scope for Sprint 10.0.
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'GÖREVLER',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.muted,
                letterSpacing: 0.8,
              ),
            ),
          ),
          for (final task in tasks) ...[
            TaskCard(
              task: task,
              onStart: () => _onTaskStart(context, task.id),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.accent,
        foregroundColor: Colors.white,
        onPressed: () => context.go('/home/aktif-nobet'),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Alıcı Ol (Nöbet)'),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: const _BottomNav(activeIndex: 0),
    );
  }

  void _onTaskStart(BuildContext context, String taskId) {
    switch (taskId) {
      case 'whatsapp':
        context.go('/home/gorevler/whatsapp');
        break;
      case 'rcs':
      default:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Sprint 10.0 mock — Sprint 10.1\'de gerçek bağlantı',
            ),
            duration: Duration(seconds: 3),
          ),
        );
        break;
    }
  }
}

class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.activeIndex});

  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: activeIndex,
      onTap: (i) {
        switch (i) {
          case 0:
            context.go('/home/gorevler');
            break;
          case 1:
            context.go('/home/aktif-nobet');
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
