#!/usr/bin/env bash
#
# verify-xcodeproj.sh — PR-25 + PR-29 static-validation gate.
#
# Runs the 9 PR-25 baseline checks plus 24 PR-29 follow-up checks
# documented in docs/ios/xcodeproj-structure.md (PR-25) +
# docs/ios/xcodeproj-structure-pr29.md (PR-29). Used by CI on
# non-macOS runners where Xcode is unavailable; the macOS job runs the
# same checks via `xcodebuild -showBuildSettings` plus a
# `xcodebuild build` / `xcodebuild test -scheme Runner` to validate
# the actual build, not just the structure.
#
# Usage:
#   bash scripts/ios/verify-xcodeproj.sh [PROJECT_ROOT]
#
# Default PROJECT_ROOT is the repo root (one level up from this script).

set -euo pipefail

PROJECT_ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
PBXPROJ="$PROJECT_ROOT/mobile/ios/Runner.xcodeproj/project.pbxproj"
APPDELEGATE="$PROJECT_ROOT/mobile/ios/Runner/AppDelegate.swift"
RUNNER_INFO_PLIST="$PROJECT_ROOT/mobile/ios/Runner/Info.plist"
NE_PROVIDER_SWIFT="$PROJECT_ROOT/mobile/ios/NetworkExtension/OpenE2eeTunnelProvider.swift"
RUNNER_XCSCHEME="$PROJECT_ROOT/mobile/ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme"
NE_ENT="$PROJECT_ROOT/mobile/ios/NetworkExtension/OpenE2eeTunnelProvider.entitlements"
NE_INFO_PLIST="$PROJECT_ROOT/mobile/ios/NetworkExtension/Info.plist"

if [[ ! -f "$PBXPROJ" ]]; then
    echo "FATAL: $PBXPROJ not found"
    exit 1
fi

fail_count=0
pass_count=0

check() {
    local name="$1"
    local pattern="$2"
    local file="$3"
    local expected="$4"
    local actual
    actual=$(grep -cE "$pattern" "$file" || true)
    if [[ "$actual" -ge "$expected" ]]; then
        echo "  PASS  $name (found $actual >= $expected)"
        pass_count=$((pass_count + 1))
    else
        echo "  FAIL  $name (found $actual < $expected)"
        fail_count=$((fail_count + 1))
    fi
}

check_one() {
    local name="$1"
    local pattern="$2"
    local file="$3"
    local expected="$4"
    local actual
    actual=$(grep -cE "$pattern" "$file" || true)
    if [[ "$actual" -eq "$expected" ]]; then
        echo "  PASS  $name (found $actual == $expected)"
        pass_count=$((pass_count + 1))
    else
        echo "  FAIL  $name (found $actual != $expected)"
        fail_count=$((fail_count + 1))
    fi
}

check_path() {
    local name="$1"
    local file="$2"
    if [[ -e "$file" ]]; then
        echo "  PASS  $name"
        pass_count=$((pass_count + 1))
    else
        echo "  FAIL  $name (file not found: $file)"
        fail_count=$((fail_count + 1))
    fi
}

echo "=== PR-25 iOS Xcode project static-validation ==="
echo "  PROJECT_ROOT: $PROJECT_ROOT"
echo

echo "[1/8] NE target .appex exists in pbxproj"
check "1. NE target exists" 'OpenE2eeTunnelProvider\.appex' "$PBXPROJ" 4

echo "[2/8] NE source in Compile Sources"
# The PBXBuildFile entry + the Sources-phase listing both reference
# "in Sources" — both are required. Expect >= 2.
check "2. NE source in Compile Sources" 'OpenE2eeTunnelProvider\.swift in Sources' "$PBXPROJ" 2

echo "[3/8] Embed App Extensions build phase on Runner"
check "3. Embed App Extensions build phase" 'Embed App Extensions' "$PBXPROJ" 3

echo "[4/8] NE entitlements referenced in pbxproj"
check_one "4. NE entitlements referenced" 'CODE_SIGN_ENTITLEMENTS = NetworkExtension/OpenE2eeTunnelProvider\.entitlements' "$PBXPROJ" 2

echo "[5/8] Tunnel bundle id in pbxproj"
check_one "5. Tunnel bundle id" 'PRODUCT_BUNDLE_IDENTIFIER = com\.opene2ee\.opene2ee\.tunnel' "$PBXPROJ" 2

echo "[6/8] AppDelegate.tunnelBundleId matches NE bundle id"
check_one "6. tunnelBundleId in AppDelegate" 'tunnelBundleId = "com\.opene2ee\.opene2ee\.tunnel"' "$APPDELEGATE" 1

echo "[7/8] NE entitlements contain packet-tunnel-provider + allow-vpn"
check "7a. packet-tunnel-provider in NE entitlements" 'packet-tunnel-provider' "$NE_ENT" 1
check "7b. allow-vpn in NE entitlements" 'allow-vpn' "$NE_ENT" 1

