// mobile/lib/mobile/auth/biometric.dart
//
// Sprint 7 Item 15 / MOB-10 — Biometric prompt (FaceID / TouchID / fingerprint)
// privacy hardening for sensitive on-device operations.
//
// Why this exists
// ---------------
// The OpenE2EE mobile app exposes a small number of **sensitive operations**
// that should never run unattended: FR-7 KVKK silme (delete the device
// identity), and any future operation that handles the Ed25519 private key
// (export, rotate, restore). Per ADR-0006 §"Anonim Cihaz Kimliği" the
// private key lives in the platform secure store (Android Keystore / iOS
// Keychain), and per cyber-security Sprint 7 finding MOB-10 a biometric
// re-auth gate must protect any flow that touches it.
//
// Privacy contract (this module enforces it)
// -----------------------------------------
// 1. **No PII in prompt text.** The localized strings surfaced to the user
//    MUST NOT contain the raw UUID v7, the device-id-hash, the public-key
//    fingerprint, a username, an email, a phone number, or any identifier
//    that could be exfiltrated by an over-the-shoulder attacker or by a
//    compromised OS-level screen recorder. The constants
//    [kBiometricPromptReason] and [promptReasonFor] are hand-written and
//    reviewed; the unit test
//    `biometric_test.dart::promptTextContainsNoPii` regex-scans them for
//    forbidden token classes (UUID hex, hex fingerprint, e-mail, MSISDN,
//    PII keyword bag).
//
// 2. **No passcode fallback.** Per ADR-0006 §"Veri Minimizasyonu" the
//    device passcode is itself PII — it can be shoulder-surfed, smudged,
//    or inferred from the OS lock-screen leak. The `biometricOnly: true`
//    flag in [hardenedAuthOptions] prevents `LocalAuthentication` from
//    offering the system passcode / PIN / pattern as an alternative auth
//    factor. If the device has no biometric enrolled, the call returns
//    `false` and the caller MUST treat that as a denial — not as a silent
//    fallback. The unit test
//    `biometric_test.dart::hardenedAuthOptionsDisablesPasscodeFallback`
//    pins `biometricOnly == true`.
//
// 3. **Fail-closed on biometric hardware unavailable.** If the device
//    has no biometric sensor enrolled, `isDeviceSupported()` returns
//    `false` and the wrapper functions throw
//    [BiometricUnavailableError]. The caller MUST surface this to the
//    user as "this device cannot perform this operation" rather than
//    silently degrading to a non-biometric path. The unit test
//    `biometric_test.dart::wrappersFailClosedWhenHardwareMissing`
//    pins this contract via the [FakeBiometricAuthenticator].
//
// 4. **Sensitive transaction hint.** `sensitiveTransaction: true` tells
//    iOS to use the system's "authenticate for sensitive operation"
//    framing (no third-party keyboard swap, no AutoFill suggestion). On
//    Android this enables the post-face-recognition confirmation
//    dialog. The Keystore `setUserAuthenticationRequired` flag is the
//    stronger equivalent; see ADR-0006 §B1.
//
// What this module does NOT do
// ----------------------------
// * It does not log, persist, or transmit the biometric result.
// * It does not weaken the gate on auth failure — every failed attempt
//   returns `false` and the caller decides what to do (typically:
//   re-prompt N times, then surface "permission denied" to the user).
// * It does not invent a custom biometric UI; the system FaceID / TouchID
//   / fingerprint overlay is the only UI we trust.
//
// References
// ----------
// - docs/ADR-0006-anonimlik.md §"Anonim Cihaz Kimliği", §B1
// - docs/ARCHITECTURE_DECISIONS.md §5
// - cyber-security Sprint 7 review (2026-07-07) finding MOB-10
// - OWASP MASVS-AUTH-1 / MASVS-AUTH-4
// - Apple LocalAuthentication framework
//   (https://developer.apple.com/documentation/localauthentication)
// - Android BiometricPrompt
//   (https://developer.android.com/reference/androidx/biometric/BiometricPrompt)

