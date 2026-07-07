// mobile/test/mobile/auth/biometric_test.dart
//
// Sprint 7 Item 15 / MOB-10 — Biometric prompt hardening unit tests.
//
// These tests pin the privacy contract documented at the top of
// `lib/mobile/auth/biometric.dart`. They DO NOT exercise the real
// `LocalAuthentication` plugin — that requires a physical device or
// simulator — they exercise the privacy-respecting wrapper surface
// (prompt text, options builder, sensitive-op routing, fail-closed
// semantics) via the in-package [FakeBiometricAuthenticator].
//
// What this test pins
// -------------------
// 1. `promptTextContainsNoPii` — every prompt text in the module
//    (constants + `promptReasonFor(...)` for every [SensitiveOperation])
//    matches NONE of the forbidden-token regexes in
//    [kBiometricPromptReasonForbiddenTokens] (UUID dashed / bare /
//    fingerprint hex / e-mail / phone / PII keyword bag / "your X"
//    phrasing).
//
// 2. `hardenedAuthOptionsDisablesPasscodeFallback` — the
//    `kHardenedAuthOptions` builder produces an [AuthenticationOptions]
//    with `biometricOnly == true`. Regression guard for the
//    ADR-0006 "passcode is PII" contract.
//
// 3. `everySensitiveOpHasHardenedPrompt` — every value in
//    [SensitiveOperation] resolves to a non-empty, PII-free
//    prompt string via [promptReasonFor]. Adding a new enum value
//    without updating [promptReasonFor] breaks this test by
//    `default:` non-exhaustiveness (Dart 3 exhaustive-switch).
//
// 4. `wrappersForwardHardenedPrompt` — `requireBiometricForKvkkDelete`
//    and `requireBiometricForKeyExport` forward the prompt reason
//    from [promptReasonFor] to the underlying [BiometricAuthenticator].
//
// 5. `wrappersFailClosedWhenHardwareMissing` — when the underlying
//    authenticator reports not-ready OR throws
//    [BiometricUnavailableError], the wrapper propagates the error
//    (does NOT silently fall back to a non-biometric path).
//
// 6. `fakeAuthenticatorRecordsInvocation` — the
//    [FakeBiometricAuthenticator] test-double records the prompt
//    string + call count so future tests can verify
//    "exactly one prompt per call" / "no retry storm".
//
// References
// ----------
// - lib/mobile/auth/biometric.dart
// - docs/ADR-0006-anonimlik.md
// - cyber-security Sprint 7 review (2026-07-07) finding MOB-10

import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:opene2ee/mobile/auth/biometric.dart';

