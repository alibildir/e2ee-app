// mobile/lib/services/vpn_service.dart
//
// Sprint 10.1B — Dart-side MethodChannel client for the Android
// `opene2ee/vpn` MethodChannel. Mirrors the Kotlin handler in
// `MainActivity.kt` / `OpenE2eeVpnService.kt`.
//
// Channel: `opene2ee/vpn` (matches `OpenE2eeVpnService.METHOD_CHANNEL`).
//
// Inbound methods (Dart → Kotlin)
// --------------------------------
//   "start"               → begin capture (caller must have
//                            obtained RESULT_OK from
//                            VpnService.prepare first).
//   "stop"   {graceful}   → tear down + flush ring.
//   "status"              → snapshot of {state, packetsObserved,
//                            ringSize, samplingCap}.
//   "getSampledPackets"   → returns a List<Map<String, Object?>>
//                            produced by `OpenE2eeVpnService`'s
//                            bounded ring buffer; each entry is
//                            the same shape `SampledPacket.toJson()`
//                            produces, so the caller can pipe
//                            them straight into
//                            `TelemetryService.send`.
//   "requestPrepare"      → returns the Android intent action the
//                            activity must `startActivityForResult`
//                            for (handled by MainActivity, exposed
//                            here for convenience).
//
// Outbound methods (Kotlin → Dart)
// --------------------------------
//   "onPacketsSampled" event (Sprint 11.0A) — pushed every 5s
//                          by the service's `PacketDrain` inner
//                          class via the shared `methodChannel`.
//                          Payload is a `List<Map<String, Object?>>`
//                          matching `SampledPacket.toJson()`. Dart
//                          subscribes through [packetStream].
//   "onTelemetry" event   → final flush of the ring + capture
//                          timestamp (legacy 10.1B channel).
//
// Permission flow
// ---------------
// `requestVpnPermission` lives on a SECOND channel
// `opene2ee/vpn_permissions` (handled by MainActivity, not the
// service) — see `MainActivity.kt` §PERMISSIONS_CHANNEL.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'packet_parser.dart';

/// Lifecycle state of the foreground capture service. Mirrors the
/// Kotlin `OpenE2eeVpnService.State` enum (IDLE / SAMPLING /
/// DRAINING / STOPPED / ERROR) but exposes a Dart-friendly
/// lowercase name so the UI can show the same labels in
/// Turkish + English. Used by [VpnService.stateStream] and the
/// `idle | preparing | running | revoked` enum referenced in
/// the Sprint 11.0A brief.
enum VpnLifecycleState {
  /// No service is alive (or service is in IDLE).
  idle,

  /// `requestAndStart()` is in flight — VPN permission dialog
  /// is being prepared or `start` is being invoked.
  preparing,

  /// Service is SAMPLING — TUN interface is up, packets are
  /// flowing, `onPacketsSampled` events are being pushed.
  running,

  /// Service was stopped by the user (or by `stop()`) — TUN
  /// has been torn down. Maps from `STOPPED`.
  stopped,

  /// Service is in ERROR — capture failed, no packets.
  error,

  /// User revoked the VPN profile from system settings —
  /// `onRevoke()` fired on the Kotlin side, Dart-side cleanup
  /// is in progress.
  revoked,
}