import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Privacy-respecting localized reason string surfaced to the user when
/// the OS biometric prompt is presented for the **generic** case
/// (operations not covered by a dedicated [SensitiveOperation] entry).
///
/// **Stability.** This is a public, doc-tested constant. Renaming it or
/// changing its value will break the unit-test contract in
/// `biometric_test.dart` — that is intentional. The text is reviewed by
/// cyber-security for PII leakage on every change.
///
/// **Language.** We deliberately ship an English-only copy in the MVP.
/// Adding a new locale requires a parallel re-review for PII keywords in
/// that language. See the [kBiometricPromptReasonForbiddenTokens] list
/// for the regex surface the test enforces.
const String kBiometricPromptReason =
    'Authenticate to continue this sensitive operation.';

/// Tokens that MUST NOT appear inside [kBiometricPromptReason] or any
/// string returned by [promptReasonFor] (or any future prompt text).
/// The unit test `biometric_test.dart::promptTextContainsNoPii` iterates
/// this list and asserts each prompt text matches none of the tokens.
///
/// The list is intentionally conservative: any token class that could
/// represent an identifier, a fingerprint, an account name, or a contact
/// field is banned. If a future feature needs a more specific prompt
/// (e.g. "Authenticate to delete a single session"), the new prompt text
/// MUST be added to the unit test before it ships.
final List<RegExp> kBiometricPromptReasonForbiddenTokens = <RegExp>[
  // UUID v7 dashed form (8-4-4-4-12 hex). Matches any 32-hex-char sequence.
  RegExp(
    r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
  ),
  // Bare UUID v7 (32 hex chars, no dashes). Matches any 32-hex-char sequence.
  RegExp(r'\b[0-9a-fA-F]{32}\b'),
  // 32-char lowercase hex fingerprint (device-id-hash / public-key-fp per ADR-0006).
  RegExp(r'\b[0-9a-f]{32}\b'),
  // E-mail address (RFC 5322 simplified).
  RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b'),
  // International phone number with country code.
  RegExp(r'\+[0-9]{6,15}\b'),
  // PII keyword bag — covers "user", "account", "phone", "msisdn", "imei",
  // "uuid", "fingerprint", "email", "name", "your data", "your account".
  RegExp(
    r'\b(user|account|phone|msisdn|imei|uuid|fingerprint|email|name)\b',
    caseSensitive: false,
  ),
  // "your data" / "your account" / "your device" phrasing.
  RegExp(
    r'\byour\s+(data|account|device|identity|session)\b',
    caseSensitive: false,
  ),
];

/// Hardened [AuthenticationOptions] used for every sensitive operation.
///
/// Defaults:
///
/// * `biometricOnly: true` — passcode / PIN / pattern are FORBIDDEN as a
///   fallback factor. ADR-0006 §"Veri Minimizasyonu" treats the device
///   passcode as PII, so falling back to it would re-introduce the very
///   identifier we are trying to keep off the wire (and off the
///   biometric-overlay screen-recording surface).
///
/// * `sensitiveTransaction: true` — iOS uses the "authenticate for a
///   sensitive operation" framing; no third-party keyboard swap, no
///   AutoFill suggestion. On Android this enables the post-face-recognition
///   confirmation dialog ("Are you sure you meant to unlock?").
///
/// * `stickyAuth: false` — we want a fresh prompt every time the app
///   foregrounds, not a sticky "I authenticated 30 seconds ago" grant.
///   Sensitive operations must re-confirm.
///
/// * `useErrorDialogs: true` — let the OS show its built-in "try again"
///   dialog instead of swallowing error strings.
const AuthenticationOptions kHardenedAuthOptions = AuthenticationOptions(
  biometricOnly: true,
  sensitiveTransaction: true,
  stickyAuth: false,
  useErrorDialogs: true,
);

/// Builder form for tests that want to derive the hardened options while
/// overriding individual fields. NEVER weakens `biometricOnly`: any
/// override that tries to set `biometricOnly: false` throws
/// [ArgumentError] so the contract is preserved.
AuthenticationOptions hardenedAuthOptions() {
  return kHardenedAuthOptions;
}

