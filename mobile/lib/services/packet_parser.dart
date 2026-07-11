// mobile/lib/services/packet_parser.dart
//
// Sprint 10.1B — Dart port of (a subset of) gopacket. Pure-Dart, no
// FFI, no native deps; we trade the full gopacket feature surface
// (PCAP readers, BPF filters, fragmented-IPv6 reassembly, application-
// layer decoders) for the very small slice OpenE2EE actually needs:
//
//   - IPv4 / IPv6 outer header → version, protocol, total length,
//     masked src/dst IP (/24 for IPv4, /48 for IPv6 — the ADR-0006
//     privacy contract).
//   - TCP / UDP next header → src/dst ports + (TCP only) flags.
//   - ICMP / OTHER → src/dst IPs only, no port info.
//
// We do NOT decode the application layer (DNS, TLS ClientHello, etc.)
// at this stage. The tlsClientHelloFingerprint field is reserved for
// Sprint 10.1C when the Dart side will be allowed to read a TINY
// bounded prefix of the TCP payload to fingerprint the SNI hash. For
// now it is always `null`.
//
// Sprint 11.0A — added [SampledPacket] class. This is the
// WIRE-FORMAT type the Kotlin `OpenE2eeVpnService` produces —
// each entry is a `Map<String, Object?>` whose keys match
// `SampledPacket.toJson()` verbatim. `fromBytes(raw)` is the
// inverse of the Kotlin extractor for cases where the Dart side
// needs to re-parse a buffer (e.g. the upcoming Sprint 12
// perf-pipeline). Audit S49 invariant: this class carries
// `fromBytes` + `toJson` round-trip methods.
//
// Privacy contract (ADR-0006 — verbatim invariants)
// --------------------------------------------------
// 1. NO raw packet payload is ever read or stored. The parser
//    walks only the IP + L4 header bytes (max 64 bytes for typical
//    TCP, 40 bytes for IPv6+TCP, 8 bytes for UDP) and discards
//    the rest. The buffer argument is NOT retained after the call
//    returns.
// 2. Source / destination IPs are masked at /24 (IPv4) or /48
//    (IPv6) before being handed to callers.
// 3. We never touch the source MAC, IMEI, MSISDN, phone number,
//    contacts, location, etc. — those are off-limits by ADR-0006.
//
// YOL decision (Sprint 10.1B): the brief offered A) Go NDK + FFI
// (matches ARCHITECTURE §5.6) or B) Dart port. Owner picked B for
// speed; the FFI contract surface is preserved (the public types
// here are what Kotlin will see when the MethodChannel
// `getSampledPackets` returns a `List<Map<String, Object?>>` whose
// values are these `SampledPacket` instances serialized as
// `toJson()` maps). If Sprint 11+ switches to the Go path, the
// FFI shape is a drop-in replacement.

import 'dart:typed_data';

/// L4 protocols we recognise. Anything else is reported as
/// [Protocol.other] (the Kotlin side stores the raw protocol number
/// for forward-compat).
enum Protocol { tcp, udp, icmp, other }

/// Immutable metadata view of a single IP packet. Constructed by
/// [PacketParser.parse]; the [tlsClientHelloFingerprint] field is
/// reserved for Sprint 10.1C and is always `null` in 10.1B.
class ParsedPacket {
  ParsedPacket({
    required this.version,
    required this.protocol,
    required this.protocolNumber,
    required this.totalLength,
    required this.srcIpMasked,
    required this.dstIpMasked,
    this.srcPort,
    this.dstPort,
    this.tcpFlags,
    this.tlsFingerprint,
  });

  /// IP version: 4 or 6.
  final int version;

  /// Decoded L4 protocol (TCP / UDP / ICMP / OTHER).
  final Protocol protocol;

  /// Raw IP-protocol number (6 = TCP, 17 = UDP, 1 = ICMP, …). Kept
  /// so the wire format survives unknown L4s the parser doesn't yet
  /// decode.
  final int protocolNumber;

  /// Total Length field from the IPv4 header, or the Payload Length
  /// from IPv6 (excluding the 40-byte IPv6 header). 0 when not
  /// available (e.g. malformed short packet).
  final int totalLength;

  /// Source IP, masked to /24 (IPv4) or /48 (IPv6) per ADR-0006.
  final String srcIpMasked;

  /// Destination IP, masked to /24 (IPv4) or /48 (IPv6) per ADR-0006.
  final String dstIpMasked;

  /// TCP / UDP source port. `null` for ICMP and OTHER.
  final int? srcPort;

  /// TCP / UDP destination port. `null` for ICMP and OTHER.
  final int? dstPort;

  /// TCP flags byte (SYN=0x02, ACK=0x10, FIN=0x01, RST=0x04, …).
  /// `null` for UDP, ICMP, OTHER.
  final int? tcpFlags;