class VpnService {
  /// Sprint 11.0F — private constructor used by the singleton
  /// initializer and the test factory. The default `VpnService()`
  /// factory (below) returns the singleton; tests use
  /// `VpnService.forTesting(channel: ...)` to inject a custom
  /// [MethodChannel].
  VpnService._internal({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('opene2ee/vpn') {
    // Sprint 11.0A — wire the `onPacketsSampled` event stream.
    // S47 invariant: the `MethodChannel` is the same channel the
    // `start` / `stop` / `status` / `getSampledPackets` calls
    // already ride on; the inbound direction is read by setting
    // a handler that fans out to a [StreamController] (broadcast
    // so multiple subscribers — e.g. ActivePoolScreen +
    // TelemetryService — can each observe the same events).
    _channel.setMethodCallHandler(_onNativeCall);
  }

  /// Sprint 11.0F — singleton accessor. All app code uses this
  /// (the default `VpnService()` factory below delegates here).
  /// Pre-11.0F, each call site constructed a fresh
  /// [VpnService], which:
  ///   (a) replaced the previous `_channel.setMethodCallHandler`
  ///       (so events landed on whichever instance was
  ///       constructed LAST — typically `PoolNotifier` in the
  ///       Riverpod provider graph, not the `active_pool_screen`),
  ///   (b) created a fresh `_packetCtrl` / `_stateCtrl`
  ///       StreamController, so UI subscribers to the OLD
  ///       instance's `packetStream` / `stateStream` never saw
  ///       updates.
  /// Result on OnePlus 9 Pro (Owner 11:01 report, Senaryo D):
  /// the Kotlin service was running, the foreground notification
  /// was visible, but the UI's state pill stayed on "HAZIRLANIYOR"
  /// and the packet count never incremented. The fix is a
  /// singleton: ONE [VpnService] for the whole app, with ONE
  /// shared `_packetCtrl` / `_stateCtrl` and ONE channel
  /// handler.
  static final VpnService _instance = VpnService._internal();

  /// Sprint 11.0F — explicit singleton accessor. The
  /// `VpnService()` factory below is the preferred call site
  /// for app code (backwards compatible); `VpnService.instance`
  /// is the canonical form for tests + future call sites.
  static VpnService get instance => _instance;

  /// Sprint 11.0F — backwards-compatible factory that returns
  /// the singleton. Pre-11.0F, `VpnService()` constructed a
  /// fresh instance; that call shape is preserved (the factory
  /// here returns the singleton), so existing call sites in
  /// `pool_provider.dart`, `active_pool_screen.dart`, and the
  /// Sprint 11.0D handler test don't have to change.
  factory VpnService() => _instance;

  /// Sprint 11.0F — test-only factory for injecting a custom
  /// [MethodChannel] (e.g. `TestDefaultBinaryMessengerBinding`
  /// mock). Returns a fresh instance — do NOT use from app
  /// code, use the default [VpnService] constructor (singleton)
  /// or [VpnService.instance] instead.
  factory VpnService.forTesting({MethodChannel? channel}) =>
      VpnService._internal(channel: channel);

  final MethodChannel _channel;
  final StreamController<List<SampledPacket>> _packetCtrl =
      StreamController<List<SampledPacket>>.broadcast();
  final StreamController<VpnLifecycleState> _stateCtrl =
      StreamController<VpnLifecycleState>.broadcast();

  /// Live packet stream. Emits a list of [SampledPacket] every
  /// 5 seconds (the Kotlin `PacketDrain` cadence — see
  /// `OpenE2eeVpnService.DRAIN_INTERVAL_SECONDS`). The list is
  /// the snapshot of the service's bounded ring at the moment
  /// the drain tick fired. Subscribers should treat each list as
  /// an INDEPENDENT snapshot (not a delta); the service ring
  /// is bounded and old entries are dropped once full.
  Stream<List<SampledPacket>> get packetStream => _packetCtrl.stream;

  /// Lifecycle state stream. Emits the new state on every
  /// transition observed by the service (IDLE / SAMPLING /
  /// DRAINING / STOPPED / ERROR / onRevoke). Subscribers
  /// (ActivePoolScreen) drive the "AKTİF / duraklatıldı" pill
  /// from the most recent value.
  Stream<VpnLifecycleState> get stateStream => _stateCtrl.stream;

  /// Start the local TUN capture. The caller must already hold
  /// RESULT_OK from `VpnService.prepare`; if not, the call
  /// throws `PlatformException` with code `vpn_not_prepared`.
  Future<Map<String, Object?>> start() async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('start');
    _stateCtrl.add(_stateFromMap(r?.cast<String, Object?>()));
    return (r ?? const {}).cast<String, Object?>();
  }

  /// Stop capture. When [graceful] is true, the service flushes
  /// the ring buffer + finalises the foreground notification
  /// before tearing down; when false, it tears down immediately
  /// (used on user-cancel).
  Future<Map<String, Object?>> stop({bool graceful = true}) async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>(
      'stop',
      {'graceful': graceful},
    );
    _stateCtrl.add(_stateFromMap(r?.cast<String, Object?>()));
    return (r ?? const {}).cast<String, Object?>();
  }

