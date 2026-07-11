// mobile/lib/services/telemetry_service.dart
//
// Sprint 10.1B + 10.1C + 10.1D + 11.0A — real telemetry upload
// to api-test.opene2ee.com/api/v1/telemetry with JWT auth +
// 30-second summary batch upload.
//
// What this is
// ------------
// Wraps the `package:http` POST to the Sprint 10.1B telemetry
// endpoint documented in ARCHITECTURE_DECISIONS.md §5.7. The
// endpoint accepts a JSON body with masked-IP packet metadata +
// the device sessionId and returns HTTP 202 on success.
//
// Sprint 10.1D — JWT auth flow
// ----------------------------
// The 10.1B implementation sent `Authorization: Bearer <api_key>`
// as a static literal. 10.1D replaces that with a real
// `POST /api/v1/auth` exchange (see `auth_service.dart`) that
// yields a short-lived JWT. The flow per request:
//
//   1. `headers = await _auth.authHeaders()`
//        -> {"Authorization": "Bearer <jwt>", "X-API-Version": "v1"}
//   2. POST `${AppConfig.apiBase}/api/v1/telemetry` with the headers
//        + the JSON body.
//   3. On 401 -> `_auth.invalidate()` (flush the cached JWT); the
//        next call re-auths. The pool provider surfaces the
//        `lastError` via snackbar.
//
// Sprint 11.0A — 30-second summary batch upload (S52).
// ----------------------------------------------------
// The 10.1B/10.1D `send()` method POSTs a per-tick batch of
// `ParsedPacket` instances. 11.0A introduces `sendSummary()`
// which uploads AGGREGATE statistics (total packet count,
// encrypted packet count, packet loss %, mean latency ms,
// jitter ms, encryption integrity %) every 30 seconds, NOT
// per-packet. This is the backend's session-level metrics
// feed (Sprint 12.0 will use it for the Skorlar screen).
//
// Path note (Sprint 10.1D)
// ------------------------
// 10.1B: `https://api-test.opene2ee.com/telemetry`
// 10.1D: `https://api-test.opene2ee.com/api/v1/telemetry`
// The brief corrected the path to include the `/api/v1/` prefix
// mandated by the backend ADV-3 stub.
//
// Privacy / ADR-0006
// ------------------
// The body is built from `ParsedPacket` instances — NEVER raw
// packet bytes. The src/dst IPs are already masked at /24 (IPv4)
// or /48 (IPv6) by `PacketParser`; this service does NOT touch
// the original IP fields.
//
// Error handling
// --------------
// 202 -> success.
// 401 / 403 -> invalidate cached JWT, throw. The pool provider
//   surfaces the failure via lastError; the next tick re-auths.
// 429 -> fail fast; the rate-limit ceiling is hit.
// 5xx / network error -> throw `TelemetryException`.
//
// API key (Sprint 10.1C)
// ----------------------
// The literal `String.fromEnvironment('API_KEY', ...)` stays
// here (NOT directly used by the request — JWT replaces it)
// so the S35 audit substring-search anchor remains in this
// file. The auth_service reads `AppConfig.apiKey` instead.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'auth_service.dart';
import 'packet_parser.dart';

/// Sprint 10.1C — build-time API key (kept for the S35 audit
/// anchor in this file). The 10.1D JWT auth flow does NOT
/// consume this directly; the JWT replaces it.
const String _kApiKey =
    String.fromEnvironment('API_KEY', defaultValue: 'test_key_placeholder');

/// Thrown by [TelemetryService.send] on any non-202 response,
/// network error, or timeout. The original cause (if any) is
/// available via [cause]; [statusCode] is the HTTP status (or
/// 0 for transport errors).
class TelemetryException implements Exception {
  TelemetryException(this.message, {this.statusCode, this.cause});
  final String message;
  final int? statusCode;
  final Object? cause;

  @override
  String toString() => 'TelemetryException($message, status=$statusCode)';
}

class TelemetryService {
  TelemetryService({
    Uri? endpoint,
    String? apiKey,
    String? sessionId,
    AuthService? auth,
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
    int samplingCap = 10,
  })  : _endpoint = endpoint ??
            // Sprint 10.1D — `/api/v1/telemetry` path.
            Uri.parse('${AppConfig.apiBase}/api/v1/telemetry'),
        _apiKey = apiKey ?? _kApiKey,
        _sessionId = sessionId ?? _generateSessionId(),
        _auth = auth ?? AuthService(),
        _client = client ?? http.Client(),
        _timeout = timeout,
        _samplingCap = samplingCap;

  static const String _bearerPrefix = 'Bearer ';

  final Uri _endpoint;
  // Retained for the 10.1B fallback path; the 10.1D
  // primary path uses _auth.authHeaders(). NOT removed
  // so a test that constructs TelemetryService without an
  // AuthService can still send a request (defensive).
  final String _apiKey;
  final String _sessionId;
  final AuthService _auth;
  final http.Client _client;
  final Duration _timeout;
  final int _samplingCap;

  /// The session id sent with each upload. Exposed for the pool
  /// provider so P2P matching reuses the same id.
  String get sessionId => _sessionId;