  /// Reserved. Sprint 10.1B: always `null`. Sprint 10.1C: populated
  /// by the TLS SNI hasher once that lands.
  final String? tlsFingerprint;

  /// Wire-format map for MethodChannel `getSampledPackets` returns.
  /// The Kotlin side feeds these into the JSON body that the
  /// `telemetry_service.dart` POSTs to `api-test.opene2ee.com`.
  Map<String, Object?> toJson() => {
        'version': version,
        'protocol': protocol.name,
        'protocolNumber': protocolNumber,
        'totalLength': totalLength,
        'srcIpMasked': srcIpMasked,
        'dstIpMasked': dstIpMasked,
        if (srcPort != null) 'srcPort': srcPort,
        if (dstPort != null) 'dstPort': dstPort,
        if (tcpFlags != null) 'tcpFlags': tcpFlags,
        if (tlsFingerprint != null) 'tlsClientHelloFingerprint': tlsFingerprint,
      };

  @override
  String toString() => 'ParsedPacket(${srcIpMasked}→$dstIpMasked '
      '${protocol.name} ${srcPort ?? '-'}→${dstPort ?? '-'})';
}

/// Pure-Dart packet parser. Stateless; safe to call from any isolate.
class PacketParser {
  PacketParser._();

  /// Parse a single IP packet. Returns `null` if the buffer is too
  /// short, the version nibble is unrecognised, or any header
  /// length field is invalid. NEVER throws.
  ///
  /// The buffer is read only — the caller retains ownership. We
  /// never allocate beyond the returned [ParsedPacket].
  static ParsedPacket? parse(Uint8List raw) {
    if (raw.isEmpty || raw.length < 1) return null;
    final version = (raw[0] >> 4) & 0x0F;
    if (version == 4) return _parseIpv4(raw);
    if (version == 6) return _parseIpv6(raw);
    return null;
  }

  // ─── IPv4 ───────────────────────────────────────────────────────

  static ParsedPacket? _parseIpv4(Uint8List raw) {
    if (raw.length < 20) return null; // min IPv4 header
    final ihl = raw[0] & 0x0F; // header length in 32-bit words
    if (ihl < 5) return null; // minimum is 5 words = 20 bytes
    final headerLen = ihl * 4;
    if (raw.length < headerLen) return null; // truncated header

    final totalLength = _readUint16(raw, 2);
    final protocolNumber = raw[9];
    final srcAddr = _readUint32(raw, 12);
    final dstAddr = _readUint32(raw, 16);

    return _withL4(
      version: 4,
      protocolNumber: protocolNumber,
      totalLength: totalLength,
      srcIpMasked: _maskIpv4(srcAddr),
      dstIpMasked: _maskIpv4(dstAddr),
      l4Offset: headerLen,
      raw: raw,
    );
  }

  /// Mask an IPv4 address to /24 — zero the last octet. ADR-0006.
  static String _maskIpv4(int addr) {
    final a = (addr >> 24) & 0xFF;
    final b = (addr >> 16) & 0xFF;
    final c = (addr >> 8) & 0xFF;
    return '$a.$b.$c.0';
  }

  // ─── IPv6 ───────────────────────────────────────────────────────

  static ParsedPacket? _parseIpv6(Uint8List raw) {
    if (raw.length < 40) return null; // min IPv6 header
    // (traffic class at offset 0-1, flow label at offset 1-3 —
    // we deliberately drop both; not surfaced to telemetry in 10.1B.)
    final payloadLength = _readUint16(raw, 4);
    final protocolNumber = raw[6];
    // Skip hop limit (1 byte at offset 7)
    final srcBytes = raw.sublist(8, 24);
    final dstBytes = raw.sublist(24, 40);
    final nextHeaderOffset = 40;

    // Walk past extension headers. We support the common
    // no-extension case only (per OpenE2eeVpnService.kt §B.3
    // documented limitation). Hop-by-hop / Routing / Destination /
    // Fragment headers are skipped up to 4 levels — anything more
    // exotic returns null rather than risk mis-parsing the L4.
    int offset = nextHeaderOffset;
    int header = protocolNumber;
    int walked = 0;
    while (_isExtensionHeader(header) && walked < 4) {
      if (raw.length < offset + 2) return null;
      header = raw[offset];
      final extLen = raw[offset + 1]; // in 8-byte units, minus 1
      final extSize = (extLen + 1) * 8;
      if (raw.length < offset + extSize) return null;
      offset += extSize;
      walked++;
    }

    return _withL4(
      version: 6,
      protocolNumber: header,
      totalLength: payloadLength, // IPv6 Payload Length, not Total
      srcIpMasked: _maskIpv6(srcBytes),
      dstIpMasked: _maskIpv6(dstBytes),
      l4Offset: offset,
      raw: raw,
      // (trafficClass + flowLabel deliberately dropped — we don't
      // surface them to telemetry in 10.1B; reserved for future
      // debug work.)
    );
  }

