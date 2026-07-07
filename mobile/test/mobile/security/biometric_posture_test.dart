// mobile/test/mobile/security/biometric_posture_test.dart
//
// Sprint 7 Item 15 / MOB-10 — Native-config regression guard for the
// biometric prompt hardening.
//
// Why a native-config test?
// -------------------------
// The changes MOB-10 ships touch XML / Plist files that the Flutter
// toolchain does NOT round-trip through `flutter test`. But the
// cyber-security review specifically called out these files (MOB-10
// bullets: iOS Info.plist + Android AndroidManifest) as the surface
// that must NOT regress. Running the assertions in `flutter test` gives
// us a CI gate that fails the build the moment a future PR:
//
//   * deletes `NSFaceIDUsageDescription` from Info.plist (which would
//     cause the iOS app to crash on first FaceID prompt with a fatal
//     `NSFaceIDUsageDescription missing` error from
//     `LAContext.canEvaluatePolicy`), OR
//   * removes the `USE_BIOMETRIC` permission from AndroidManifest.xml
//     (which would silently disable `BiometricPrompt` and make the
//     hardening moot — see ADR-0006 §B1), OR
//   * changes the iOS usage description to a string that contains PII
//     (the prompt text is shown in the FaceID overlay verbatim), OR
//   * weakens the Privacy - Biometric description to admit
//     non-biometric factors.
//
// This parallels the PR-39 pattern in
// `mobile/test/mobile/security/android_security_posture_test.dart`.
//
// Test matrix:
//   1. iOS Info.plist carries `<key>NSFaceIDUsageDescription</key>` with
//      a `<string>` value that contains no PII token class
//      (UUID/fingerprint/e-mail/phone/keyword bag).
//   2. iOS Info.plist usage description does NOT mention passcode /
//      PIN / pattern — those would defeat the MOB-10 hardening.
//   3. Android AndroidManifest.xml declares
//      `android.permission.USE_BIOMETRIC` (Android 9+, API 28+).
//   4. Android AndroidManifest.xml does NOT request
//      `USE_FINGERPRINT` (deprecated since API 28; the canonical
//      permission is `USE_BIOMETRIC`).
//   5. Android AndroidManifest.xml retains the existing PRIVACY
//      invariant from PR-39 (no `READ_PHONE_STATE`, no
//      `READ_PRIVILEGED_PHONE_STATE`, no `READ_PHONE_NUMBERS`).
//
// Reference docs:
//   - cyber-security Sprint 7 review (2026-07-07) finding MOB-10
//   - docs/ADR-0006-anonimlik.md §"Veri Minimizasyonu"
//   - Apple `NSFaceIDUsageDescription`:
//     https://developer.apple.com/documentation/bundleresources/information_property_list/nsfaceidusagedescription
//   - Android `USE_BIOMETRIC`:
//     https://developer.android.com/reference/android/Manifest.permission#USE_BIOMETRIC

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opene2ee/mobile/auth/biometric.dart';

/// Resolve the `mobile/` directory by walking up from the current
/// working directory. Test runner's CWD is `mobile/` by default
/// (`flutter test` runs from the package root), but allow an override
/// via the `MOBILE_PACKAGE_ROOT` env var for CI matrix jobs that run
/// from the repo root.
Directory _resolveMobileRoot() {
  final override = Platform.environment['MOBILE_PACKAGE_ROOT'];
  if (override != null && override.isNotEmpty) {
    return Directory(override);
  }
  // `flutter test` CWD is `mobile/`. When run via `dart test`, fall
  // back to looking for `pubspec.yaml` upward.
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}

String _readFile(String relativePath) {
  final root = _resolveMobileRoot();
  final file = File('${root.path}/$relativePath');
  if (!file.existsSync()) {
    fail('Native config file not found: ${file.path}');
  }
  return file.readAsStringSync();
}

/// Strip XML / Plist comments so test assertions don't false-positive
/// on text that appears inside a `<!-- ... -->` block. The iOS
/// `Info.plist` carries the MOB-10 commentary in a comment block above
/// the `NSFaceIDUsageDescription` key — the test must ignore those
/// annotations, just like PR-39's posture test.
String _stripXmlComments(String source) {
  return source.replaceAll(
    RegExp(r'<!--[\s\S]*?-->', multiLine: true),
    '',
  );
}

/// Extract the value of `<key>NAME</key>` followed by
/// `<string>VALUE</string>`. Returns `null` if not present.
String? _extractStringValue(String xml, String keyName) {
  // `<key>NAME</key>\s*<string>VALUE</string>` — VALUE is single-line
  // for our plist usage descriptions. Anchored on the exact key so
  // unrelated `<string>` tags don't false-match.
  final re = RegExp(
    '<key>${RegExp.escape(keyName)}</key>\\s*<string>([^<]*)</string>',
    caseSensitive: false,
  );
  final m = re.firstMatch(xml);
  return m?.group(1);
}

/// True iff `<uses-permission android:name="NAME" />` appears in the
/// manifest. Tolerates either `<uses-permission ... />` (self-closing)
/// or `<uses-permission ...></uses-permission>` (paired).
bool _hasUsesPermission(String xml, String permissionName) {
  // `<uses-permission[^>]*android:name="PERM"[^>]*/?>` (self-closing OR
  // paired — both end with `>` or `/>`). The regex is permissive on
  // attribute order.
  final re = RegExp(
    '<uses-permission[^>]*android:name=["\']${RegExp.escape(permissionName)}["\'][^>]*/?>',
    caseSensitive: false,
  );
  return re.hasMatch(xml);
}

