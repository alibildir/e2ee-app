// mobile/test/sampled_packet_test.dart
//
// Sprint 11.0A — SampledPacket round-trip tests (S49 invariant).
//
// Verifies:
//   1. SampledPacket.fromBytes(raw) decodes the same wire shape
//      the Kotlin `OpenE2eeVpnService.extractMetadata` produces
//      (the `Map<String, Object?>` returned to Dart via the
//      `getSampledPackets` MethodChannel and the `onPacketsSampled`
//      event).
//   2. SampledPacket.toJson() round-trips back to the same wire
//      shape (so a downstream consumer — TelemetryService or
//      Skorlar — can re-encode without losing fields).
//   3. SampledPacket.fromJson handles missing optional fields
//      (the Kotlin extractor emits null for absent srcPort /
//      dstPort / tcpFlags / fingerprint; the Dart factory must
//      tolerate that and default sensibly).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:opene2ee/services/packet_parser.dart';

void main() {
  group('SampledPacket (Sprint 11.0A S49)', () {
    test('fromBytes → IPv4 TCP returns the same fields as toJson', () {
      // Same fixture as the ParsedPacket test #1.
      final bytes = Uint8List.fromList([
        0x45, 0x00, 0x00, 0x28, // ver/ihl, tos, total length = 40
        0x00, 0x01, 0x00, 0x00,
        0x40, 0x06, 0x00, 0x00, // proto=6 (TCP)
        0x0A, 0x00, 0x00, 0x01,
        0x5D, 0xB8, 0xD8, 0x22,
        0xD4, 0x31, 0x01, 0xBB, // src 54321, dst 443
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x50, 0x12, 0xFF, 0xFF, // flags=0x12 (SYN|ACK)
        0x00, 0x00, 0x00, 0x00,
      ]);
      final s = SampledPacket.fromBytes(bytes);
      expect(s, isNotNull);
      expect(s!.version, 4);
      expect(s.protocol, 'tcp');
      expect(s.protocolNumber, 6);
      expect(s.packetLength, 40);
      expect(s.srcIpMasked, '10.0.0.0');
      expect(s.dstIpMasked, '93.184.216.0');
      expect(s.srcPort, 54321);
      expect(s.dstPort, 443);
      expect(s.tcpFlags, 0x12);
    });

    test('toJson round-trips back to the same wire shape', () {
      final original = SampledPacket(
        version: 4,
        protocol: 'tcp',
        protocolNumber: 6,
        packetLength: 40,
        srcIpMasked: '10.0.0.0',
        dstIpMasked: '93.184.216.0',
        srcPort: 54321,
        dstPort: 443,
        tcpFlags: 0x12,
      );
      final json = original.toJson();
      // All non-null fields are present.
      expect(json['version'], 4);
      expect(json['protocol'], 'tcp');
      expect(json['protocolNumber'], 6);
      expect(json['packetLength'], 40);
      expect(json['srcIpMasked'], '10.0.0.0');
      expect(json['dstIpMasked'], '93.184.216.0');
      expect(json['srcPort'], 54321);
      expect(json['dstPort'], 443);
      expect(json['tcpFlags'], 0x12);
      // Decode back via fromJson — every field survives.
      final decoded = SampledPacket.fromJson(json);
      expect(decoded.version, original.version);
      expect(decoded.protocol, original.protocol);
      expect(decoded.protocolNumber, original.protocolNumber);
      expect(decoded.packetLength, original.packetLength);
      expect(decoded.srcIpMasked, original.srcIpMasked);
      expect(decoded.dstIpMasked, original.dstIpMasked);
      expect(decoded.srcPort, original.srcPort);
      expect(decoded.dstPort, original.dstPort);
      expect(decoded.tcpFlags, original.tcpFlags);
    });

    test('fromJson tolerates missing optional fields (ICMP packet)', () {
      // Kotlin ICMP packet — no ports, no flags, no fingerprint.
      final json = <String, Object?>{
        'version': 4,
        'protocol': 'icmp',
        'protocolNumber': 1,
        'packetLength': 20,
        'srcIpMasked': '1.2.3.0',
        'dstIpMasked': '5.6.7.0',
      };
      final s = SampledPacket.fromJson(json);
      expect(s.srcPort, isNull);
      expect(s.dstPort, isNull);
      expect(s.tcpFlags, isNull);
      expect(s.tlsClientHelloFingerprint, isNull);
      expect(s.protocol, 'icmp');
      expect(s.protocolNumber, 1);
    });

    test('fromJson defaults are sensible for an empty map', () {
      final s = SampledPacket.fromJson(<String, Object?>{});
      expect(s.version, 4);
      expect(s.protocol, 'other');
      expect(s.protocolNumber, 0);
      expect(s.packetLength, 0);
      expect(s.srcIpMasked, '0.0.0.0');
      expect(s.dstIpMasked, '0.0.0.0');
      expect(s.srcPort, isNull);
      expect(s.dstPort, isNull);
      expect(s.tcpFlags, isNull);
      expect(s.tlsClientHelloFingerprint, isNull);
    });
  });
}