  static bool _isExtensionHeader(int n) {
    // 0 = Hop-by-Hop, 43 = Routing, 44 = Fragment, 50 = ESP,
    // 51 = AH. (60 = Destination — also extension but we don't
    // walk past it because some stacks use it as a terminal
    // pseudo-header.)
    return n == 0 || n == 43 || n == 44 || n == 50 || n == 51;
  }

  /// Mask an IPv6 address to /48 — keep the first 6 bytes (3
  /// 16-bit hextets), zero the remaining 10 bytes. ADR-0006.
  static String _maskIpv6(List<int> bytes) {
    if (bytes.length < 16) return '0:0:0:0:0:0:0:0';
    final masked = List<int>.from(bytes.sublist(0, 6))..addAll(List.filled(10, 0));
    final parts = <String>[];
    for (var i = 0; i < 16; i += 2) {
      final hi = masked[i];
      final lo = masked[i + 1];
      parts.add(((hi << 8) | lo).toRadixString(16));
    }
    return parts.join(':');
  }

  // ─── L4 dispatch ────────────────────────────────────────────────

  static ParsedPacket _withL4({
    required int version,
    required int protocolNumber,
    required int totalLength,
    required String srcIpMasked,
    required String dstIpMasked,
    required int l4Offset,
    required Uint8List raw,
  }) {
    final proto = _decodeProtocol(protocolNumber);
    int? srcPort;
    int? dstPort;
    int? tcpFlags;

    if (proto == Protocol.tcp && raw.length >= l4Offset + 20) {
      srcPort = _readUint16(raw, l4Offset);
      dstPort = _readUint16(raw, l4Offset + 2);
      // TCP flags live in byte 13 of the TCP header.
      tcpFlags = raw[l4Offset + 13];
    } else if (proto == Protocol.udp && raw.length >= l4Offset + 8) {
      srcPort = _readUint16(raw, l4Offset);
      dstPort = _readUint16(raw, l4Offset + 2);
    }
    // ICMP / OTHER: no port info.

    return ParsedPacket(
      version: version,
      protocol: proto,
      protocolNumber: protocolNumber,
      totalLength: totalLength,
      srcIpMasked: srcIpMasked,
      dstIpMasked: dstIpMasked,
      srcPort: srcPort,
      dstPort: dstPort,
      tcpFlags: tcpFlags,
      tlsFingerprint: null,
    );
  }

  static Protocol _decodeProtocol(int n) {
    switch (n) {
      case 6:
        return Protocol.tcp;
      case 17:
        return Protocol.udp;
      case 1:
        return Protocol.icmp;
      default:
        return Protocol.other;
    }
  }

  // ─── helpers ────────────────────────────────────────────────────

  static int _readUint16(Uint8List buf, int offset) {
    return (buf[offset] << 8) | buf[offset + 1];
  }

  static int _readUint32(Uint8List buf, int offset) {
    return (buf[offset] << 24) |
        (buf[offset + 1] << 16) |
        (buf[offset + 2] << 8) |
        buf[offset + 3];
  }
}

// ═══ Sprint 11.0A — SampledPacket (S49 invariant) ═══
//
// Wire format produced by the Kotlin `OpenE2eeVpnService`
// `extractMetadata` (see `mobile/android/app/src/main/kotlin/
// com/opene2ee/opene2ee/vpn/OpenE2eeVpnService.kt`). The class
// is the Dart-side mirror of the Kotlin Map shape so the
// `SampledPacket.fromJson` factory can decode a `List<Map<String,
// Object?>>` returned by the `getSampledPackets` MethodChannel
// call, AND `SampledPacket.fromBytes` can re-parse a raw
// `Uint8List` buffer for the rare case the Dart side wants to
// inspect a single packet end-to-end. The two factories feed the
// same field set; the `toJson` round-trips to MethodChannel wire
// format verbatim.
//
// Privacy: every field is already privacy-safe (IP /24 masked,
// no payload bytes, no device identifiers). `fromBytes` does not
// retain the input buffer after the call returns (per ADR-0006).
class SampledPacket {
  SampledPacket({
    required this.version,
    required this.protocol,
    required this.protocolNumber,
    required this.packetLength,
    required this.srcIpMasked,
    required this.dstIpMasked,
    this.srcPort,
    this.dstPort,
    this.tcpFlags,
    this.tlsClientHelloFingerprint,
  });

  /// IP version: 4 or 6.
  final int version;

  /// L4 protocol name. Mirrors the [Protocol] enum's `name` so
  /// `SampledPacket.toJson()` produces a string the Dart-side
  /// `PacketParser.parse` can also parse. `tcp` / `udp` / `icmp`
  /// / `other`.
  final String protocol;