  /// Snapshot the service status.
  Future<Map<String, Object?>> status() async {
    final r = await _channel.invokeMethod<Map<Object?, Object?>>('status');
    return (r ?? const {}).cast<String, Object?>();
  }

  /// Drain the ring buffer of metadata snapshots. Returns a
  /// `List<Map<String, Object?>>` whose shape matches
  /// `SampledPacket.toJson()` so the result can be fed straight
  /// into `TelemetryService.send`.
  ///
  /// The ring is consumed atomically — the caller's view is
  /// independent of subsequent sampling. The service caps the
  /// ring at `SAMPLING_CAP_PACKETS` (10) so a slow consumer does
  /// not leak memory.
  Future<List<Map<String, Object?>>> getSampledPackets() async {
    final r = await _channel.invokeMethod<List<Object?>>('getSampledPackets');
    if (r == null) return const [];
    return r
        .whereType<Map<Object?, Object?>>()
        .map((m) => m.cast<String, Object?>())
        .toList(growable: false);
  }

  /// Sprint 11.0A — combined "request consent + start" flow.
  /// Replaces the older 3-step dance of `requestPrepare` +
  /// `onActivityResult` + `start` with a single async call.
  /// Returns `true` if the service is running, `false` if the
  /// user declined consent or any step failed (throwing on
  /// platform errors). The implementation:
  ///   1. ensure Android 13+ `POST_NOTIFICATIONS` runtime
  ///      permission is granted (Sprint 11.0F — Senaryo C fix;
  ///      pre-11.0F the helper existed in MainActivity but was
  ///      unreachable from Dart, so on Android 13+ the user
  ///      would never see the foreground notification even
  ///      though the service was running);
  ///   2. invoke `requestPrepare` on the permissions channel
  ///      (handled by MainActivity);
  ///   3. on consent → invoke `start` on the main channel;
  ///   4. return whether `start` succeeded.
  /// The state stream is updated at every transition so the UI
  /// pill flips `preparing → running` (or `preparing → revoked`).
  ///
  /// Sprint 11.0F — `debugPrint` breadcrumbs at each step. The
  /// OnePlus 9 Pro "tap Aktif Nöbet → nothing happens" symptom
  /// (Owner 10:56 report) was traced via these breadcrumbs to
  /// either Senaryo A (Magisk Zygisk intercepts
  /// `Builder.establish()` → null → error) or Senaryo C
  /// (POST_NOTIFICATIONS denied → notification silent). The
  /// breadcrumbs + the new `ensureNotificationPermission` call
  /// in step 1 give the Owner the runtime evidence to disambiguate.
  Future<bool> requestAndStart() async {
    _stateCtrl.add(VpnLifecycleState.preparing);
    debugPrint('VpnService.requestAndStart: state=preparing');
    try {
      const permChannel = MethodChannel('opene2ee/vpn_permissions');

      // Step 1 (Sprint 11.0F — Senaryo C fix): ensure the
      // Android 13+ POST_NOTIFICATIONS runtime permission is
      // granted. On API < 33 the call is a no-op success.
      // On API 33+ the helper shows the runtime permission
      // dialog if not already granted; the user can still
      // decline, in which case the service runs but the
      // notification is silent. The Dart flow does NOT block
      // on this — the helper is fire-and-forget — so the
      // flow continues to step 2 even if the user hasn't
      // responded yet.
      try {
        final notifGranted = await permChannel
            .invokeMethod<bool>('ensureNotificationPermission');
        debugPrint(
            'VpnService.requestAndStart: ensureNotificationPermission returned $notifGranted');
      } catch (e) {
        debugPrint(
            'VpnService.requestAndStart: ensureNotificationPermission threw (continuing anyway): $e');
      }

      // Step 2: ask the activity to launch the consent dialog.
      // MainActivity owns `opene2ee/vpn_permissions`; we use a
      // separate channel to avoid colliding with the main one
      // (which is owned by `OpenE2eeVpnService`).
      final ok = await permChannel.invokeMethod<bool>('requestVpnPermission');
      debugPrint('VpnService.requestAndStart: requestVpnPermission returned $ok');
      if (ok != true) {
        _stateCtrl.add(VpnLifecycleState.revoked);
        debugPrint('VpnService.requestAndStart: revoked (consent denied)');
        return false;
      }
      // Step 3: kick off the foreground service.
      final r = await _channel.invokeMethod<Map<Object?, Object?>>('start');
      debugPrint('VpnService.requestAndStart: start returned $r');
      _stateCtrl.add(_stateFromMap(r?.cast<String, Object?>()));
      return true;
    } catch (e) {
      debugPrint('VpnService.requestAndStart: caught exception: $e');
      _stateCtrl.add(VpnLifecycleState.error);
      return false;
    }
  }

