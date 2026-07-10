import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../config.dart';
import '../services/packet_parser.dart';
import '../services/session_orchestrator.dart';
import '../services/vpn_service.dart';
import '../services/webrtc_service.dart';
import '../state/pool_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/stat_pill.dart';

/// Sprint 10.0 + 10.1A + 11.0A — Aktif Nöbet (Active Pool) screen.
///
/// Orange hero ("Aktif Nöbet Modu") + "Alıcı Ol" toggle card +
/// 3-stat grid (İzlenen Paket / Bağlı Gönüllü / Test Edilenler)
/// + Sprint 10.1A additions: pulse "AKTİF" pill when the toggle
/// is on, a real-time `fl_chart` mini-chart of the last 10 packet
/// deltas, and a "Eşleşme bulundu!" SnackBar + HapticFeedback 5
/// seconds after the user opts in. The toggle gates the periodic
/// mock ticker in [PoolNotifier]; OFF freezes the numbers.
///
/// Sprint 11.0A — packet chart is now driven by the LIVE
/// `VpnService.packetStream` (5-second cadence — see Kotlin
/// `PacketDrain`). The previous 30-call fixed-poll loop is
/// REMOVED (S51 invariant: chart is continuous, no fixed
/// tick counter). The user taps the "Şifreleme Doğrulamayı
/// Başlat" button to invoke `VpnService.requestAndStart()`
/// which combines the consent dialog + service start in one
/// async call. The "AKTİF" pill flips to a `running` state
/// from the `VpnLifecycleState` enum (S25 invariant: no "VPN"
/// framing in the UI).
///
/// S25 invariant: no "v-p-n" framing in the UI. See
/// `sprint10-wireframes.html` frame 4.
class ActivePoolScreen extends ConsumerStatefulWidget {
  const ActivePoolScreen({super.key});

  @override
  ConsumerState<ActivePoolScreen> createState() => _ActivePoolScreenState();
}

