// mobile/lib/services/session_orchestrator.dart
//
// Sprint 11.0B — Session Orchestrator (M2).
//
// The orchestrator drives the WebRTC P2P negotiation:
//   1. startSession()    — POST /api/v1/sessions → session_id +
//                          receiver_session_id
//   2. pollForOffer()    — GET /api/v1/webrtc/offer?session_id=...
//                          long-poll (30s timeout) until the
//                          peer posts an offer
//   3. negotiate()       — create local offer (or answer),
//                          POST, long-poll for the remote
//                          counterpart, setRemoteDescription
//   4. tearDown()        — close the peer connection +
//                          DELETE /api/v1/sessions/{id}
//
// Audit invariants (Sprint 11.0B):
//   S56 — `startSession()` method + JWT auth header (`_auth.authHeaders()`)
//   S57 — long-poll GET with 30s timeout
//   S58 — backend router.go has GET /api/v1/webrtc/{offer,answer}
//          long-poll handlers (production audit, this file
//          is the consumer — see backend/internal/api/router.go)
//
// Wire surface:
//   POST /api/v1/sessions                              → start
//   GET  /api/v1/webrtc/offer?session_id=...           → poll
//   GET  /api/v1/webrtc/answer?session_id=...          → poll
//   POST /api/v1/webrtc/offer                          → push
//   POST /api/v1/webrtc/answer                         → push
//   POST /api/v1/webrtc/ice                            → push
//   DELETE /api/v1/sessions/{id}                       → close

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'auth_service.dart';
import 'webrtc_service.dart';

class SessionOrchestrator {
  SessionOrchestrator({
    AuthService? auth,
    WebRTCService? webrtc,
    http.Client? client,
    Duration pollTimeout = const Duration(seconds: 30),
  })  : _auth = auth ?? AuthService(),
        _webrtc = webrtc ?? WebRTCService(),
        _client = client ?? http.Client(),
        _pollTimeout = pollTimeout;

  final AuthService _auth;
  final WebRTCService _webrtc;
  final http.Client _client;
  final Duration _pollTimeout;

  /// The session id returned by `startSession()`. Other methods
  /// read this; the orchestrator owns the lifecycle.
  String? _sessionId;

  /// The peer's session id (the receiver half of the pair).
  /// Returned by the backend when a match is found; the
  /// orchestrator fans ICE candidates to it.
  String? _receiverSessionId;

  /// SDP offer received from the peer (if we're the answerer).
  /// Populated by `pollForOffer` / `negotiate`; cleared on
  /// `tearDown`.
  Map<String, Object?>? _remoteOffer;

  /// SDP answer received from the peer (if we're the offerer).
  Map<String, Object?>? _remoteAnswer;

  /// Tear-down flag. Set by [tearDown] to short-circuit any
  /// in-flight long-poll + createOffer paths.
  bool _tornDown = false;

  String? get sessionId => _sessionId;
  String? get receiverSessionId => _receiverSessionId;
  WebRTCService get webrtc => _webrtc;
  WebRTCState get webrtcState => _webrtc.state;
  Map<String, Object?>? get remoteOffer => _remoteOffer;
  Map<String, Object?>? get remoteAnswer => _remoteAnswer;