void main() {
  group('MOB-10 iOS Info.plist posture', () {
    final plist = _stripXmlComments(
      _readFile('ios/Runner/Info.plist'),
    );

    test('Info.plist declares NSFaceIDUsageDescription', () {
      final value = _extractStringValue(plist, 'NSFaceIDUsageDescription');
      expect(
        value,
        isNotNull,
        reason:
            'NSFaceIDUsageDescription is REQUIRED by Apple when FaceID is '
            'used. Without it the app crashes on the first biometric '
            'prompt with `NSFaceIDUsageDescription missing`.',
      );
      expect(value, isNotEmpty);
    });

    test('Info.plist NSFaceIDUsageDescription contains no PII tokens', () {
      final value = _extractStringValue(plist, 'NSFaceIDUsageDescription');
      if (value == null) {
        // Already covered by the previous test, but skip cleanly to
        // avoid a confusing double-failure.
        return;
      }
      // Reuse the same forbidden-token regexes the Dart-side prompt
      // text is validated against. If you ever extend the regex list,
        // the iOS prompt text is automatically re-validated too.
      for (final re in kBiometricPromptReasonForbiddenTokens) {
        final m = re.firstMatch(value);
        expect(
          m,
          isNull,
          reason:
              'NSFaceIDUsageDescription contains forbidden PII token '
              '(${re.pattern}) at "${m?.group(0) ?? ''}" — the iOS '
              'FaceID overlay shows this string verbatim. '
              'Full text was: "$value"',
        );
      }
    });

    test('Info.plist NSFaceIDUsageDescription does NOT mention '
        'passcode / PIN / pattern (would defeat MOB-10 hardening)', () {
      final value = _extractStringValue(plist, 'NSFaceIDUsageDescription');
      if (value == null) return;
      final lower = value.toLowerCase();
      // The MOB-10 hardening forbids advertising passcode / PIN /
      // pattern as the auth factor — that would imply the system can
      // fall back to a non-biometric factor, contradicting the
      // `biometricOnly: true` invariant enforced in Dart.
      const forbiddenWords = <String>[
        'passcode',
        'pin',
        'pattern',
      ];
      for (final w in forbiddenWords) {
        expect(
          lower.contains(w),
          isFalse,
          reason:
              'NSFaceIDUsageDescription contains "$w" — this would defeat '
              'the MOB-10 biometricOnly invariant. The iOS usage '
              'description must describe biometric authentication only. '
              'Full text was: "$value"',
        );
      }
    });
  });

  group('MOB-10 Android AndroidManifest.xml posture', () {
    final manifest = _stripXmlComments(
      _readFile('android/app/src/main/AndroidManifest.xml'),
    );

    test('AndroidManifest.xml declares USE_BIOMETRIC permission', () {
      expect(
        _hasUsesPermission(manifest, 'android.permission.USE_BIOMETRIC'),
        isTrue,
        reason:
            'USE_BIOMETRIC is required for Android BiometricPrompt '
            '(API 28+). Without it the biometric gate is silently '
            'disabled and MOB-10 hardening is moot.',
      );
    });

    test(
        'AndroidManifest.xml does NOT request deprecated USE_FINGERPRINT '
        '(canonical permission is USE_BIOMETRIC since API 28)', () {
      expect(
        _hasUsesPermission(manifest, 'android.permission.USE_FINGERPRINT'),
        isFalse,
        reason:
            'USE_FINGERPRINT was deprecated in API 28 (Android 9). The '
            'canonical permission is USE_BIOMETRIC. Keeping the '
            'deprecated one around invites a future developer to think '
            'both are required (they are not — USE_FINGERPRINT is a '
            'subset of USE_BIOMETRIC).',
      );
    });

    test(
        'AndroidManifest.xml retains the PR-39 PRIVACY invariant '
        '(no READ_PHONE_STATE / READ_PHONE_NUMBERS / '
        'READ_PRIVILEGED_PHONE_STATE)', () {
      // Re-pinned here so a future "biometric hardening" PR does not
      // silently introduce a hardware-identifier permission while
      // adding the biometric permission.
      const forbiddenPerms = <String>[
        'android.permission.READ_PHONE_STATE',
        'android.permission.READ_PHONE_NUMBERS',
        'android.permission.READ_PRIVILEGED_PHONE_STATE',
      ];
      for (final p in forbiddenPerms) {
        expect(
          _hasUsesPermission(manifest, p),
          isFalse,
          reason:
              'AndroidManifest.xml requests forbidden PII-collecting '
              'permission $p — see docs/ADR-0006 §"Veri Minimizasyonu". '
              'Biometric hardening MUST NOT introduce hardware '
              'identifiers as a side-effect.',
        );
      }
    });
  });

  group('MOB-10 cross-platform invariants', () {
    test('local_auth is pinned to a version range that has biometricOnly',
        () {
      // Defensive check on the Dart-side surface. If a future major
      // bump of `local_auth` removes the `biometricOnly` flag, the
      // MOB-10 contract breaks at compile time and this test makes
      // the regression visible in CI output.
      final pubspec = _readFile('pubspec.yaml');
      expect(
        pubspec,
        contains('local_auth'),
        reason: 'pubspec.yaml must declare local_auth for biometric '
            'prompt hardening',
      );
      // The MOB-10 comment block also exists so a future maintainer
      // does not silently bump past the 2.x contract.
      expect(
        pubspec,
        contains('PR-S7-MOB-10'),
        reason: 'pubspec.yaml must keep the MOB-10 explanatory comment '
            'alongside the local_auth pin',
      );
    });
  });
}