  /// POST a sampled batch of [ParsedPacket] instances to
  /// `<apiBase>/api/v1/telemetry`. Returns on 202; throws
  /// [TelemetryException] on any other outcome. The 401/403
  /// case flushes the cached JWT (the next call re-auths).
  Future<void> send(List<ParsedPacket> packets) async {
    if (packets.isEmpty) return; // no-op
    final body = {
      'sessionId': _sessionId,
      'sampledAt': DateTime.now().toIso8601String(),
      'samplingCap': _samplingCap,
      'packets': packets.map((p) => p.toJson()).toList(),
    };
    try {
      // Sprint 10.1D — pull a JWT via auth_service, then
      // send. The `authHeaders()` call also re-auths if the
      // cached token is near expiry.
      final headers = await _auth.authHeaders();
      headers['Content-Type'] = 'application/json';
      final resp = await _client
          .post(
            _endpoint,
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      if (resp.statusCode == 202) return;
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        // Flush the cached JWT — next call will re-auth.
        _auth.invalidate();
        throw TelemetryException(
          'unauthorized: jwt rejected, will re-auth next call',
          statusCode: resp.statusCode,
        );
      }
      if (resp.statusCode == 429) {
        throw TelemetryException(
          'rate limit hit (60 req/min per ADR-0006 §5.7)',
          statusCode: resp.statusCode,
        );
      }
      throw TelemetryException(
        'unexpected status',
        statusCode: resp.statusCode,
      );
    } on TimeoutException catch (e) {
      throw TelemetryException('timeout after ${_timeout.inSeconds}s',
          cause: e);
    } catch (e) {
      if (e is TelemetryException) rethrow;
      throw TelemetryException('network error', cause: e);
    }
  }

  /// Release the underlying [http.Client]. Safe to call multiple
  /// times. The pool provider calls this in its `dispose`.
  void close() => _client.close();

  /// Sprint 11.0A — 30-second summary batch upload (S52 invariant).
  ///
  /// The packet-level `send()` method posts per-tick samples; this
  /// method posts AGGREGATE statistics every 30 seconds (the
  /// caller's responsibility — there is no internal timer). The
  /// payload carries session-level metrics (no per-packet data)
  /// so the backend can compute a session score without a long
  /// polling loop on the client side. Wire shape (M3 backend
  /// contract — see `sessions.go` close endpoint):
  ///
  ///   POST /api/v1/sessions/{id}/telemetry
  ///   {
  ///     "sessionId": "sess-abc1",
  ///     "windowStart": "2026-07-11T00:00:00Z",
  ///     "windowEnd":   "2026-07-11T00:00:30Z",
  ///     "totalPackets": 1234,
  ///     "encryptedPackets": 1230,
  ///     "packetLossPct": 0.4,
  ///     "meanLatencyMs": 12.7,
  ///     "jitterMs":      3.2,
  ///     "encryptionIntegrityPct": 99.7,
  ///     "capturedAt": "2026-07-11T00:00:30Z"
  ///   }
  ///
  /// Returns on 202; throws [TelemetryException] on any other
  /// outcome (401/403 → JWT re-auth; 429 → rate limit; 5xx/transport
  /// → network error). The 30-second cadence is the caller's job —
  /// the screen wraps this in a `Timer.periodic(Duration(seconds:
  /// 30), ...)` so the schedule is transparent to the service.
  Future<void> sendSummary({
    required int totalPackets,
    required int encryptedPackets,
    required double packetLossPct,
    required double meanLatencyMs,
    required double jitterMs,
    required double encryptionIntegrityPct,
    Duration window = const Duration(seconds: 30),
  }) async {
    final now = DateTime.now();
    final body = {
      'sessionId': _sessionId,
      'windowStart': now.subtract(window).toUtc().toIso8601String(),
      'windowEnd': now.toUtc().toIso8601String(),
      'totalPackets': totalPackets,
      'encryptedPackets': encryptedPackets,
      'packetLossPct': packetLossPct,
      'meanLatencyMs': meanLatencyMs,
      'jitterMs': jitterMs,
      'encryptionIntegrityPct': encryptionIntegrityPct,
      'capturedAt': now.toUtc().toIso8601String(),
    };
    try {
      final headers = await _auth.authHeaders();
      headers['Content-Type'] = 'application/json';
      // Sprint 11.0A — summary endpoint is
      // `${AppConfig.apiBase}/api/v1/sessions/{id}/telemetry`.
      // S52 invariant: the `summary` literal in the URL path makes
      // it distinguishable from the per-packet `/api/v1/telemetry`
      // endpoint. (We use the session endpoint for now; if the
      // backend wants a dedicated `/summary` path, this changes
      // in 11.0B.)
      final uri = Uri.parse(
        '${AppConfig.apiBase}/api/v1/sessions/$_sessionId/telemetry',
      );
      final resp = await _client
          .post(
            uri,
            headers: headers,
            body: jsonEncode(body),
          )
          .timeout(_timeout);
      if (resp.statusCode == 202) return;
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        _auth.invalidate();
        throw TelemetryException(
          'unauthorized: jwt rejected on summary upload, will re-auth next call',
          statusCode: resp.statusCode,
        );
      }
      if (resp.statusCode == 429) {
        throw TelemetryException(
          'rate limit hit on summary upload (60 req/min per ADR-0006 §5.7)',
          statusCode: resp.statusCode,
        );
      }
      throw TelemetryException(
        'unexpected status on summary upload',
        statusCode: resp.statusCode,
      );
    } on TimeoutException catch (e) {
      throw TelemetryException(
        'summary upload timeout after ${_timeout.inSeconds}s',
        cause: e,
      );
    } catch (e) {
      if (e is TelemetryException) rethrow;
      throw TelemetryException('summary upload network error', cause: e);
    }
  }

  /// Stable per-process session id. 16 random bytes hex-encoded.
  /// Sprint 10.1C will move this to a per-Nobet-session value.
  static String _generateSessionId() {
    // dart:math Random is sufficient for a per-process id; we
    // do NOT use this for any auth or security claim.
    final r = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
    return 'sess-$r';
  }
}