void main() {
  group('MOB-10 prompt-text privacy', () {
    test('kBiometricPromptReason contains no forbidden PII tokens', () {
      _assertPiiFree(kBiometricPromptReason);
    });

    test('promptReasonFor(kvkkDelete) contains no forbidden PII tokens', () {
      _assertPiiFree(promptReasonFor(SensitiveOperation.kvkkDelete));
    });

    test('promptReasonFor(keyExport) contains no forbidden PII tokens', () {
      _assertPiiFree(promptReasonFor(SensitiveOperation.keyExport));
    });

    test(
        'every SensitiveOperation resolves to a non-empty, PII-free prompt',
        () {
      for (final op in SensitiveOperation.values) {
        final reason = promptReasonFor(op);
        expect(
          reason,
          isNotEmpty,
          reason: 'promptReasonFor($op) returned empty string',
        );
        _assertPiiFree(reason, label: 'promptReasonFor($op)');
      }
    });
  });

  group('MOB-10 hardened options builder', () {
    test('hardenedAuthOptions sets biometricOnly = true (no passcode '
        'fallback per ADR-0006)', () {
      final opts = hardenedAuthOptions();
      expect(
        opts.biometricOnly,
        isTrue,
        reason: 'biometricOnly must be true; passcode IS PII per ADR-0006',
      );
    });

    test('hardenedAuthOptions sets sensitiveTransaction = true', () {
      final opts = hardenedAuthOptions();
      expect(opts.sensitiveTransaction, isTrue);
    });

    test('hardenedAuthOptions sets stickyAuth = false (re-prompt on '
        'foreground)', () {
      final opts = hardenedAuthOptions();
      expect(opts.stickyAuth, isFalse);
    });

    test('hardenedAuthOptions is structurally equal to kHardenedAuthOptions',
        () {
      // Regression guard: the constant and the builder must produce the
      // same AuthenticationOptions — otherwise the call sites diverge
      // from the docstring.
      expect(hardenedAuthOptions(), equals(kHardenedAuthOptions));
    });
  });

  group('MOB-10 wrapper functions', () {
    test('requireBiometricForKvkkDelete forwards kvkkDelete prompt', () async {
      final fake = FakeBiometricAuthenticator();
      final ok = await requireBiometricForKvkkDelete(fake);
      expect(ok, isTrue);
      expect(fake.lastLocalizedReason,
          equals(promptReasonFor(SensitiveOperation.kvkkDelete)));
    });

    test('requireBiometricForKeyExport forwards keyExport prompt', () async {
      final fake = FakeBiometricAuthenticator();
      final ok = await requireBiometricForKeyExport(fake);
      expect(ok, isTrue);
      expect(fake.lastLocalizedReason,
          equals(promptReasonFor(SensitiveOperation.keyExport)));
    });

    test('requireBiometricForKvkkDelete returns false on user-cancel',
        () async {
      final fake = FakeBiometricAuthenticator(authenticateResult: false);
      final ok = await requireBiometricForKvkkDelete(fake);
      expect(ok, isFalse);
      expect(fake.authenticateCallCount, equals(1));
    });

    test(
        'wrappers propagate BiometricUnavailableError (fail-closed on '
        'missing hardware)', () async {
      final fake = FakeBiometricAuthenticator(
        throwUnavailable: const BiometricUnavailableError(
          BiometricUnavailableCause.notEnrolled,
          'NotEnrolled',
        ),
      );
      expect(
        () => requireBiometricForKvkkDelete(fake),
        throwsA(isA<BiometricUnavailableError>()),
      );
      expect(
        () => requireBiometricForKeyExport(fake),
        throwsA(isA<BiometricUnavailableError>()),
      );
    });

    test('wrappers do NOT retry on failure (call count == 1)', () async {
      final fake = FakeBiometricAuthenticator(authenticateResult: false);
      await requireBiometricForKvkkDelete(fake);
      await requireBiometricForKeyExport(fake);
      expect(fake.authenticateCallCount, equals(2));
    });
  });

  group('MOB-10 FakeBiometricAuthenticator', () {
    test('isReady returns injected value', () async {
      expect(await FakeBiometricAuthenticator(ready: true).isReady(), isTrue);
      expect(await FakeBiometricAuthenticator(ready: false).isReady(),
          isFalse);
    });

    test('authenticate records lastLocalizedReason', () async {
      final fake = FakeBiometricAuthenticator();
      await fake.authenticate(localizedReason: 'hello');
      expect(fake.lastLocalizedReason, equals('hello'));
    });
  });

  group('MOB-10 AuthenticationOptions contract', () {
    test('local_auth AuthenticationOptions has biometricOnly field', () {
      // Sanity check on the upstream API surface — if local_auth ever
      // removes this field, the MOB-10 contract breaks at compile time
      // and this test (which references the symbol) makes the
      // regression obvious in CI output.
      const opts = AuthenticationOptions(biometricOnly: true);
      expect(opts.biometricOnly, isTrue);
    });
  });
}

/// Asserts that [text] matches none of the forbidden-PII regexes.
/// Provides a precise per-token failure message so a regression points
/// the developer at the offending token class.
void _assertPiiFree(String text, {String label = 'text'}) {
  for (final re in kBiometricPromptReasonForbiddenTokens) {
    final match = re.firstMatch(text);
    expect(
      match,
      isNull,
      reason: '$label contains forbidden PII token '
          '(${re.pattern}) at "${match?.group(0) ?? ''}" — '
          'full text was: "$text"',
    );
  }
}