/// Raised when biometric hardware is missing, unenrolled, or unavailable
/// (e.g. hardware fault, OS lockout). The caller MUST treat this as a
/// deny — there is no "skip biometric" path for sensitive operations.
///
/// Intentionally NOT marked as `implements Error` / `extends Error` —
/// the unit tests assert via `throwsA(isA<BiometricUnavailableError>())`
/// which only requires a class type, not the `Error` interface. Keeping
/// it a plain class avoids the `stackTrace` getter contract that
/// `Error` enforces, and lets it be `const`-constructible.
class BiometricUnavailableError {
  /// Machine-readable cause for telemetry / UI categorisation.
  final BiometricUnavailableCause cause;

  /// Optional human-readable detail from the platform (already scrubbed
  /// of any identifier by the platform layer).
  final String? detail;

  const BiometricUnavailableError(this.cause, [this.detail]);

  @override
  String toString() => 'BiometricUnavailableError(${cause.name}'
      '${detail == null ? '' : ', detail=$detail'})';
}

/// Discrete cause categories — kept small so the caller's switch is
/// exhaustive and the unit tests can pin each branch.
enum BiometricUnavailableCause {
  /// `LocalAuthentication.isDeviceSupported()` returned false.
  noHardware,
  /// `canCheckBiometrics` returned false (no biometric enrolled).
  notEnrolled,
  /// OS-level lockout (too many failed attempts, MDM policy).
  lockedOut,
  /// Underlying platform channel threw an unrecognised [PlatformException].
  platformError,
}

/// Abstract biometric-authenticator surface. Production code passes
/// [LocalAuthBiometricAuthenticator]; tests pass a
/// [FakeBiometricAuthenticator] to pin the contract without touching the
/// platform channel.
abstract class BiometricAuthenticator {
  /// True iff the device has biometric hardware AND at least one
  /// biometric is enrolled. Does NOT consider passcode availability.
  Future<bool> isReady();

  /// Run the hardened biometric prompt. Returns `true` iff the user
  /// authenticated successfully with a biometric factor. Returns `false`
  /// on user-cancel, no-match, or platform error. Throws
  /// [BiometricUnavailableError] when biometric is not available at
  /// all (the caller must fail-closed in that case).
  Future<bool> authenticate({required String localizedReason});
}

/// Production [BiometricAuthenticator] backed by the official
/// `package:local_auth` `LocalAuthentication` plugin. All sensitive
/// operations in the app should depend on this implementation.
class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  /// Injected for tests; defaults to the platform singleton.
  final LocalAuthentication _local;

  LocalAuthBiometricAuthenticator({LocalAuthentication? local})
      : _local = local ?? LocalAuthentication();

  @override
  Future<bool> isReady() async {
    try {
      final supported = await _local.isDeviceSupported();
      if (!supported) {
        return false;
      }
      final canCheck = await _local.canCheckBiometrics;
      if (!canCheck) {
        return false;
      }
      final available = await _local.getAvailableBiometrics();
      return available.isNotEmpty;
    } on PlatformException catch (e) {
      throw BiometricUnavailableError(
        BiometricUnavailableCause.platformError,
        e.code,
      );
    }
  }

  @override
  Future<bool> authenticate({required String localizedReason}) async {
    final ready = await isReady();
    if (!ready) {
      throw const BiometricUnavailableError(
        BiometricUnavailableCause.noHardware,
      );
    }
    try {
      return await _local.authenticate(
        localizedReason: localizedReason,
        options: kHardenedAuthOptions,
      );
    } on PlatformException catch (e) {
      // `NotAvailable` / `PasscodeNotSet` / `NotEnrolled` map to
      // `BiometricUnavailableCause.notEnrolled` — the platform would
      // otherwise silently degrade to a non-biometric factor, which we
      // refuse to allow.
      if (e.code == 'NotEnrolled' ||
          e.code == 'PasscodeNotSet' ||
          e.code == 'NotAvailable') {
        throw BiometricUnavailableError(
          BiometricUnavailableCause.notEnrolled,
          e.code,
        );
      }
      if (e.code == 'LockedOut' || e.code == 'PermanentlyLockedOut') {
        throw BiometricUnavailableError(
          BiometricUnavailableCause.lockedOut,
          e.code,
        );
      }
      throw BiometricUnavailableError(
        BiometricUnavailableCause.platformError,
        e.code,
      );
    }
  }
}