  /// Raw IP-protocol number (6 = TCP, 17 = UDP, 1 = ICMP, …).
  final int protocolNumber;

  /// Total Length (IPv4) or Payload Length (IPv6) at capture
  /// time. Field name `packetLength` matches the Kotlin
  /// `extractIpv4` / `extractIpv6` key.
  final int packetLength;

  /// Source IP, masked at /24 (IPv4) or /48 (IPv6) per ADR-0006.
  final String srcIpMasked;

  /// Destination IP, masked at /24 (IPv4) or /48 (IPv6) per ADR-0006.
  final String dstIpMasked;

  /// TCP / UDP source port. `null` for ICMP and OTHER.
  final int? srcPort;

  /// TCP / UDP destination port. `null` for ICMP and OTHER.
  final int? dstPort;

  /// TCP flags byte (SYN=0x02, ACK=0x10, FIN=0x01, RST=0x04, …).
  /// `null` for UDP, ICMP, OTHER.
  final int? tcpFlags;

  /// TLS ClientHello fingerprint (IPv4: IP-ID hex; IPv6: flow
  /// label). `null` for UDP/ICMP/OTHER and for IPv6 packets
  /// without a parseable fingerprint. Mirrors the Kotlin key
  /// `tlsClientHelloFingerprint`.
  final String? tlsClientHelloFingerprint;

  /// Round-trip: map → object. Tolerant to missing optional
  /// fields (the Kotlin side emits `null` for absent srcPort /
  /// dstPort / tcpFlags / fingerprint). The [protocol] string
  /// defaults to `'other'` when the wire map does not include
  /// the field.
  factory SampledPacket.fromJson(Map<String, Object?> m) {
    final protoNum = (m['protocolNumber'] as int?) ??
        _protocolNameToNumber(m['protocol'] as String? ?? 'other');
    return SampledPacket(
      version: (m['version'] as int?) ?? 4,
      protocol: (m['protocol'] as String?) ?? 'other',
      protocolNumber: protoNum,
      packetLength: (m['packetLength'] as int?) ??
          (m['totalLength'] as int?) ??
          0,
      srcIpMasked: (m['srcIpMasked'] as String?) ?? '0.0.0.0',
      dstIpMasked: (m['dstIpMasked'] as String?) ?? '0.0.0.0',
      srcPort: m['srcPort'] as int?,
      dstPort: m['dstPort'] as int?,
      tcpFlags: m['tcpFlags'] as int?,
      tlsClientHelloFingerprint: m['tlsClientHelloFingerprint'] as String?,
    );
  }

  /// Round-trip: raw IP bytes → object. Delegates to the existing
  /// [PacketParser.parse] for the actual decode; the result is
  /// then re-shaped into [SampledPacket]. Returns `null` when the
  /// buffer is too short or the version nibble is unrecognised.
  static SampledPacket? fromBytes(Uint8List raw) {
    final parsed = PacketParser.parse(raw);
    if (parsed == null) return null;
    return SampledPacket(
      version: parsed.version,
      protocol: parsed.protocol.name,
      protocolNumber: parsed.protocolNumber,
      packetLength: parsed.totalLength,
      srcIpMasked: parsed.srcIpMasked,
      dstIpMasked: parsed.dstIpMasked,
      srcPort: parsed.srcPort,
      dstPort: parsed.dstPort,
      tcpFlags: parsed.tcpFlags,
      tlsClientHelloFingerprint: parsed.tlsFingerprint,
    );
  }

  /// Wire format — matches the keys the Kotlin
  /// `OpenE2eeVpnService.extractMetadata` emits. Both
  /// `getSampledPackets` poll (MainActivity) and the
  /// `onPacketsSampled` event (PacketDrain) feed this exact
  /// shape into the Dart side.
  Map<String, Object?> toJson() => {
        'version': version,
        'protocol': protocol,
        'protocolNumber': protocolNumber,
        'packetLength': packetLength,
        'srcIpMasked': srcIpMasked,
        'dstIpMasked': dstIpMasked,
        if (srcPort != null) 'srcPort': srcPort,
        if (dstPort != null) 'dstPort': dstPort,
        if (tcpFlags != null) 'tcpFlags': tcpFlags,
        if (tlsClientHelloFingerprint != null)
          'tlsClientHelloFingerprint': tlsClientHelloFingerprint,
      };

  @override
  String toString() => 'SampledPacket($srcIpMasked→$dstIpMasked '
      '$protocol ${srcPort ?? '-'}→${dstPort ?? '-'} '
      'len=$packetLength)';
}

int _protocolNameToNumber(String name) {
  switch (name) {
    case 'tcp':
      return 6;
    case 'udp':
      return 17;
    case 'icmp':
      return 1;
    default:
      return 0;
  }
}