echo "[8/8] NE Info.plist has packet-tunnel extension point"
# The string appears in comments AND in the actual plist string value.
# Match only plist string lines (inside <string>...</string>) to avoid
# comment noise. Expect exactly 1.
check_one "8. NE Info.plist extension point" '<string>com\.apple\.networkextension\.packet-tunnel</string>' "$NE_INFO_PLIST" 1

echo
echo "=== PR-29 iOS Xcode project static-validation (follow-up) ==="
echo

echo "[9/16] RunnerTests target exists in pbxproj"
check "9a. Native targets declared (Runner + NE + RunnerTests)" 'isa = PBXNativeTarget;' "$PBXPROJ" 3
check "9b. unit-test productType" 'com\.apple\.product-type\.bundle\.unit-test' "$PBXPROJ" 1
check "9c. RunnerTests.xctest file ref" 'RunnerTests\.xctest' "$PBXPROJ" 3

echo "[10/16] OpenE2eeTunnelProviderTests.swift in RunnerTests Sources phase"
check "10a. test file Compile Sources entry" 'OpenE2eeTunnelProviderTests\.swift in Sources' "$PBXPROJ" 1
check "10b. 3 Sources phases (Runner + NE + RunnerTests)" 'isa = PBXSourcesBuildPhase;' "$PBXPROJ" 3

echo "[11/16] RunnerTests dependencies (Runner host + NE target)"
check "11a. RunnerTests has proxyType=2 host proxy to Runner" 'proxyType = 2;' "$PBXPROJ" 1
check "11b. Two PBXContainerItemProxy entries to NE" 'remoteInfo = OpenE2eeTunnelProvider;' "$PBXPROJ" 2
check "11c. PBXTargetDependency Runner -> RunnerTests (D2)" 'targetProxy = A100000000000000000000D2 /\* PBXContainerItemProxy \*/;' "$PBXPROJ" 1

echo "[12/16] Runner.xcscheme has TestAction + RunnerTests testable reference"
check_path "12a. Runner.xcscheme file exists" "$RUNNER_XCSCHEME"
check "12b. Runner.xcscheme TestAction" '<TestAction' "$RUNNER_XCSCHEME" 1
check "12c. Runner.xcscheme Testables block" '<Testables>' "$RUNNER_XCSCHEME" 1
check "12d. Runner.xcscheme RunnerTests references" 'RunnerTests' "$RUNNER_XCSCHEME" 3

echo "[13/16] kVpnIosSprint3Master placeholder is deprecated"
check "13a. @available deprecated marker" '@available\(\*, deprecated' "$NE_PROVIDER_SWIFT" 1
check_one "13b. one deprecated placeholder constant" 'private let kVpnIosSprint3Master' "$NE_PROVIDER_SWIFT" 1
check "13c. placeholder referenced in audit trail (>=3 mentions)" 'kVpnIosSprint3Master' "$NE_PROVIDER_SWIFT" 3

echo "[14/16] loadMasterKeyFromKeychain uses kSecClassKey + kSecAttrApplicationTag"
check "14a. kSecClassKey lookup + add" 'kSecClass as String: kSecClassKey' "$NE_PROVIDER_SWIFT" 2
check_one "14b. application tag is opene2ee.ios.vpn.master" 'kVpnIosKeychainApplicationTag = "opene2ee\.ios\.vpn\.master"' "$NE_PROVIDER_SWIFT" 1
check "14c. SecItemCopyMatching + SecItemAdd used" 'SecItem(CopyMatching|Add)\(' "$NE_PROVIDER_SWIFT" 2
check_one "14d. access group matches entitlements" 'kVpnIosKeychainAccessGroup = "group\.com\.opene2ee\.opene2ee"' "$NE_PROVIDER_SWIFT" 1
check_one "14e. deriveSessionKey calls loadMasterKeyFromKeychain" 'let master = try Self\.loadMasterKeyFromKeychain\(\)' "$NE_PROVIDER_SWIFT" 1

echo "[15/16] Info.plist MinimumOSVersion bumped to 15.0"
check_one "15a. MinimumOSVersion = 15.0" '<string>15\.0</string>' "$RUNNER_INFO_PLIST" 1

echo "[16/16] pbxproj IPHONEOS_DEPLOYMENT_TARGET bumped to 15.0"
check "16a. IPHONEOS_DEPLOYMENT_TARGET = 15.0 (>=3 occurrences: project Debug + Release + RunnerTests)" 'IPHONEOS_DEPLOYMENT_TARGET = 15\.0;' "$PBXPROJ" 3
check_one "16b. iOS 14 deny-list NSLog breadcrumb is gone" 'ios14-fallback-tunnel-all' "$APPDELEGATE" 0
check_one "16c. Runner test bundle id follows com.opene2ee.opene2ee.RunnerTests (Debug + Release configs)" 'PRODUCT_BUNDLE_IDENTIFIER = com\.opene2ee\.opene2ee\.RunnerTests;' "$PBXPROJ" 2

echo
echo "=== Results: $pass_count passed, $fail_count failed ==="
if [[ "$fail_count" -gt 0 ]]; then
    echo "STATIC VALIDATION FAILED — see docs/ios/xcodeproj-structure-pr29.md for the expected layout."
    exit 1
fi
echo "All static-validation checks passed."
