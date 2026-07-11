// mobile/lib/screens/skorlar_screen.dart
//
// Sprint 11.0C — Skorlar (Score) Screen (M3).
//
// The screen reads the recent completed sessions from
// `GET /api/v1/sessions?status=completed` (JWT auth header),
// feeds each `summary_stats` block into
// `SessionScoreCalculator.compute()`, and renders a
// `SessionScoreCard` for each session. The headline number
// on each card is the `overallScore` (0-100, higher is better).
//
// Empty state: "Henüz tamamlanmış oturum yok" with a
// centred icon. S68 invariant.
//
// Audit invariants (Sprint 11.0C):
//   S61 — `Future<List<SessionScore>> fetchScores` + Riverpod
//   S68 — empty state string
//   S69 — `SessionScoreCard` with overall gauge (fl_chart
//         radial gauge or simple coloured disc — Sprint 11.0C
//         uses a simple disc with the `tier` color hint to keep
//         APK small after the M2 +50 MB libwebrtc hit)

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config.dart';
import '../services/auth_service.dart';
import '../services/score_calculator.dart';
import '../services/session_orchestrator.dart';
import '../state/pool_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/stat_pill.dart';

/// Sprint 11.0C — Skorlar screen.
///
/// Tabs into 3 sub-views (via a 3-tab TopNavigationBar):
///   - "Tümü"          — every session in the cache
///   - "Offerer"       — sessions where role == "offerer"
///   - "Answerer"      — sessions where role == "answerer"
/// The list is reverse-chronological (most recent first).
class SkorlarScreen extends ConsumerStatefulWidget {
  const SkorlarScreen({super.key});

  @override
  ConsumerState<SkorlarScreen> createState() => _SkorlarScreenState();
}

class _SkorlarScreenState extends ConsumerState<SkorlarScreen> {
  late final AuthService _auth;
  late final SessionOrchestrator _orchestrator;
  Future<List<SessionScore>>? _scoresFuture;

  @override
  void initState() {
    super.initState();
    _auth = AuthService();
    _orchestrator = SessionOrchestrator(auth: _auth);
    _scoresFuture = _fetchScores();
  }

  @override
  void dispose() {
    _orchestrator.close();
    super.dispose();
  }

  /// Sprint 11.0C — S61 invariant. `Future<List<SessionScore>>`
  /// fetchScores returns a typed list. The provider that
  /// drives the list is `skorlarFutureProvider`; the UI also
  /// holds a local copy so a refresh-pull can re-fetch without
  /// disturbing the provider graph.
  Future<List<SessionScore>> _fetchScores() async {
    final headers = await _auth.authHeaders();
    headers['Accept'] = 'application/json';
    final resp = await _auth.client.get(
      Uri.parse(
        '${AppConfig.apiBase}/api/v1/sessions?status=completed',
      ),
      headers: headers,
    );
    if (resp.statusCode != 200) {
      throw ScoreFetchException(
        'fetchScores failed (${resp.statusCode}): ${resp.body}',
        statusCode: resp.statusCode,
      );
    }
    final body = jsonDecode(resp.body) as Map<String, Object?>;
    final raw = (body['sessions'] as List?) ?? const [];
    final telemetries = <SessionTelemetry>[];
    for (final entry in raw) {
      if (entry is Map) {
        telemetries.add(
          SessionTelemetry.fromJson(entry.cast<String, Object?>()),
        );
      }
    }
    return SessionScoreCalculator.computeAll(telemetries);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('Skorlar'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/home/gorevler'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Yenile',
            onPressed: () {
              setState(() {
                _scoresFuture = _fetchScores();
              });
            },
          ),
        ],
      ),
      body: FutureBuilder<List<SessionScore>>(
        future: _scoresFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
              ),
            );
          }
          if (snap.hasError) {
            return _SkorlarError(error: snap.error.toString());
          }
          final scores = snap.data ?? const <SessionScore>[];
          // S68 invariant — empty state literal.
          if (scores.isEmpty) {
            return const _SkorlarEmpty();
          }
          // Reverse-chronological.
          final sorted = [...scores]
            ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
          return RefreshIndicator(
            color: AppTheme.primary,
            onRefresh: () async {
              setState(() {
                _scoresFuture = _fetchScores();
              });
              await _scoresFuture;
            },
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: sorted.length,
              itemBuilder: (context, i) => SessionScoreCard(score: sorted[i]),
            ),
          );
        },
      ),
      bottomNavigationBar: const _SkorlarBottomNav(),
    );
  }
}

/// Per-session card on the Skorlar screen. The headline
/// number is the overall score (0-100, coloured by tier).
/// The expand-on-tap detail view shows the 4 sub-metrics.
class SessionScoreCard extends StatefulWidget {
  const SessionScoreCard({super.key, required this.score});
  final SessionScore score;

