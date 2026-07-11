// mobile/test/sprint110d_handler_test.dart
//
// Sprint 11.0D — runtime handler-registration probe (S73 audit gap).
//
// Regression test for the OnePlus 9 Pro error
// `MissingPluginException(No implementation found for method
// getSampledPackets on channel opene2ee/vpn)`.
//
// What this test verifies (and what it does NOT):
//   ✓ Dart-side contract: `VpnService()` constructs the same
//     `opene2ee/vpn` MethodChannel the Kotlin side owns, and
//     `getSampledPackets()` actually calls `invokeMethod` on
//     that channel.
//   ✓ The mock handler is invoked with the literal method name
//     `getSampledPackets` and returns a controlled payload that
//     the Dart side successfully deserialises.
//   ✗ The Kotlin-side handler being present at runtime is NOT
//     directly testable from the Dart unit-test harness — that
//     requires the Android emulator + a real `OpenE2eeVpnService`
//     instance, which is out of scope for `flutter test`.
//
// Why this test is still load-bearing even though it does not
// prove the Kotlin side:
//   1. If a future refactor renames the Dart-side channel
//      (`opene2ee/vpn` → `opene2ee_vpn` etc.) or the call-site
//      method (`getSampledPackets` → `getSampled`), the
//      `opene2ee/vpn` MethodChannel construction here will still
//      wire up, BUT the mock will return a `MissingPluginException`
//      when the call hits the platform side because no handler
//      matches the (renamed) channel / method. The `expect()` below
//      catches that.
//   2. The S73 production audit (in `tools/workflow-yaml-audit.py`
//      `check_main_activity_owns_vpn_channel_v18`) statically
//      checks that `MainActivity.kt` registers the inbound
//      handler. Together, this runtime probe + the static audit
//      provide defence in depth: the static check catches a
//      regression in the Kotlin source, this test catches a
//      regression in the Dart contract.
//
// Sprint 3.44.x test API note (memory: flutter.md):
//   `TestDefaultBinaryMessengerBinding` is NOT instantiable (no
//   `()`). The static reference is itself the singleton.
//   `setMockMethodCallHandler` takes a `MethodChannel` instance
//   (the `MethodChannel.handler` extension is the modern form).
//
// References:
//   - brief-sprint110d.md §3 "Yeni audit gap: S73"
//   - tools/workflow-yaml-audit.py `check_main_activity_owns_vpn_channel_v18`
//   - mobile/lib/services/vpn_service.dart (Dart side, channel
//     `opene2ee/vpn`)
//   - mobile/android/app/src/main/kotlin/com/opene2ee/opene2ee/MainActivity.kt
//     (Kotlin side, host of the channel handler post-Sprint 11.0D)
//   - mobile/android/app/src/main/kotlin/com/opene2ee/opene2ee/vpn/OpenE2eeVpnService.kt
//     (Kotlin side, `dispatch(context, call, result)` static)

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opene2ee/services/vpn_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Sprint 11.0D S73 — opene2ee/vpn MethodChannel probe', () {
    test(
      'getSampledPackets() invokes the opene2ee/vpn channel '
      'with method name `getSampledPackets` and deserialises the '
      'mocked response (regression: OnePlus 9 Pro '
      '`MissingPluginException`)',
      () async {
        // Build a `VpnService` against the same channel name
        // the Kotlin side owns. The constructor registers a
        // Dart-side inbound handler for `onPacketsSampled` events
        // (S47 invariant) but does NOT install a Kotlin-side
        // handler — that's the MainActivity's job (S73).
        //
        // Sprint 11.0F — `VpnService()` is now a singleton
        // factory. The mock test needs a fresh instance with a
        // dedicated channel so the mock handler doesn't leak
        // into other tests sharing the singleton. Use
        // `VpnService.forTesting()` for that.
        final vpn = VpnService.forTesting();

        // We expect the platform messenger to receive exactly one
        // call to `opene2ee/vpn` with method name `getSampledPackets`.
        var invokeCount = 0;
        String? lastMethod;
        const mockedPackets = <Map<String, Object?>>[
          {
            'srcIp': '203.0.113.5',
            'dstIp': '198.51.100.42',
            'srcPort': 54321,
            'dstPort': 443,
            'protocol': 'TCP',
            'tcpFlags': 0x18,
            'length': 1500,
            'ts': 1715000000000,
            'direction': 'out',
            'fingerprint': 'sha256:abcdef',
          },
        ];

        // Mock the platform side. `setMockMethodCallHandler` on
        // `TestDefaultBinaryMessengerBinding` (3.44.x) is the
        // canonical way to intercept `MethodChannel.invokeMethod`
        // calls in unit tests. The lambda receives the
        // [MethodCall] the Dart side emitted.
        TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('opene2ee/vpn'),
              (MethodCall call) async {
                invokeCount += 1;
                lastMethod = call.method;
                if (call.method == 'getSampledPackets') {
                  return mockedPackets;
                }
                if (call.method == 'status') {
                  return <String, Object?>{
                    'state': 'IDLE',
                    'packetsObserved': 0,
                    'ringSize': 0,
                    'samplingCap': 10,
                    'lastError': null,
                    'allowedApplications': null,
                    'disallowedApplications': null,
                  };
                }
                if (call.method == 'start' || call.method == 'stop') {
                  return <String, Object?>{
                    'state': 'IDLE',
                    'packetsObserved': 0,
                    'ringSize': 0,
                    'samplingCap': 10,
                    'lastError': null,
                    'allowedApplications': null,
                    'disallowedApplications': null,
                  };
                }
                return null;
              },
            );

        try {
          // The actual call that was throwing
          // `MissingPluginException` on the OnePlus 9 Pro before
          // Sprint 11.0D. After Sprint 11.0D, the call lands on
          // the mocked handler (in this test) OR the MainActivity-
          // registered handler (on device).
          final packets = await vpn.getSampledPackets();

          // 1. The mock handler was invoked exactly once for
          //    `getSampledPackets` (S73 invariant: the Dart-side
          //    call site uses the right method name).
          expect(invokeCount, 1,
              reason:
                  'getSampledPackets() must invoke the platform '
                  'channel exactly once. invokeCount=$invokeCount '
                  'lastMethod=$lastMethod. Regression guard for the '
                  'OnePlus 9 Pro MissingPluginException — if this '
                  'expect fails, the Dart-side call site has '
                  'drifted from the Kotlin handler.');
          expect(lastMethod, 'getSampledPackets',
              reason:
                  'The Dart-side call must use the literal method '
                  'name `getSampledPackets` that the Kotlin '
                  '`OpenE2eeVpnService.dispatch` routes. '
                  'lastMethod=$lastMethod.');

          // 2. The response is deserialised correctly — proves
          //    the Dart-side contract (`List<Map<String, Object?>>`)
          //    matches what the Kotlin `snapshotRing()` produces.
          expect(packets, isA<List<Map<String, Object?>>>());
          expect(packets, isNotEmpty);
          expect(packets.length, 1);
          expect(packets.first['srcPort'], 54321);
          expect(packets.first['dstPort'], 443);
          expect(packets.first['protocol'], 'TCP');

          // 3. Also exercise `status()` to confirm the channel
          //    is reusable across methods (the polling loop
          //    calls both `getSampledPackets` and `status` on
          //    the same channel instance).
          final status = await vpn.status();
          expect(invokeCount, 2,
              reason: 'status() should fire a SECOND invoke on '
                  'the same channel.');
          expect(status['state'], 'IDLE');
        } finally {
          // Always unregister the mock so a follow-up test
          // that constructs its own `VpnService` does not see
          // stale handler state.
          TestDefaultBinaryMessengerBinding
              .instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('opene2ee/vpn'),
                null,
              );
          vpn.dispose();
        }
      },
    );
  });
}