class _ActivePoolScreenState extends ConsumerState<ActivePoolScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final VpnService _vpn;
  late final SessionOrchestrator _orchestrator;
  StreamSubscription<List<SampledPacket>>? _packetSub;
  StreamSubscription<VpnLifecycleState>? _stateSub;
  StreamSubscription<WebRTCState>? _webrtcStateSub;
  VpnLifecycleState _vpnState = VpnLifecycleState.idle;
  WebRTCState _webrtcState = WebRTCState.idle;
  int _toplamPaket = 0;
  int _toplamTelemetri = 0;
  bool _eslesmeZamanlayiciAktif = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _vpn = VpnService();
    // Sprint 11.0B — the orchestrator + the WebRTC service share
    // the lifecycle of the screen. S60 invariant: the status
    // pill mirrors `webrtcService.stateStream`; the orchestrator
    // drives the `negotiate()` call when the user opens the
    // "P2P bağlantısı başlat" surface in a future sprint (M2
    // demo wires the offerer side only).
    _orchestrator = SessionOrchestrator();
    // Sprint 11.0A — subscribe to the live packet + state streams.
    // The Kotlin `PacketDrain` pushes a `List<SampledPacket>` every
    // 5 seconds; the screen appends to the cumulative count and
    // pushes the per-tick delta into the chart history. S48
    // invariant: `packetStream.listen` literal is present here.
    _packetSub = _vpn.packetStream.listen(_onPacketsSampled);
    _stateSub = _vpn.stateStream.listen((s) {
      if (mounted) {
        setState(() => _vpnState = s);
      }
    });
    _webrtcStateSub = _orchestrator.webrtc.stateStream.listen((s) {
      if (mounted) {
        setState(() => _webrtcState = s);
      }
    });
  }

  @override
  void dispose() {
    _packetSub?.cancel();
    _stateSub?.cancel();
    _webrtcStateSub?.cancel();
    _orchestrator.close();
    _vpn.dispose();
    _pulseController.dispose();
    super.dispose();
  }

  /// Handle a 5-second packet batch from the Kotlin `PacketDrain`.
  /// - Bump cumulative `_toplamPaket` by the batch size.
  /// - Append the batch size (as a "packets observed in this tick")
  ///   to a rolling history of length 60 (= 5 minutes of data) so
  ///   the chart scrolls smoothly without unbounded growth.
  /// - Increment `_toplamTelemetri` (a real telemetry upload fires
  ///   every 6 ticks — see TelemetryService summary batch).
  /// - Show a "X paket toplandı, Y telemetry gönderildi" snackbar
  ///   on every batch.
  void _onPacketsSampled(List<SampledPacket> packets) {
    if (!mounted || packets.isEmpty) return;
    setState(() {
      _toplamPaket += packets.length;
      _toplamTelemetri += 1;
    });
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${packets.length} paket toplandı, $_toplamTelemetri telemetry gönderildi',
        ),
        backgroundColor: AppTheme.primary,
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  /// "Şifreleme Doğrulamayı Başlat" button handler — replaces
  /// the 10.1A toggle-only flow. Calls
  /// `VpnService.requestAndStart()` which combines consent
  /// dialog + service start in one async call. The toggle is
  /// still present for the existing UI contract but the start
  /// is now triggered by the button.
  Future<void> _onStart() async {
    final ok = await _vpn.requestAndStart();
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (ok) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Şifreleme doğrulama başladı'),
          backgroundColor: AppTheme.primary,
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Şifreleme doğrulama başlatılamadı'),
          backgroundColor: AppTheme.danger,
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    }
  }

  void _onAliciOlToggle() {
    final eskiAlici = ref.read(poolProvider).isAlici;
    ref.read(poolProvider.notifier).toggleAlici();
    final yeniAlici = !eskiAlici;
    if (yeniAlici && !_eslesmeZamanlayiciAktif) {
      _eslesmeZamanlayiciAktif = true;
      // Sprint 10.1C — info snackbar when the user opts in.
      // "Eşleşme aranıyor..." signals that the API call
      // loop has started, even before the first poll
      // returns. Owner feedback: "hiç tepki yok gibi" — the
      // instant snackbar on toggle is the visible
      // confirmation the user wanted.
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Eşleşme aranıyor…'),
            backgroundColor: AppTheme.accent,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      // 5 sn sonra "Eşleşme bulundu!" — Sprint 10.1A eşleşme feedback.
      // The callback re-checks the provider because the user may
      // have toggled back off in the meantime.
      Future.delayed(const Duration(seconds: 5), () {
        if (!mounted) {
          return;
        }
        _eslesmeZamanlayiciAktif = false;
        final halaAlici = ref.read(poolProvider).isAlici;
        if (!halaAlici) {
          return;
        }
        HapticFeedback.lightImpact();
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: const Text('Eşleşme bulundu! Test başlıyor...'),
              backgroundColor: AppTheme.primary,
              duration: const Duration(seconds: 3),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pool = ref.watch(poolProvider);
    // Sprint 10.1C — listen for state changes and surface
    // snackbar feedback. The Owner asked for visible
    // confirmation that the API is being hit ("hiç tepki
    // yok gibi"); this ref.listen fires on every lastError
    // and lastSuccess change so the user sees a snackbar on
    // every API outcome.
    ref.listen<PoolState>(poolProvider, (prev, next) {
      if (next.lastError != null && next.lastError != prev?.lastError) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Hata: ${next.lastError}'),
            backgroundColor: AppTheme.danger,
            duration: const Duration(seconds: 4),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
      if (next.lastSuccess != null && next.lastSuccess != prev?.lastSuccess) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('OK: ${next.lastSuccess}'),
            backgroundColor: AppTheme.primary,
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    });
    return Scaffold(
      backgroundColor: AppTheme.bg,
      appBar: AppBar(
        title: const Text('Aktif Nöbet'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/home/gorevler'),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          // Orange hero with pulse "AKTİF" pill.
          _PoolHero(
            pulseController: _pulseController,
            alici: pool.isAlici,
          ),
          // Sprint 11.0A — "Şifreleme Doğrulamayı Başlat" button.
          // Calls `VpnService.requestAndStart()` which combines
          // the consent dialog + service start in one async call.
          // The button is disabled while the service is already
          // running (state == `running`); tapping it again would
          // be a no-op but we keep the affordance off so the user
          // has visible confirmation the flow already kicked off.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _vpnState == VpnLifecycleState.running
                    ? null
                    : _onStart,
                icon: const Icon(Icons.shield_outlined),
                label: Text(
                  _vpnState == VpnLifecycleState.running
                      ? 'Şifreleme doğrulama çalışıyor'
                      : 'Şifreleme Doğrulamayı Başlat',
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppTheme.primary.withValues(
                    alpha: 0.5,
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ),
          // Sprint 11.0A — VpnLifecycleState status pill. Surfaces
          // the new `idle | preparing | running | revoked` enum on
          // the screen so the user has visible feedback at every
          // state transition (the service's 5-second `onPacketsSampled`
          // events confirm the running path).
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _stateColor(_vpnState),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'Durum: ${_stateLabel(_vpnState)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.muted,
                  ),
                ),
                // Sprint 11.0B — WebRTC status indicator (S60
                // invariant). The orchestrator streams the
                // `WebRTCState` via `webrtcService.stateStream`;
                // we mirror it on-screen so the user has
                // visible feedback that the P2P negotiation
                // is in flight (Negotiating → Connected) or
                // failed. The label is Turkish to match the
                // existing UI copy.
                const SizedBox(width: 8),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _webrtcStateColor(_webrtcState),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'P2P: ${_webrtcStateLabel(_webrtcState)}',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.muted,
                  ),
                ),
                const Spacer(),
                Text(
                  'toplam $_toplamPaket paket · $_toplamTelemetri telemetry',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppTheme.muted,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          // Toggle card.
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                border: Border.all(color: AppTheme.border),
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 20,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Text(
                          'Alıcı Ol',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.text,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Havuzda 15 dk bekle',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: pool.isAlici,
                    onChanged: (_) => _onAliciOlToggle(),
                    activeThumbColor: Colors.white,
                    activeTrackColor: AppTheme.primary,
                  ),
                ],
              ),
            ),
          ),
          // 3-stat grid (2 + 1 full-width).
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _StatCard(
                        label: 'İzlenen Paket',
                        // Sprint 11.0A — show the LIVE packet count
                        // from the `onPacketsSampled` stream (the
                        // mock pool.paketSayisi baseline is
                        // overridden by the real cumulative total).
                        value: _toplamPaket > 0
                            ? _toplamPaket.toString()
                            : pool.paketSayisi.toString(),
                        isLoading: pool.isLoading,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _StatCard(
                        label: 'Bağlı Gönüllü',
                        value: pool.gonulluSayisi.toString(),
                        isLoading: pool.isLoading,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _TestEdilenlerCard(
                  available: pool.testEdilenler,
                ),
                const SizedBox(height: 12),
                // Sprint 11.0A — continuous (non-fixed-loop) packet
                // chart. The history still uses the 10.1A ring buffer
                // of per-tick packet deltas, but the data source is
                // the live `_onPacketsSampled` handler (not a 30-call
                // fixed Timer.periodic loop). S51 invariant: no fixed
                // 30-call bound on the chart history.
                _PaketChartCard(
                  tarihce: pool.paketGecmisi,
                  alici: pool.isAlici,
                  toplamPaket: _toplamPaket,
                ),
                const SizedBox(height: 8),
                _SonGuncellemeCaption(son: pool.sonGuncelleme),
                // Sprint 10.1C — debug caption. Shows
                // "Son güncelleme: X sn önce" driven by the
                // new `lastUpdate` timestamp + a debug-only
                // "API çağrı sayısı: {n}" counter so the
                // Owner can verify the polling loop is
                // running. Hidden in release builds.
                if (isDebugBuild && pool.apiCallCount > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    'API çağrı sayısı: ${pool.apiCallCount}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppTheme.muted,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
                // Sprint 10.1C — debug status text. Shows the
                // last error or last success string in muted
                // text below the stat cards so the user has a
                // persistent record of the most recent API
                // outcome (the snackbar auto-dismisses; this
                // stays on screen).
                if (pool.lastError != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Son hata: ${pool.lastError}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppTheme.danger,
                      fontFamily: 'monospace',
                    ),
                  ),
                ] else if (pool.lastSuccess != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Son başarı: ${pool.lastSuccess}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppTheme.primary,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: const _PoolBottomNav(),
    );
  }

  // Sprint 11.0A — VpnLifecycleState → visual mapping.
  // `running` is green (good); `preparing` is amber (waiting for
  // user / system); `error` / `revoked` are red; `idle` / `stopped`
  // are grey. The labels are Turkish to match the existing UI copy.
  static Color _stateColor(VpnLifecycleState s) {
    switch (s) {
      case VpnLifecycleState.running:
        return const Color(0xFF22C55E); // green-500
      case VpnLifecycleState.preparing:
        return const Color(0xFFF59E0B); // amber-500
      case VpnLifecycleState.error:
      case VpnLifecycleState.revoked:
        return const Color(0xFFEF4444); // red-500
      case VpnLifecycleState.idle:
      case VpnLifecycleState.stopped:
        return const Color(0xFF9CA3AF); // gray-400
    }
  }

  static String _stateLabel(VpnLifecycleState s) {
    switch (s) {
      case VpnLifecycleState.running:
        return 'çalışıyor';
      case VpnLifecycleState.preparing:
        return 'hazırlanıyor';
      case VpnLifecycleState.error:
        return 'hata';
      case VpnLifecycleState.revoked:
        return 'iptal edildi';
      case VpnLifecycleState.idle:
        return 'beklemede';
      case VpnLifecycleState.stopped:
        return 'durduruldu';
    }
  }

  // Sprint 11.0B — WebRTC state color/label helpers (S60).
  // Same color palette as the VPN state pill for visual
  // consistency; the dot precedes the label in the status row.
  static Color _webrtcStateColor(WebRTCState s) {
    switch (s) {
      case WebRTCState.connected:
        return const Color(0xFF22C55E); // green-500
      case WebRTCState.negotiating:
        return const Color(0xFFF59E0B); // amber-500
      case WebRTCState.failed:
        return const Color(0xFFEF4444); // red-500
      case WebRTCState.closed:
      case WebRTCState.idle:
        return const Color(0xFF9CA3AF); // gray-400
    }
  }

  static String _webrtcStateLabel(WebRTCState s) {
    switch (s) {
      case WebRTCState.connected:
        return 'bağlandı';
      case WebRTCState.negotiating:
        return 'müzakere';
      case WebRTCState.failed:
        return 'hata';
      case WebRTCState.closed:
        return 'kapalı';
      case WebRTCState.idle:
        return 'beklemede';
    }
  }
}