  /// POST /api/v1/sessions → returns `{ session_id, ... }`.
  ///
  /// S56 invariant: the request carries the JWT bearer token
  /// from `_auth.authHeaders()` (Sprint 10.1D's JWT auth
  /// contract).
  Future<String> startSession({String? role}) async {
    final headers = await _auth.authHeaders();
    headers['Content-Type'] = 'application/json';
    final resp = await _client
        .post(
          Uri.parse('${AppConfig.apiBase}/api/v1/sessions'),
          headers: headers,
          body: jsonEncode({
            'role': role ?? 'offerer',
            'device_id_hash': AppConfig.deviceId,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 201 && resp.statusCode != 200) {
      throw OrchestratorException(
        'startSession failed (${resp.statusCode}): ${resp.body}',
        statusCode: resp.statusCode,
      );
    }
    final body = jsonDecode(resp.body) as Map<String, Object?>;
    _sessionId = body['session_id'] as String?;
    _receiverSessionId = body['receiver_session_id'] as String?;
    if (_sessionId == null) {
      throw const OrchestratorException('startSession: missing session_id');
    }
    return _sessionId!;
  }

  /// GET /api/v1/webrtc/offer?session_id=... with 30s long-poll.
  ///
  /// S57 invariant: the long-poll GET carries a 30s timeout
  /// (matching the brief's spec). The backend's GET handler
  /// (Sprint 11.0B v15 — see router.go) holds the request open
  /// for up to 30s, returning either the remote offer SDP (200
  /// + JSON body) or an empty body (204 + no offer yet). The
  /// Dart side cancels the request at 30s and retries.
  Future<Map<String, Object?>?> pollForOffer() async {
    if (_sessionId == null) {
      throw const OrchestratorException('pollForOffer: no session_id');
    }
    if (_tornDown) return null;
    final headers = await _auth.authHeaders();
    final url = Uri.parse(
      '${AppConfig.apiBase}/api/v1/webrtc/offer?session_id=$_sessionId',
    );
    try {
      final resp = await _client.get(url, headers: headers).timeout(
            _pollTimeout,
            onTimeout: () {
              // The backend held the connection open for the
              // full 30s without sending a body. We return null
              // so the caller can retry; the spec is "poll
              // until you get an offer or the user gives up".
              return http.Response('', 204);
            },
          );
      if (resp.statusCode == 204 || resp.body.isEmpty) {
        return null;
      }
      if (resp.statusCode != 200) {
        throw OrchestratorException(
          'pollForOffer failed (${resp.statusCode}): ${resp.body}',
          statusCode: resp.statusCode,
        );
      }
      final body = jsonDecode(resp.body) as Map<String, Object?>;
      _remoteOffer = body['sdp'] as Map<String, Object?>?;
      return _remoteOffer;
    } on TimeoutException {
      // Defensive — the .timeout callback above already returns
      // a 204; this branch is for http-level timeouts (DNS
      // resolution, etc.) that the Future.timeout doesn't catch.
      return null;
    }
  }

  /// GET /api/v1/webrtc/answer?session_id=... with 30s long-poll.
  /// Mirror of [pollForOffer] for the answerer side.
  Future<Map<String, Object?>?> pollForAnswer() async {
    if (_sessionId == null) {
      throw const OrchestratorException('pollForAnswer: no session_id');
    }
    if (_tornDown) return null;
    final headers = await _auth.authHeaders();
    final url = Uri.parse(
      '${AppConfig.apiBase}/api/v1/webrtc/answer?session_id=$_sessionId',
    );
    try {
      final resp = await _client.get(url, headers: headers).timeout(
            _pollTimeout,
            onTimeout: () => http.Response('', 204),
          );
      if (resp.statusCode == 204 || resp.body.isEmpty) {
        return null;
      }
      if (resp.statusCode != 200) {
        throw OrchestratorException(
          'pollForAnswer failed (${resp.statusCode}): ${resp.body}',
          statusCode: resp.statusCode,
        );
      }
      final body = jsonDecode(resp.body) as Map<String, Object?>;
      _remoteAnswer = body['sdp'] as Map<String, Object?>?;
      return _remoteAnswer;
    } on TimeoutException {
      return null;
    }
  }

  /// Drive the offerer-side negotiation:
  ///   1. createOffer on the local peer connection
  ///   2. POST /api/v1/webrtc/offer (with the local SDP)
  ///   3. long-poll /api/v1/webrtc/answer for the remote answer
  ///   4. setRemoteDescription on the local peer connection
  Future<void> negotiateAsOfferer() async {
    if (_sessionId == null) {
      throw const OrchestratorException(
        'negotiateAsOfferer: no session_id (call startSession first)',
      );
    }
    if (_tornDown) return;
    await _webrtc.createPeerConnection();
    final localOffer = await _webrtc.createOffer();
    final headers = await _auth.authHeaders();
    headers['Content-Type'] = 'application/json';
    final offerResp = await _client
        .post(
          Uri.parse('${AppConfig.apiBase}/api/v1/webrtc/offer'),
          headers: headers,
          body: jsonEncode({
            'session_id': _sessionId,
            'peer_hash': AppConfig.deviceId,
            'sdp': localOffer,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (offerResp.statusCode != 201 && offerResp.statusCode != 200) {
      throw OrchestratorException(
        'POST offer failed (${offerResp.statusCode}): ${offerResp.body}',
        statusCode: offerResp.statusCode,
      );
    }
    // Long-poll for the answer.
    final answerSdp = await pollForAnswer();
    if (answerSdp == null) {
      throw const OrchestratorException('no answer received in 30s');
    }
    await _webrtc.setRemoteDescription(
      sdpType: (answerSdp['sdp_type'] as String?) ?? 'answer',
      sdp: (answerSdp['sdp'] as String?) ?? '',
    );
  }

  /// Drive the answerer-side negotiation:
  ///   1. long-poll /api/v1/webrtc/offer for the remote offer
  ///   2. setRemoteDescription on the local peer connection
  ///   3. createAnswer on the local peer connection
  ///   4. POST /api/v1/webrtc/answer (with the local SDP)
  Future<void> negotiateAsAnswerer() async {
    if (_sessionId == null) {
      throw const OrchestratorException(
        'negotiateAsAnswerer: no session_id',
      );
    }
    if (_tornDown) return;
    final offerSdp = await pollForOffer();
    if (offerSdp == null) {
      throw const OrchestratorException('no offer received in 30s');
    }
    await _webrtc.createPeerConnection();
    await _webrtc.setRemoteDescription(
      sdpType: (offerSdp['sdp_type'] as String?) ?? 'offer',
      sdp: (offerSdp['sdp'] as String?) ?? '',
    );
    final localAnswer = await _webrtc.createAnswer();
    final headers = await _auth.authHeaders();
    headers['Content-Type'] = 'application/json';
    final answerResp = await _client
        .post(
          Uri.parse('${AppConfig.apiBase}/api/v1/webrtc/answer'),
          headers: headers,
          body: jsonEncode({
            'session_id': _sessionId,
            'peer_hash': AppConfig.deviceId,
            'sdp': localAnswer,
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (answerResp.statusCode != 200 && answerResp.statusCode != 201) {
      throw OrchestratorException(
        'POST answer failed (${answerResp.statusCode}): ${answerResp.body}',
        statusCode: answerResp.statusCode,
      );
    }
  }

  /// Tear down: close the peer connection + DELETE the session.
  /// Idempotent.
  Future<void> tearDown() async {
    _tornDown = true;
    await _webrtc.close();
    if (_sessionId != null) {
      final headers = await _auth.authHeaders();
      try {
        await _client
            .delete(
              Uri.parse(
                '${AppConfig.apiBase}/api/v1/sessions/$_sessionId',
              ),
              headers: headers,
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // Best-effort: the server cleans up sessions on its
        // 15-minute TTL anyway. Don't fail tearDown over a
        // DELETE error.
      }
    }
    _sessionId = null;
    _receiverSessionId = null;
    _remoteOffer = null;
    _remoteAnswer = null;
  }

  /// Release the underlying [http.Client].
  void close() => _client.close();
}

class OrchestratorException implements Exception {
  const OrchestratorException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => 'OrchestratorException($message, status=$statusCode)';
}
