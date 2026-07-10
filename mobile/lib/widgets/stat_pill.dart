import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A pill used in the "Test Edilenler" stat card on the Aktif Nöbet
/// screen. Two variants are supported by `colorKey`:
///   - `accent`    : RCS pill (orange)
///   - `whatsapp`  : WhatsApp pill (green)
class StatPill extends StatelessWidget {
  const StatPill({
    super.key,
    required this.label,
    required this.colorKey,
  });

  final String label;
  final StatPillColor colorKey;

  @override
  Widget build(BuildContext context) {
    final fg = colorKey == StatPillColor.accent
        ? AppTheme.accent
        : AppTheme.whatsapp;
    final bg = colorKey == StatPillColor.accent
        ? const Color(0x15C97B3F)
        : const Color(0x1525D366);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check, size: 11, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

enum StatPillColor { accent, whatsapp }
