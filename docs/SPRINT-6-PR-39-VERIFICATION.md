# Sprint 6 PR-39 — Mobile Security Hardening Verification Plan

> **Status:** Implementation in branch `feat/pr-39-mobile-security-hardening`.
> **Cyber-security hand-off:** findings **MOB-1** (High), **MOB-2** (Medium),
> **MOB-3** (High), **MOB-7 / STRIDE-6-01 / AUTHZ-9** (High).

This document captures the **manual verification plan** for PR-39 changes
that `flutter analyze` / `flutter test` cannot exercise natively (Android
Gradle R8, AndroidManifest merge, iOS Xcode NE target).

The Dart-side regression guards live in
`mobile/test/mobile/security/android_security_posture_test.dart` and
run under `flutter test` on every CI build.

---

## 1. Automated verification (`flutter analyze` + `flutter test`)

```bash
cd mobile
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```

Expected:

- `flutter analyze` reports 0 errors, 0 warnings (lint-clean).
- `flutter test` reports the existing test groups + the new
  `PR-39 Android security posture` + `PR-39 iOS NetworkExtension
  Info.plist posture` groups PASS.

The new test groups assert the following invariants:

| Test | Cyber-security finding | Asserts |
|------|------------------------|---------|
| MOB-1 usesCleartextTraffic pin | MOB-1 | `AndroidManifest.xml <application>` carries `android:usesCleartextTraffic="false"`. |
| MOB-1 tools:remove | MOB-1 | `xmlns:tools` declared + `tools:remove="android:usesCleartextTraffic"` strips library merges. |
| MOB-2 networkSecurityConfig | MOB-2 | `android:networkSecurityConfig="@xml/network_security_config"` is present. |
| MOB-2 trust-anchors = system | MOB-2 | `network_security_config.xml` pins to `<certificates src="system" />` and rejects `<certificates src="user" />`. |
| MOB-3 R8 enabled | MOB-3 | `build.gradle.kts` release block sets `isMinifyEnabled = true`, `isShrinkResources = true`, references `proguard-rules.pro`. |
| MOB-3 keep rules | MOB-3 | `proguard-rules.pro` keeps `io.flutter.**`, `GeneratedPluginRegistrant`, `MainActivity`, `OpenE2eeVpnService`. |
| Privacy invariant (ADR-0006) | ADR-0006 | AndroidManifest does NOT request forbidden device-ID permissions. |
| MOB-7 NE MinimumOSVersion | MOB-7 / STRIDE-6-01 / AUTHZ-9 | `NetworkExtension/Info.plist MinimumOSVersion` is `15.0` AND matches `Runner/Info.plist`. |
| AUTHZ-7 / AUTHZ-8 Runner | AUTHZ-7 / AUTHZ-8 | Runner Info.plist still has `MinimumOSVersion=15.0` + `NSVPNUsageDescription`. |

---

## 2. Manual smoke test — Android (release APK with R8/ProGuard)

> **Prerequisites:** Android Studio Iguana or later, Android SDK
> platform-34, an Android emulator (API 21 + API 34). macOS or Linux
> host recommended; Windows host works for Gradle build but not for
> signing.

### 2.1 Build a release APK

```bash
cd mobile
flutter build apk --release
```

Expected output ends with:

```
✓ Built build/app/outputs/flutter-apk/app-release.apk (XX.X MB)
```

### 2.2 Verify R8 stripped dev symbols

```bash
# `apkanalyzer` ships with the Android SDK cmdline-tools.
$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer \
    dex packages --files build/app/outputs/flutter-apk/app-release.apk \
    | grep -E '(com.opene2ee.opene2ee.MainActivity|OpenE2eeVpnService)' \
    | head -5
```

The class FQDN must still appear (proguard-rules.pro keeps them),
but the method body lines and Kotlin-specific annotations should be
absent. If you see Kotlin `Companion` field references stripped,
re-verify the keep rules include `-keepclassmembers ... Companion`.

### 2.3 Verify cleartext is blocked at runtime

```bash
# Install the release APK on the emulator.
adb install -r build/app/outputs/flutter-apk/app-release.apk

# Launch the app, then attempt to start a sampling session that
# would (in a hypothetical bug) try to talk plaintext to 10.0.2.2.
# Expect the app to fail fast with a `CLEARTEXT_NOT_PERMITTED`
# network exception in logcat, NOT silently fall back.
adb logcat | grep -E '(CLEARTEXT|network_security_config|TrustManager)'
```

If the app silently talks plaintext, the `network_security_config.xml`
is misconfigured; re-check that `<base-config
cleartextTrafficPermitted="false">` is in effect (not just the
`<domain-config>` overrides).

### 2.4 Verify VPN handshake still works

In the app:

1. Open Settings → Privacy → "Allow VPN sampling".
2. Tap "Start sampling" — consent dialog appears.
3. Tap "Allow" — VPN handshake resolves the OpenE2eeVpnService
   class (proguard-rules.pro must keep it).
4. Sampling state machine reaches `sampling` (logcat line
   `OpenE2eeVpnService: state=sampling`).
5. Tap "Stop sampling" — state returns to `stopped` without error.