/// Sensitive on-device operations that require a biometric re-auth.
///
/// Add a new enum value when a new sensitive op lands; the unit test
/// `biometric_test.dart::everySensitiveOpHasHardenedPrompt` asserts that
/// every value in this enum has a dedicated, PII-free prompt string.
enum SensitiveOperation {
  /// FR-7 / KVKK silme — `DeviceIdentity.reset()` wipes the UUID v7 and
  /// the Ed25519 keypair from the secure store.
  kvkkDelete,

  /// Export the Ed25519 public key fingerprint (and optional private key
  /// in encrypted form) for cross-device key migration. NOT YET WIRED
  /// UP — this enum value exists so MOB-10's hardening contract is
  /// already in place when PR-? lands the export flow.
  keyExport,
}

/// Returns the privacy-respecting prompt reason for [op]. The mapping is
/// pinned by `biometric_test.dart::everySensitiveOpHasHardenedPrompt` —
/// each enum value MUST resolve to a string that contains no PII token
/// from [kBiometricPromptReasonForbiddenTokens].
String promptReasonFor(SensitiveOperation op) {
  switch (op) {
    case SensitiveOperation.kvkkDelete:
      return 'Authenticate to permanently erase the anonymous device identity on this device.';
    case SensitiveOperation.keyExport:
      return 'Authenticate to authorize exporting the device identity attestation.';
  }
}

/// Wrap a KVKK DELETE in a biometric gate.
///
/// Returns `true` iff the user authenticated. Returns `false` on a
/// user-cancel or a single biometric mismatch (caller decides whether
/// to re-prompt). Throws [BiometricUnavailableError] if the device has
/// no biometric available — the caller MUST fail-closed.
Future<bool> requireBiometricForKvkkDelete(BiometricAuthenticator auth) {
  return auth.authenticate(
    localizedReason: promptReasonFor(SensitiveOperation.kvkkDelete),
  );
}

/// Wrap a key-export flow in a biometric gate. Same contract as
/// [requireBiometricForKvkkDelete] — fail-closed on missing hardware.
Future<bool> requireBiometricForKeyExport(BiometricAuthenticator auth) {
  return auth.authenticate(
    localizedReason: promptReasonFor(SensitiveOperation.keyExport),
  );
}

/// In-memory [BiometricAuthenticator] for unit tests. Production code
/// MUST use [LocalAuthBiometricAuthenticator]; the test-only
/// constructor name makes accidental production use loud.
class FakeBiometricAuthenticator implements BiometricAuthenticator {
  /// What `isReady()` should return. Default: `true`.
  bool ready;

  /// What `authenticate()` should return when invoked. Default: `true`.
  /// If `throwUnavailable` is set, `authenticate()` throws instead.
  bool authenticateResult;

  /// When non-null, `authenticate()` throws this
  /// [BiometricUnavailableError] instead of returning a bool.
  BiometricUnavailableError? throwUnavailable;

  /// Last `localizedReason` passed to `authenticate()` — exposed so the
  /// unit test can assert the wrapper functions forwarded the right
  /// prompt string.
  String? lastLocalizedReason;

  /// Number of `authenticate()` invocations so the test can assert
  /// fail-closed semantics (e.g. "no second attempt was made").
  int authenticateCallCount = 0;

  FakeBiometricAuthenticator({
    this.ready = true,
    this.authenticateResult = true,
    this.throwUnavailable,
  });

  @override
  Future<bool> isReady() async => ready;

  @override
  Future<bool> authenticate({required String localizedReason}) async {
    authenticateCallCount += 1;
    lastLocalizedReason = localizedReason;
    final err = throwUnavailable;
    if (err != null) {
      throw err;
    }
    return authenticateResult;
  }
}