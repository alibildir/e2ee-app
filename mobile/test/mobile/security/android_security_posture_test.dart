// mobile/test/mobile/security/android_security_posture_test.dart
//
// PR-39 (Sprint 6) — Regression-guard tests for the Android security
// posture addressed in PR-39 (Sprint 6). These tests are NOT unit tests
// of Dart code; they parse the native config files on disk and assert
// the security-relevant contract documented in
// `cyber-security Sprint 6 review` (findings MOB-1, MOB-2, MOB-3).
//
// Why parse native config from a Dart unit test?
// -----------------------------------------------
// The changes PR-39 ships are in XML/Gradle/Plist files that the
// Flutter toolchain does NOT round-trip through `flutter test`. But
// the cyber-security review specifically called out these files
// (MOB-1, MOB-2, MOB-3) as the surface that must NOT regress.
// Running them in `flutter test` gives us a CI gate that fails the
// build the moment a future PR deletes the `usesCleartextTraffic`
// pin, disables R8/ProGuard, or strips the network security config.
//
// Test matrix:
//   1. AndroidManifest.xml `<application>` carries:
//        - `android:usesCleartextTraffic="false"`
//        - `android:networkSecurityConfig="@xml/network_security_config"`
//        - `xmlns:tools` namespace (required by `tools:remove`).
//   2. network_security_config.xml pins to `system` trust anchors only,
//      and disables cleartext (`cleartextTrafficPermitted="false"`).
//   3. build.gradle.kts release block has `isMinifyEnabled = true` and
//      `isShrinkResources = true`, and references `proguard-rules.pro`.
//   4. proguard-rules.pro keeps the Flutter embedding + the OpenE2ee
//      Kotlin sources (MainActivity + OpenE2eeVpnService) so R8 does
//      not strip them.
//   5. AndroidManifest.xml does NOT request forbidden device-ID
//      permissions (privacy invariant from ADR-0006).
//
// Reference docs:
//   - docs/SPRINT-6-PR-39-VERIFICATION.md (manual smoke test plan)
//   - cyber-security Sprint 6 review (2026-07-07)

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

/// Strip XML/Gradle/Plist comments so test assertions don't false-positive
/// on text that appears inside a `<!-- ... -->` or `// ...` block. Privacy
/// invariants in particular live as commentary in AndroidManifest.xml —
/// the test must ignore them.
String _stripComments(String source) {
  // XML / Plist comments: `<!-- ... -->` (non-greedy, may span lines).
  final noXmlComments = source.replaceAll(
    RegExp(r'<!--[\s\S]*?-->', multiLine: true),
    '',
  );
  // Kotlin line comments: `// ...` to end of line. We only strip lines
  // whose first non-whitespace is `//` to avoid eating `://` inside
  // attribute values like `xmlns:tools="http://schemas.android.com/..."`.
  final stripped = noXmlComments.split('\n').map((line) {
    final idx = line.indexOf('//');
    if (idx < 0) return line;
    // Make sure the `//` is not inside a string literal. For our config
    // files this is conservative enough — we never write `//` inside
    // a property string value.
    final before = line.substring(0, idx);
    final quoteCount = '"'.allMatches(before).length;
    if (quoteCount.isOdd) return line;
    return before;
  }).join('\n');
  return stripped;
}

bool _attributePresent(String xml, String tag, String attr, String want) {
  // Match either attribute="want" or attribute='want'.
  final re = RegExp(
    '$attr\\s*=\\s*["\']([^"\']+)["\']',
    caseSensitive: false,
  );
  final match = re.firstMatch(xml);
  if (match == null) return false;
  return match.group(1) == want;
}

bool _attributeEquals(String xml, String attr, String want) {
  final re = RegExp('$attr\\s*=\\s*["\']([^"\']+)["\']');
  final match = re.firstMatch(xml);
  return match != null && match.group(1) == want;
}

