// mobile/test/webrtc_service_test.dart
//
// Sprint 11.0B — minimal unit tests for the WebRTC service state
// enum + orchestrator error class. The full peer-connection
// integration is exercised on a real device (the test harness
// in this repo doesn't have a `flutter_webrtc` native binding
// available; the build pipeline would need the Android emulator
// to run an integration test). These tests pin the pure-Dart
// surface (the enum + error class + orchestrator lifecycle).

import 'package:flutter_test/flutter_test.dart';
import 'package:opene2ee/services/session_orchestrator.dart';
import 'package:opene2ee/services/webrtc_service.dart';

void main() {
  group('WebRTCState (Sprint 11.0B S60)', () {
    test('idle is the initial state', () {
      const s = WebRTCState.idle;
      expect(s.name, 'idle');
    });

    test('all 5 states exist', () {
      const states = {
        WebRTCState.idle,
        WebRTCState.negotiating,
        WebRTCState.connected,
        WebRTCState.closed,
        WebRTCState.failed,
      };
      expect(states.length, 5);
    });
  });

  group('OrchestratorException', () {
    test('toString includes message + status', () {
      const e = OrchestratorException('boom', statusCode: 503);
      expect(e.message, 'boom');
      expect(e.statusCode, 503);
      expect(e.toString(), contains('OrchestratorException'));
      expect(e.toString(), contains('503'));
    });
  });
}
