// mobile/lib/services/p2p_matcher.dart
//
// Sprint 10.1B + 10.1D — peer-to-peer matcher via JWT-auth
// `GET <apiBase>/api/v1/matches?sessionId=...`.
//
// What this is
// ------------
// Polls the matcher endpoint on a 5-second cadence. The
// endpoint returns either:
//   - 200 + {"peerSessionId": "...", "transport": "rcs|whatsapp"}
//     when a peer is waiting for us, OR
//   - 204 No Content when no peer is available yet.
//
// Sprint 10.1D — JWT auth flow
// ----------------------------
// The 10.1B implementation sent `Authorization: Bearer <api_key>`
// as a static literal. 10.1D replaces that with a real
// `POST /api/v1/auth` exchange (see `auth_service.dart`) that
// yields a short-lived JWT. `authHeaders()` returns
// `{"Authorization": "Bearer <jwt>", "X-API-Version": "v1"}`.
//
// Path note (Sprint 10.1D)
// ------------------------
// 10.1B: `https://api-test.opene2ee.com/matches`
// 10.1D: `https://api-test.opene2ee.com/api/v1/matches`
// The brief corrected the path to include the `/api/v1/`
// prefix mandated by the backend ADV-3 stub.
//
// Privacy
// -------
// We send our own `sessionId` (a per-process random string
// from `TelemetryService._generateSessionId`) — not the
// device installation id, not the IMEI/MSISDN, and not the
// masked IP. The peer's session id is the only thing the
// matcher returns.
//
// Error handling
// --------------
// 200 -> parse body, return [MatchResult].
// 204 -> no peer -> return `null`.
// 401 / 403 -> invalidate cached JWT, return `null`. The pool
//   provider's lastError surfaces the failure; the next tick
//   re-auths automatically.
// 5xx / network error -> throw; pool provider logs + retries
//   on the next tick.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'auth_service.dart';

class MatchResult {
  MatchResult({required this.peerSessionId, required this.transport});
  final String peerSessionId;
  final String transport; // "rcs" or "whatsapp"
  Map<String, Object?> toJson() => {
        'peerSessionId': peerSessionId,
        'transport': transport,
      };
}

class P2PMatcher {
  P2PMatcher({
    Uri? endpoint,
    String? apiKey,
    AuthService? auth,
    http.Client? client,
    Duration timeout = const Duration(seconds: 5),
  })  : _endpoint = endpoint ??
            // Sprint 10.1D — `/api/v1/matches` path.
            Uri.parse('${AppConfig.apiBase}/api/v1/matches'),
        _apiKey = apiKey ?? kApiKey,
        _auth = auth ?? AuthService(),
        _client = client ?? http.Client(),
        _timeout = timeout;

  final Uri _endpoint;
  // Retained for 10.1B backwards-compat — the 10.1D
  // primary path uses _auth.authHeaders(). NOT removed so
  // a test that constructs P2PMatcher without an
  // AuthService can still send a request.
  final String _apiKey;
  final AuthService _auth;
  final http.Client _client;
  final Duration _timeout;

  /// One-shot poll. Returns:
  ///   - a [MatchResult] when a peer is available,
  ///   - `null` on 204 (no peer yet) OR 401 (auth flushed),
  ///   - throws on any other status / transport error.
  Future<MatchResult?> findMatch(String sessionId) async {
    final uri = _endpoint.replace(queryParameters: {
      'sessionId': sessionId,
    });
    try {
      // Sprint 10.1D — pull a JWT via auth_service, then
      // GET. The `authHeaders()` call also re-auths if the
      // cached token is near expiry.
      final headers = await _auth.authHeaders();
      headers['Accept'] = 'application/json';
      final resp = await _client
          .get(
            uri,
            headers: headers,
          )
          .timeout(_timeout);
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, Object?>;
        final peer = body['peerSessionId'];
        final transport = body['transport'];
        if (peer is! String || peer.isEmpty) {
          throw const FormatException('peerSessionId missing or empty');
        }
        if (transport is! String || transport.isEmpty) {
          throw const FormatException('transport missing or empty');
        }
        return MatchResult(peerSessionId: peer, transport: transport);
      }
      if (resp.statusCode == 204) return null;
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        // Flush the cached JWT — next call will re-auth.
        // Return null (not throw) so the pool provider
        // treats this as "no peer" and retries on the
        // next tick with a fresh JWT.
        _auth.invalidate();
        return null;
      }
      throw http.ClientException(
        'unexpected status ${resp.statusCode}',
        uri,
      );
    } on TimeoutException {
      rethrow;
    } catch (e) {
      if (e is http.ClientException) rethrow;
      throw http.ClientException('transport error: $e', uri);
    }
  }

  void close() => _client.close();
}
