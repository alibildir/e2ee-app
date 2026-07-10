import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';

/// A single "Görevler" card on the home screen.
///
/// Sprint 10.0 — only 2 tasks: RCS Mesajları and WhatsApp. GSM operator
/// cards (Turkcell / Vodafone / Türk Telekom) are intentionally removed
/// from this design — see `docs/SPRINT-10-SCOPE.md`.
class Task {
  const Task({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.iconColor,
    required this.iconBackground,
    required this.durationLabel,
    required this.actionLabel,
  });

  final String id;
  final String title;
  final String description;
  final IconData icon;
  final Color iconColor;
  final Color iconBackground;
  final String durationLabel;
  final String actionLabel;
}

/// Mock task list — Sprint 10.0 has only RCS and WhatsApp tasks. The
/// data is static; in 10.1+ this is replaced with a backend-backed
/// provider that reads from the device-aggregator endpoint.
final tasksListProvider = Provider<List<Task>>((ref) => const [
      Task(
        id: 'rcs',
        title: 'RCS Mesajları',
        description:
            'RCS üzerinden gönderilen mesajların şifreleme bütünlüğünü test et',
        icon: Icons.chat_bubble_outline,
        iconColor: AppTheme.accent,
        iconBackground: Color(0x15C97B3F),
        durationLabel: '~2 dk',
        actionLabel: 'Başla',
      ),
      Task(
        id: 'whatsapp',
        title: 'WhatsApp',
        description:
            "WhatsApp üzerinden hazır mesaj gönder, şifreleme bütünlüğünü kanıtla",
        icon: Icons.chat,
        iconColor: AppTheme.whatsapp,
        iconBackground: Color(0x1525D366),
        durationLabel: '~1 dk',
        actionLabel: 'Başla',
      ),
    ]);