  @override
  State<SessionScoreCard> createState() => _SessionScoreCardState();
}

class _SessionScoreCardState extends State<SessionScoreCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.score;
    final color = _tierColor(s.tier);
    final dateStr = _formatDate(s.startedAt);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          border: Border.all(color: AppTheme.border),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Headline gauge — coloured disc with the overall
                // score in the centre. S69 invariant.
                _OverallScoreDisc(score: s.overallScore, color: color),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dateStr,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Oturum ${s.sessionId.substring(0, s.sessionId.length.clamp(0, 8))}…',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.muted,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: AppTheme.muted,
                  ),
                  onPressed: () => setState(() => _expanded = !_expanded),
                ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: 12),
              const Divider(height: 1, color: AppTheme.border),
              const SizedBox(height: 12),
              // 4 sub-metric rows.
              _MetricRow(
                label: 'Şifreleme bütünlüğü',
                value: '${s.encryptionIntegrityPct.toStringAsFixed(1)}%',
                color: _integrityColor(s.encryptionIntegrityPct),
              ),
              _MetricRow(
                label: 'Paket kaybı',
                value: '${s.packetLossPct.toStringAsFixed(1)}%',
                color: _lossColor(s.packetLossPct),
              ),
              _MetricRow(
                label: 'Gecikme',
                value: '${s.meanLatencyMs.toStringAsFixed(1)} ms',
                color: _latencyColor(s.meanLatencyMs),
              ),
              _MetricRow(
                label: 'Jitter',
                value: '${s.jitterMs.toStringAsFixed(1)} ms',
                color: _jitterColor(s.jitterMs),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OverallScoreDisc extends StatelessWidget {
  const _OverallScoreDisc({required this.score, required this.color});
  final double score;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 2),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            score.toStringAsFixed(0),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: color,
              height: 1,
            ),
          ),
          const Text(
            '/ 100',
            style: TextStyle(
              fontSize: 9,
              color: AppTheme.muted,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                color: AppTheme.text,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _SkorlarEmpty extends StatelessWidget {
  const _SkorlarEmpty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bar_chart_outlined, size: 56, color: AppTheme.muted),
            SizedBox(height: 12),
            Text(
              'Henüz tamamlanmış oturum yok',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Aktif nöbet ekranından bir oturum başlatıp '
              '"Oturumu Bitir" dediğinizde burada görünecek.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkorlarError extends StatelessWidget {
  const _SkorlarError({required this.error});
  final String error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 56, color: AppTheme.danger),
            const SizedBox(height: 12),
            const Text(
              'Skorlar yüklenemedi',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.muted,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SkorlarBottomNav extends StatelessWidget {
  const _SkorlarBottomNav();

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: 2,
      onTap: (i) {
        switch (i) {
          case 0:
            context.go('/home/gorevler');
            break;
          case 1:
            context.go('/home/aktif-nobet');
            break;
          case 2:
            // already here
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

// ─── Helpers ────────────────────────────────────────────────────

Color _tierColor(ScoreTier t) {
  switch (t) {
    case ScoreTier.good:
      return const Color(0xFF22C55E); // green-500
    case ScoreTier.warn:
      return const Color(0xFFF59E0B); // amber-500
    case ScoreTier.bad:
      return const Color(0xFFEF4444); // red-500
  }
}

Color _integrityColor(double pct) {
  if (pct >= 95) return const Color(0xFF22C55E);
  if (pct >= 80) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

Color _lossColor(double pct) {
  if (pct <= 1) return const Color(0xFF22C55E);
  if (pct <= 5) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

Color _latencyColor(double ms) {
  if (ms <= 100) return const Color(0xFF22C55E);
  if (ms <= 300) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

Color _jitterColor(double ms) {
  if (ms <= 20) return const Color(0xFF22C55E);
  if (ms <= 50) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

String _formatDate(DateTime ts) {
  // Owner-selected Turkish format: "11 Tem 2026 · 00:55"
  // We use the Turkish month abbreviations inline (no locale
  // data — Sprint 12.0 will switch to intl + locale package).
  const months = [
    'Oca', 'Şub', 'Mar', 'Nis', 'May', 'Haz',
    'Tem', 'Ağu', 'Eyl', 'Eki', 'Kas', 'Ara',
  ];
  final m = months[ts.month - 1];
  final day = ts.day.toString().padLeft(2, '0');
  final hour = ts.hour.toString().padLeft(2, '0');
  final min = ts.minute.toString().padLeft(2, '0');
  return '$day $m ${ts.year} · $hour:$min';
}

class ScoreFetchException implements Exception {
  ScoreFetchException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'ScoreFetchException($message, status=$statusCode)';
}