void main() {
  group('PR-39 Android security posture', () {
    test(
      'MOB-1: AndroidManifest <application> pins usesCleartextTraffic=false',
      () {
        final manifest = _readFile(
          'android/app/src/main/AndroidManifest.xml',
        );
        // The pin must appear on the <application> tag. We accept
        // either the lone `usesCleartextTraffic="false"` or the
        // pair with `tools:remove` (preferred — strips the
        // value when a library merges it back in).
        expect(
          _attributePresent(
            manifest,
            'application',
            'android:usesCleartextTraffic',
            'false',
          ),
          isTrue,
          reason:
              'Cyber-security MOB-1: <application> must pin '
              'usesCleartextTraffic="false" (defence-in-depth against '
              'a future library re-enabling cleartext).',
        );
      },
    );

    test(
      'MOB-1: AndroidManifest <application> declares tools:replace '
      'for usesCleartextTraffic (defence against library merge)',
      () {
        final manifest = _readFile(
          'android/app/src/main/AndroidManifest.xml',
        );
        // Sprint 9.6.10: AGP 8.11.1 + the manifest merger refuse
        // the pre-9.6.10 `tools:remove` directive when paired
        // with an explicit `android:usesCleartextTraffic="false"`
        // value ("tools:remove specified at line:63 for attribute
        // android:usesCleartextTraffic, but attribute also declared
        // at line:68, do you want to use tools:replace instead?").
        // The canonical MOB-1 cyber-security finding answer —
        // confirmed in Sprint 7 PR-39 follow-up — is to use
        // `tools:replace` instead of `tools:remove` so the merger
        // accepts the directive and our value wins on library
        // merge. Required: xmlns:tools namespace + the
        // `tools:replace` attribute on `<application>`.
        expect(
          manifest.contains('xmlns:tools'),
          isTrue,
          reason:
              'xmlns:tools must be declared on <manifest> so '
              'tools:replace can be used on <application>.',
        );
        expect(
          _attributePresent(
            manifest,
            'application',
            'tools:replace',
            'android:usesCleartextTraffic',
          ),
          isTrue,
          reason:
              'Cyber-security MOB-1 (Sprint 9.6.10 update): '
              '<application> must declare '
              'tools:replace="android:usesCleartextTraffic" so '
              'transitive libraries cannot silently re-enable '
              'cleartext. The pre-9.6.10 tools:remove form was '
              'rejected by AGP 8.11.1\'s manifest merger when '
              'paired with an explicit value; tools:replace is the '
              'canonical correct directive for "our value wins on '
              'library merge".',
        );
      },
    );

    test(
      'MOB-2: AndroidManifest <application> references the network '
      'security config resource',
      () {
        final manifest = _readFile(
          'android/app/src/main/AndroidManifest.xml',
        );
        expect(
          _attributePresent(
            manifest,
            'application',
            'android:networkSecurityConfig',
            '@xml/network_security_config',
          ),
          isTrue,
          reason:
              'Cyber-security MOB-2: <application> must reference '
              '@xml/network_security_config.',
        );
      },
    );

    test(
      'MOB-2: network_security_config.xml pins to system trust '
      'anchors only and disables cleartext',
      () {
        final cfg = _readFile(
          'android/app/src/main/res/xml/network_security_config.xml',
        );
        expect(
          _attributeEquals(cfg, 'cleartextTrafficPermitted', 'false'),
          isTrue,
          reason:
              'Network security config must declare '
              'cleartextTrafficPermitted="false" at the base config '
              'level so HTTPS is enforced for every domain.',
        );
        expect(
          cfg.contains('<certificates src="system"'),
          isTrue,
          reason:
              'Trust anchors must be `system` only — user-installed '
              'CAs (mitmproxy / Charles Proxy) must NOT be trusted.',
        );
        // Defence against accidentally re-adding user CAs.
        expect(
          cfg.contains('<certificates src="user"'),
          isFalse,
          reason:
              'Network security config must NOT trust user-installed '
              'CAs (closes the MITM-by-malicious-CA class).',
        );
      },
    );

    test(
      'MOB-3: build.gradle.kts release block enables R8/ProGuard',
      () {
        final gradleRaw = _readFile('android/app/build.gradle.kts');
        // Strip comments first — privacy / intent notes appear as
        // Kotlin line comments and we don't want to false-positive.
        final gradle = _stripComments(gradleRaw);
        // Verify the `release { ... }` buildType block exists, then
        // check the body for the R8 pins. Use a regex that
        // specifically anchors on the `getByName("release")` opener
        // and consumes up to the **closing `}` at column 0** (no
        // leading whitespace) — this avoids stopping at the
        // nested `if/else` block endings.
        final releaseBlock = RegExp(
          r'getByName\(\s*"release"\s*\)\s*\{([\s\S]*?)\n\}',
          multiLine: true,
        ).firstMatch(gradle);
        expect(
          releaseBlock,
          isNotNull,
          reason:
              'Could not find `getByName("release") { ... }` block in '
              'build.gradle.kts.',
        );
        final body = releaseBlock!.group(1) ?? '';
        expect(
          body.contains('isMinifyEnabled = true'),
          isTrue,
          reason:
              'Cyber-security MOB-3: release builds must run R8 '
              '(isMinifyEnabled = true). Disabling R8 ships full '
              'Kotlin symbol names + dev-friendly stack traces '
              '(OWASP MASVS-CODE-2 violation).',
        );
        expect(
          body.contains('isShrinkResources = true'),
          isTrue,
          reason:
              'Cyber-security MOB-3: release builds must shrink '
              'resources (isShrinkResources = true).',
        );
        expect(
          body.contains('proguardFiles('),
          isTrue,
          reason:
              'Cyber-security MOB-3: release builds must reference a '
              'project-specific proguard-rules.pro so R8 keeps the '
              'Flutter embedding + our Kotlin MethodChannels.',
        );
        expect(
          body.contains('proguard-rules.pro'),
          isTrue,
          reason:
              'Cyber-security MOB-3: proguardFiles must include the '
              'project rules file.',
        );
      },
    );

    test(
      'MOB-3: proguard-rules.pro keeps the Flutter embedding + our '
      'Kotlin sources',
      () {
        final rules = _readFile('android/app/proguard-rules.pro');
        // Flutter embedding classes must be kept.
        for (final cls in <String>[
          'io.flutter.app.**',
          'io.flutter.plugin.**',
          'io.flutter.plugins.GeneratedPluginRegistrant',
          'com.opene2ee.opene2ee.MainActivity',
          'com.opene2ee.opene2ee.vpn.OpenE2eeVpnService',
        ]) {
          expect(
            rules.contains(cls),
            isTrue,
            reason:
                'proguard-rules.pro must keep `$cls` so R8 does not '
                'strip the class the Flutter embedding or '
                'AndroidManifest reflect against.',
          );
        }
      },
    );

    test(
      'Privacy invariant (ADR-0006): AndroidManifest does not request '
      'forbidden device-identifier permissions',
      () {
        final manifestRaw = _readFile(
          'android/app/src/main/AndroidManifest.xml',
        );
        // Strip XML comments before scanning — the manifest already
        // declares in its header that these permissions are
        // deliberately omitted (per ADR-0006); we don't want the
        // declaration to false-positive the test.
        final manifest = _stripComments(manifestRaw);
        // Extract every `<uses-permission ... />` line and check
        // each `android:name` against the forbidden list.
        final permLines = RegExp(
          r'<uses-permission[^/]*/>',
        ).allMatches(manifest).map((m) => m.group(0) ?? '');
        final declared = permLines
            .map(
              (line) => RegExp(
                r'android:name\s*=\s*"([^"]+)"',
              ).firstMatch(line)?.group(1) ?? '',
            )
            .where((s) => s.isNotEmpty)
            .toSet();
        // Forbidden per ADR-0006 + STRIDE-3-01.
        for (final perm in <String>[
          'android.permission.READ_PHONE_STATE',
          'android.permission.READ_PRIVILEGED_PHONE_STATE',
          'android.permission.READ_PHONE_NUMBERS',
          'android.permission.READ_DEVICE_ID',
          'android.permission.GET_DEVICE_ID',
          'android.permission.BLUETOOTH_CONNECT',
        ]) {
          expect(
            declared.contains(perm),
            isFalse,
            reason:
                'Privacy invariant (ADR-0006): manifest must NOT '
                'request `$perm`. Declared permissions: $declared',
          );
        }
      },
    );
  });

  group('PR-39 iOS NetworkExtension Info.plist posture', () {
    test(
      'MOB-7 / STRIDE-6-01: NetworkExtension Info.plist MinimumOSVersion '
      'matches Runner (15.0)',
      () {
        final nePlist = _readFile('ios/NetworkExtension/Info.plist');
        final runnerPlist = _readFile('ios/Runner/Info.plist');
        // Extract the MinimumOSVersion <string>VALUE</string> just
        // after the <key>MinimumOSVersion</key> line.
        String pickMin(String plist) {
          final re = RegExp(
            r'<key>\s*MinimumOSVersion\s*</key>\s*<string>\s*([0-9.]+)\s*</string>',
            multiLine: true,
          );
          final m = re.firstMatch(plist);
          return m?.group(1) ?? '';
        }

        final neMin = pickMin(nePlist);
        final runnerMin = pickMin(runnerPlist);
        expect(
          neMin,
          '15.0',
          reason:
              'Cyber-security STRIDE-6-01 / AUTHZ-9 / MOB-7: NE '
              'Info.plist MinimumOSVersion must be 15.0 to match the '
              'Runner target. Mismatch caused cryptic install errors '
              'on iOS 14 devices when the extension tried to load on '
              'a host that required 15.',
        );
        expect(
          neMin,
          runnerMin,
          reason:
              'NE and Runner Info.plist MinimumOSVersion MUST match '
              '(otherwise the extension fails to install on the '
              'host\'s minimum OS).',
        );
      },
    );

    test(
      'AUTHZ-7 / AUTHZ-8: Runner Info.plist still has MinimumOSVersion '
      '15.0 and NSVPNUsageDescription',
      () {
        final runnerPlist = _readFile('ios/Runner/Info.plist');
        expect(
          RegExp(
            r'<key>\s*MinimumOSVersion\s*</key>\s*<string>\s*15\.0\s*</string>',
          ).hasMatch(runnerPlist),
          isTrue,
          reason:
              'Runner Info.plist MinimumOSVersion must remain 15.0 '
              '(deny-list `excludeAppRules` semantics require iOS 15+).',
        );
        expect(
          runnerPlist.contains('NSVPNUsageDescription'),
          isTrue,
          reason:
              'Runner Info.plist must declare NSVPNUsageDescription '
              '(required by Apple for any app that establishes a '
              'VPN connection).',
        );
      },
    );
  });
}