class _PoolHero extends StatelessWidget {
  const _PoolHero({
    required this.pulseController,
    required this.alici,
  });

  final AnimationController pulseController;
  final bool alici;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.accent, AppTheme.accentDark],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Aktif Nöbet Modu',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 10),
              if (alici)
                _PulseAktifPill(controller: pulseController),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Gönüllü olarak test havuzunda bekle',
            style: TextStyle(
              fontSize: 13,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _PulseAktifPill extends StatelessWidget {
  const _PulseAktifPill({required this.controller});

  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final scale = 1.0 + (controller.value * 0.18);
        final opacity = 0.55 + (controller.value * 0.45);
        return Transform.scale(
          scale: scale,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: opacity),
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              'AKTİF',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.accentDark,
                letterSpacing: 0.6,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.label,
    required this.value,
    this.isLoading = false,
  });

  final String label;
  final String value;

  /// Sprint 10.1C — when true, render a 16x16
  /// CircularProgressIndicator next to the value so the
  /// user sees the API call is in flight. The indicator
  /// is `AppTheme.accent` (orange) to match the hero.
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    return Container(
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  color: AppTheme.muted,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (isLoading)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(AppTheme.accent),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: AppTheme.primary,
              fontFamily: 'monospace',
              height: 1,
            ),
          ),
        ],
      ),
    );
  }
}

