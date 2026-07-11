// mobile/lib/services/score_calculator.dart
//
// Sprint 11.0C — Score Calculator (M3).
//
// Pure-Dart scoring engine for OpenE2EE session aggregates.
// The Skorlar screen reads the recent completed sessions
// from the backend's `GET /api/v1/sessions?status=completed`
// endpoint and feeds each session's `summary_stats` block
// into `SessionScoreCalculator.compute(...)`. The result is
// the per-session score the UI shows in the ListView
// (`SessionScoreCard`).
//
// Audit invariants (Sprint 11.0C):
//   S62 — `compute()` pure function (no I/O, no time-source
//         injection, no logging — easy to unit test)
//   S63 — 4 metric formulas (encryption/loss/latency/jitter)
//   S64 — overall weighted sum (0.4 + 0.3 + 0.2 + 0.1)
//
// Privacy
// -------
// The calculator reads the backend's `summary_stats` block:
//   {
//     totalPackets, encryptedPackets, packetLossPct,
//     meanLatencyMs, jitterMs, encryptionIntegrityPct,
//     capturedAt
//   }
// We never read raw packet bytes; the IP-masking invariant
// (ADR-0006 /24 for IPv4, /48 for IPv6) is enforced on the
// Samping side, not here.

import 'dart:math' as math;

/// SessionTelemetry is the input to [SessionScoreCalculator.compute].
/// All fields are nullable for the "session in progress" case
/// (the Skorlar screen surfaces a placeholder card for those).
class SessionTelemetry {
  const SessionTelemetry({
    required this.sessionId,
    required this.role,
    required this.startedAt,
    this.endedAt,
    this.totalPackets = 0,
    this.encryptedPackets = 0,
    this.packetLossPct = 0.0,
    this.meanLatencyMs = 0.0,
    this.jitterMs = 0.0,
    this.encryptionIntegrityPct = 100.0,
  });

  /// Server-minted session id.
  final String sessionId;

  /// "offerer" or "answerer" — surfaces in the UI card so the
  /// user knows which side they were on.
  final String role;

  /// Wall-clock start time.
  final DateTime startedAt;

  /// Wall-clock end time. `null` if the session is still in
  /// progress (the Skorlar screen shows a "(devam ediyor)"
  /// placeholder).
  final DateTime? endedAt;

  /// Total packets observed in the session.
  final int totalPackets;

  /// Packets whose encryption header (parsed by `PacketParser`)
  /// was valid. Computed by the backend in `summary_stats`.
  final int encryptedPackets;

  /// `(expected - received) / expected` * 100, clamped to [0, 100].
  /// From the backend's `summary_stats.packet_loss_pct`.
  final double packetLossPct;

  /// Mean inter-packet arrival time delta (ms).
  final double meanLatencyMs;

  /// Standard deviation of the inter-packet delta (ms).
  final double jitterMs;

  /// `(encryptedPackets / totalPackets) * 100` rounded to 1
  /// decimal. From `summary_stats.encryption_integrity_pct`.
  final double encryptionIntegrityPct;

  Map<String, Object?> toJson() => {
        'session_id': sessionId,
        'role': role,
        'started_at': startedAt.toUtc().toIso8601String(),
        'ended_at': endedAt?.toUtc().toIso8601String(),
        'total_packets': totalPackets,
        'encrypted_packets': encryptedPackets,
        'packet_loss_pct': packetLossPct,
        'mean_latency_ms': meanLatencyMs,
        'jitter_ms': jitterMs,
        'encryption_integrity_pct': encryptionIntegrityPct,
      };