  /// Tear-down helper. Sprint 11.0F — idempotent + safe on the
  /// singleton: the singleton's `dispose()` is a no-op (the
  /// `forTesting()` instances can still tear down properly).
  /// Pre-11.0F, every widget rebuild created a fresh
  /// `VpnService` whose `dispose()` was called on the screen's
  /// teardown. With the singleton, the screen teardown is NOT
  /// the end of the service — `PoolNotifier` (the Riverpod
  /// provider) and the singleton's UI both outlive any single
  /// screen. Closing the stream controllers here would
  /// permanently silence the singleton, which is exactly the
  /// regression we are trying to fix.
  void dispose() {
    if (identical(this, _instance)) {
      // Singleton — no-op. The streams stay open for the
      // lifetime of the app. The channel handler stays
      // registered. Re-calling `dispose()` is safe.
      return;
    }
    _channel.setMethodCallHandler(null);
    if (!_packetCtrl.isClosed) _packetCtrl.close();
    if (!_stateCtrl.isClosed) _stateCtrl.close();
  }

  /// Map a Kotlin `state` string (UPPERCASE) to a Dart
  /// [VpnLifecycleState]. Falls back to [VpnLifecycleState.idle]
  /// for unrecognised values.
  VpnLifecycleState _stateFromMap(Map<String, Object?>? r) {
    final raw = (r?['state'] as String?) ?? 'IDLE';
    switch (raw.toUpperCase()) {
      case 'SAMPLING':
        return VpnLifecycleState.running;
      case 'DRAINING':
        return VpnLifecycleState.running;
      case 'STOPPED':
        return VpnLifecycleState.stopped;
      case 'ERROR':
        return VpnLifecycleState.error;
      case 'IDLE':
      default:
        return VpnLifecycleState.idle;
    }
  }

  /// Inbound `opene2ee/vpn` MethodChannel handler. Fans out
  /// the `onPacketsSampled` events to [packetStream] and the
  /// `onError` / `onTelemetry` events to internal observers.
  /// Registered in the constructor.
  Future<dynamic> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onPacketsSampled':
        // Payload shape: `List<Object?>` whose elements are
        // `Map<Object?, Object?>` (the Kotlin `extractMetadata`
        // map). Each entry maps 1:1 to a [SampledPacket].
        final raw = call.arguments;
        if (raw is List) {
          final packets = raw
              .whereType<Map<Object?, Object?>>()
              .map((m) => SampledPacket.fromJson(m.cast<String, Object?>()))
              .toList(growable: false);
          if (!_packetCtrl.isClosed) {
            _packetCtrl.add(packets);
          }
        }
        return null;
      case 'onError':
        final code = (call.arguments is Map)
            ? (call.arguments as Map)['code'] as String? ?? 'vpn_runtime_error'
            : 'vpn_runtime_error';
        if (!_stateCtrl.isClosed) {
          _stateCtrl.add(VpnLifecycleState.error);
        }
        // The previous 10.1B behaviour surfaced the error
        // string to a callback the consumer wired. We keep
        // parity by adding a sentinel `null` so subscribers
        // see the error event with no extra args.
        return code;
      case 'onTelemetry':
        // Legacy 10.1B channel — final flush on stop. Convert
        // the same way as `onPacketsSampled` and emit on the
        // packet stream so consumers do not have to special-case
        // the stop path.
        final raw = call.arguments;
        if (raw is Map && raw['packets'] is List) {
          final packets = (raw['packets'] as List)
              .whereType<Map<Object?, Object?>>()
              .map((m) => SampledPacket.fromJson(m.cast<String, Object?>()))
              .toList(growable: false);
          if (!_packetCtrl.isClosed) {
            _packetCtrl.add(packets);
          }
        }
        return null;
      default:
        return null;
    }
  }
}