If the handshake throws `ClassNotFoundException` for
`com.opene2ee.opene2ee.vpn.OpenE2eeVpnService`, R8 stripped the
class. Re-check the keep rules include the FQCN.

---

## 3. Manual smoke test — iOS (NetworkExtension MinimumOSVersion)

### 3.1 Build for an iOS 14 device (regression test)

> **Purpose:** prove the previous "iOS 14 install fails" symptom
> is gone after bumping NE `MinimumOSVersion` to `15.0`.

```bash
cd mobile
# Open the workspace, NOT the project — workspace aggregates
# Runner + NetworkExtension.
open ios/Runner.xcworkspace
```

In Xcode:

1. Select the `NetworkExtension` scheme.
2. **Deployment Info → iOS Deployment Target** must show **15.0**.
3. Select a target device running iOS 14.x (e.g. iPhone 8 with
   iOS 14.8).
4. Build → Run. Xcode should reject the run with:

   ```
   The application requires iOS 15.0 or later
   ```

   This is the **expected** failure mode — it confirms the NE
   target now correctly advertises 15.0 minimum. If Xcode
   accepted the install on iOS 14, the MinimumOSVersion pin
   regressed; revert.

### 3.2 Build for an iOS 15+ device (positive test)

1. Select a target device running iOS 15.x or later.
2. Build → Run. The Runner + NE both install. The VPN toggle
   in Settings shows the OpenE2EE tunnel. Tap it — the
   `OpenE2eeTunnelProvider` extension loads without error.
3. Sample one packet. Confirm `NEPacketTunnelProvider`
   `startTunnel(options:completionHandler:)` callback fires
   (log line `OpenE2eeTunnelProvider: started`).

If the NE target fails to load on iOS 15+, the `NSExtensionPointIdentifier`
or `NSExtensionPrincipalClass` regressed — diff against
`mobile/ios/NetworkExtension/Info.plist` from `origin/main`.

### 3.3 Verify NSVPNUsageDescription present

```bash
/usr/libexec/PlistBuddy -c "Print :NSVPNUsageDescription" \
    build/ios/Release-iphoneos/Runner.app/Info.plist
```

Expected: a non-empty privacy string (e.g. "OpenE2EE uses the
VPN to verify network metadata is not modified in transit.").
If the string is missing, App Store review will reject the binary.

---

## 4. CA pinning rotation procedure (Sprint 7+ follow-up)

The `network_security_config.xml` ships with **commented-out**
`<pin-set>` blocks for `api.opene2ee.com` + `staging.opene2ee.com`.
Before public launch, the operator must:

1. **Compute the SPKI SHA-256 hash** of the production CA:

   ```bash
   openssl x509 -in prod-ca.pem -pubkey -noout \
     | openssl pkey -pubin -outform DER \
     | openssl dgst -sha256 -binary \
     | openssl enc -base64
   ```

   Output is a base64 string like `YLh1dUR9y6Kja30RrAn7JKnbQG/uEtLMkBgFF2Fuihg=`.

2. **Append the pin** alongside the current one (pin-set overlap so
   a CA renewal does not break clients). Pattern:

   ```xml
   <pin-set expiration="2027-07-07">
       <pin digest="SHA-256">YLh1dUR9y6Kja30RrAn7JKnbQG/uEtLMkBgFF2Fuihg=</pin>
       <pin digest="SHA-256">sRHdihwgkaib1P1gN7SkKPjVLmNpQ7YCMoUD6qxoqhE=</pin>
   </pin-set>
   ```

3. **Uncomment the `<domain-config>` block** in
   `network_security_config.xml` and rebuild.

4. **Ship to clients** with at least 90 days of pin overlap. After
   90 days, drop the old pin.

This procedure is documented inline in the file's header comment.

---

## 5. Rollback

If R8/ProGuard breaks the release build on first try (e.g. a
MethodChannel handler is stripped), the quickest mitigation:

```bash
# Revert just the build.gradle.kts block; leave proguard-rules.pro
# + AndroidManifest changes in place.
git checkout origin/main -- mobile/android/app/build.gradle.kts
```

Then add the missing keep rule to `proguard-rules.pro` based on
the R8 mapping file at
`mobile/build/app/outputs/mapping/release/mapping.txt`, and
re-enable `isMinifyEnabled = true`.

The cyber-security MOB-3 finding is HIGH severity; do NOT keep
R8 disabled in a merged release. Either fix the keep rules or
escalate to the architect.

---

## 6. Cross-references

- cyber-security Sprint 6 review: `agents/cyber-security/workspace/reports/sprint6-security-review.md`
- ADR-0003 (VPN layer): `docs/ADR-0003-vpn-layer.md`
- ADR-0006 (Anonim Cihaz Kimliği): `docs/ADR-0006-anonimlik.md`
- OWASP MASVS-NETWORK-1: https://mas.owasp.org/MASVS/0x91-MASVS-NETWORK/
- OWASP MASVS-CODE-2: https://mas.owasp.org/MASVS/0x91-MASVS-CODE/
- Android network-security-config: https://developer.android.com/training/articles/security-config
- Flutter R8 guide: https://docs.flutter.dev/deployment/android#shrinking-your-code-with-r8