  /// Convenience: construct from the wire shape the backend
  /// returns. Tolerates missing optional fields (defensive —
  /// older server builds may not include every aggregate).
  factory SessionTelemetry.fromJson(Map<String, Object?> m) {
    return SessionTelemetry(
      sessionId: (m['session_id'] as String?) ?? '',
      role: (m['role'] as String?) ?? 'offerer',
      startedAt: DateTime.tryParse((m['started_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
      endedAt: m['ended_at'] == null
          ? null
          : DateTime.tryParse(m['ended_at'] as String),
      totalPackets: (m['total_packets'] as int?) ?? 0,
      encryptedPackets: (m['encrypted_packets'] as int?) ?? 0,
      packetLossPct: (m['packet_loss_pct'] as num?)?.toDouble() ?? 0.0,
      meanLatencyMs: (m['mean_latency_ms'] as num?)?.toDouble() ?? 0.0,
      jitterMs: (m['jitter_ms'] as num?)?.toDouble() ?? 0.0,
      encryptionIntegrityPct:
          (m['encryption_integrity_pct'] as num?)?.toDouble() ?? 100.0,
    );
  }
}

/// SessionScore is the output of [SessionScoreCalculator.compute].
/// The `overallScore` is the headline metric (0-100, higher is
/// better); the four per-metric `*Pct` fields drive the details
/// view inside each `SessionScoreCard`.
class SessionScore {
  const SessionScore({
    required this.sessionId,
    required this.overallScore,
    required this.encryptionIntegrityPct,
    required this.packetLossPct,
    required this.meanLatencyMs,
    required this.jitterMs,
    required this.startedAt,
    this.endedAt,
  });

  final String sessionId;

  /// 0-100. Higher is better. The UI renders this as the
  /// headline number on the session card.
  final double overallScore;

  final double encryptionIntegrityPct;
  final double packetLossPct;
  final double meanLatencyMs;
  final double jitterMs;
  final DateTime startedAt;
  final DateTime? endedAt;

  /// Turkish color hint for the headline score (the UI uses
  /// this to pick green/amber/red without re-deriving the
  /// threshold).
  ScoreTier get tier {
    if (overallScore >= 80) return ScoreTier.good;
    if (overallScore >= 50) return ScoreTier.warn;
    return ScoreTier.bad;
  }
}

enum ScoreTier { good, warn, bad }

/// Pure scoring function. Returns a [SessionScore] for the
/// given [SessionTelemetry] aggregate. The formula:
///
///   overall = clamp(
///     0.4 * integrity
///     + 0.3 * (1 - loss/100)
///     + 0.2 * (1 - latency/1000)
///     + 0.1 * (1 - jitter/100),
///     0, 1) * 100
///
/// The 4 weights (0.4, 0.3, 0.2, 0.1) sum to 1.0. integrity is
/// already a 0-100 percentage; loss is also 0-100; latency is
/// clamped to 1000ms (anything slower saturates the
/// contribution); jitter is clamped to 100ms. The result is
/// rounded to 1 decimal place.
class SessionScoreCalculator {
  const SessionScoreCalculator._();

  /// Compute the [SessionScore] for the given telemetry.
  /// Pure function — no I/O, no time source injection, easy
  /// to unit test.
  static SessionScore compute(SessionTelemetry t) {
    // Per-metric contributions, normalised to [0, 1].
    final integrity = (t.encryptionIntegrityPct / 100.0).clamp(0.0, 1.0);
    final loss = (t.packetLossPct / 100.0).clamp(0.0, 1.0);
    // Latency: 0ms → 1.0; 1000ms+ → 0.0; linear in between.
    final latency = (1.0 - (t.meanLatencyMs / 1000.0)).clamp(0.0, 1.0);
    // Jitter: 0ms → 1.0; 100ms+ → 0.0; linear in between.
    final jitter = (1.0 - (t.jitterMs / 100.0)).clamp(0.0, 1.0);

    // Weighted sum.
    final raw = 0.4 * integrity +
        0.3 * (1.0 - loss) +
        0.2 * latency +
        0.1 * jitter;
    final overall = (raw.clamp(0.0, 1.0) * 100.0 * 10).round() / 10.0;

    return SessionScore(
      sessionId: t.sessionId,
      overallScore: overall,
      encryptionIntegrityPct: t.encryptionIntegrityPct,
      packetLossPct: t.packetLossPct,
      meanLatencyMs: t.meanLatencyMs,
      jitterMs: t.jitterMs,
      startedAt: t.startedAt,
      endedAt: t.endedAt,
    );
  }

  /// Compute a list of scores for a batch of telemetries.
  /// Convenience for the Skorlar screen — single-call
  /// alternative to mapping `compute` over the list.
  static List<SessionScore> computeAll(Iterable<SessionTelemetry> telemetries) {
    final out = <SessionScore>[];
    for (final t in telemetries) {
      out.add(compute(t));
    }
    return out;
  }
}

/// Compute the standard deviation of a list of doubles.
/// Used by tests to verify the 4 metric formulas end-to-end.
/// Not used by the calculator itself — the metrics are
/// pre-aggregated by the backend's `summary_stats` block.
double standardDeviation(List<double> values) {
  if (values.isEmpty) return 0.0;
  final mean = values.reduce((a, b) => a + b) / values.length;
  final variance = values
          .map((v) => (v - mean) * (v - mean))
          .reduce((a, b) => a + b) /
      values.length;
  return math.sqrt(variance);
}