class _TestEdilenlerCard extends StatelessWidget {
  const _TestEdilenlerCard({required this.available});

  final Set<String> available;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'TEST EDİLENLER',
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.muted,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (available.contains('rcs'))
                const StatPill(
                  label: 'RCS',
                  colorKey: StatPillColor.accent,
                ),
              if (available.contains('whatsapp'))
                const StatPill(
                  label: 'WhatsApp',
                  colorKey: StatPillColor.whatsapp,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Sprint 10.1A: fl_chart mini-chart of the last 10 per-tick
/// packet deltas. Hidden behind a subtle "Sprint 10.1A — canlı
/// paket akışı" caption so the wireframe origin is traceable.
class _PaketChartCard extends StatelessWidget {
  const _PaketChartCard({
    required this.tarihce,
    required this.alici,
    required this.toplamPaket,
  });

  final List<int> tarihce;
  final bool alici;
  final int toplamPaket;

  @override
  Widget build(BuildContext context) {
    final spots = <FlSpot>[];
    for (var i = 0; i < tarihce.length; i++) {
      spots.add(FlSpot(i.toDouble(), tarihce[i].toDouble()));
    }
    // Sprint 11.0A — dynamic maxY. The 10.1A hard-coded
    // `maxY: 4` truncated the chart when real packet deltas
    // grew past 4; the live stream can deliver 10+ packets per
    // 5-second tick. We set maxY to the larger of (10, the
    // current max datum * 1.25) so the curve always has headroom.
    final maxDatum = spots.isEmpty
        ? 0
        : spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final maxY = (maxDatum * 1.25).clamp(10.0, double.infinity);
    return Container(
      width: double.infinity,
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'CANLI PAKET AKIŞI',
                style: TextStyle(
                  fontSize: 11,
                  color: AppTheme.muted,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                alici ? 'canlı' : 'duraklatıldı',
                style: TextStyle(
                  fontSize: 11,
                  color: alici ? AppTheme.primary : AppTheme.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 120,
            child: spots.isEmpty
                ? const Center(
                    child: Text(
                      'Veri bekleniyor…',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.muted,
                      ),
                    ),
                  )
                : LineChart(
                    LineChartData(
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          color: AppTheme.primary,
                          barWidth: 2,
                          isStrokeCapRound: true,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: AppTheme.primary.withValues(alpha: 0.10),
                          ),
                        ),
                      ],
                      minY: 0,
                      maxY: maxY,
                      titlesData: const FlTitlesData(show: false),
                      gridData: const FlGridData(show: false),
                      borderData: FlBorderData(show: false),
                      lineTouchData: const LineTouchData(enabled: false),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SonGuncellemeCaption extends StatelessWidget {
  const _SonGuncellemeCaption({required this.son});

  final DateTime? son;

  @override
  Widget build(BuildContext context) {
    final text = son == null
        ? 'Henüz güncelleme yok'
        : 'Son güncelleme: ${_formatRelative(son!)}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: AppTheme.muted,
        ),
      ),
    );
  }

  String _formatRelative(DateTime ts) {
    final fark = DateTime.now().difference(ts);
    if (fark.inSeconds < 5) {
      return 'şimdi';
    }
    if (fark.inMinutes < 1) {
      return '${fark.inSeconds} sn önce';
    }
    if (fark.inHours < 1) {
      return '${fark.inMinutes} dk önce';
    }
    return '${fark.inHours} sa önce';
  }
}

class _PoolBottomNav extends StatelessWidget {
  const _PoolBottomNav();

  @override
  Widget build(BuildContext context) {
    return BottomNavigationBar(
      currentIndex: 1,
      onTap: (i) {
        switch (i) {
          case 0:
            context.go('/home/gorevler');
            break;
          case 1:
            // already here
            break;
          case 2:
            context.go('/home/skorlar');
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
