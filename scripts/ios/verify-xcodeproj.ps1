# verify-xcodeproj.ps1 — PR-25 + PR-29 static-validation gate (PowerShell).
#
# Windows / non-bash counterpart of verify-xcodeproj.sh. Runs the 8 PR-25
# baseline checks plus 8 PR-29 follow-up checks (RunnerTests Xcode wiring,
# Keychain master fetch, iOS 15+ deployment-target bump). Documented in
# docs/ios/xcodeproj-structure.md (PR-25) +
# docs/ios/xcodeproj-structure-pr29.md (PR-29). Used by CI on Windows
# runners where bash is unavailable.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/ios/verify-xcodeproj.ps1 [-ProjectRoot <path>]

[CmdletBinding()]
param(
    [string]$ProjectRoot
)

if (-not $ProjectRoot) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ProjectRoot = (Resolve-Path "$scriptDir/../..").Path
}

$ErrorActionPreference = 'Stop'

$Pbxproj = Join-Path $ProjectRoot 'mobile/ios/Runner.xcodeproj/project.pbxproj'
$AppDelegate = Join-Path $ProjectRoot 'mobile/ios/Runner/AppDelegate.swift'
$RunnerInfoPlist = Join-Path $ProjectRoot 'mobile/ios/Runner/Info.plist'
$NeProviderSwift = Join-Path $ProjectRoot 'mobile/ios/NetworkExtension/OpenE2eeTunnelProvider.swift'
$RunnerXcscheme = Join-Path $ProjectRoot 'mobile/ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme'
$NeEntitlements = Join-Path $ProjectRoot 'mobile/ios/NetworkExtension/OpenE2eeTunnelProvider.entitlements'
$NeInfoPlist = Join-Path $ProjectRoot 'mobile/ios/NetworkExtension/Info.plist'

if (-not (Test-Path $Pbxproj)) {
    Write-Host "FATAL: $Pbxproj not found"
    exit 1
}

$failCount = 0
$passCount = 0

function Test-GrepAtLeast {
    param(
        [string]$Name,
        [string]$Pattern,
        [string]$Path,
        [int]$Expected
    )
    $count = (Select-String -Path $Path -Pattern $Pattern -AllMatches | Measure-Object).Count
    if ($count -ge $Expected) {
        Write-Host "  PASS  $Name (found $count >= $Expected)"
        $script:passCount++
    } else {
        Write-Host "  FAIL  $Name (found $count < $Expected)"
        $script:failCount++
    }
}

function Test-GrepExactly {
    param(
        [string]$Name,
        [string]$Pattern,
        [string]$Path,
        [int]$Expected
    )
    $count = (Select-String -Path $Path -Pattern $Pattern -AllMatches | Measure-Object).Count
    if ($count -eq $Expected) {
        Write-Host "  PASS  $Name (found $count == $Expected)"
        $script:passCount++
    } else {
        Write-Host "  FAIL  $Name (found $count != $Expected)"
        $script:failCount++
    }
}

function Test-PathExists {
    param(
        [string]$Name,
        [string]$Path
    )
    if (Test-Path $Path) {
        Write-Host "  PASS  $Name"
        $script:passCount++
    } else {
        Write-Host "  FAIL  $Name (file not found: $Path)"
        $script:failCount++
    }
}

Write-Host '=== PR-25 iOS Xcode project static-validation ==='
Write-Host "  PROJECT_ROOT: $ProjectRoot"
Write-Host ''

Write-Host '[1/8] NE target .appex exists in pbxproj'
Test-GrepAtLeast -Name '1. NE target exists' -Pattern 'OpenE2eeTunnelProvider\.appex' -Path $Pbxproj -Expected 4

Write-Host '[2/8] NE source in Compile Sources'
# The PBXBuildFile entry + the Sources-phase listing both reference
# "in Sources" — both are required. Expect >= 2.
Test-GrepAtLeast -Name '2. NE source in Compile Sources' -Pattern 'OpenE2eeTunnelProvider\.swift in Sources' -Path $Pbxproj -Expected 2

Write-Host '[3/8] Embed App Extensions build phase on Runner'
Test-GrepAtLeast -Name '3. Embed App Extensions build phase' -Pattern 'Embed App Extensions' -Path $Pbxproj -Expected 3

Write-Host '[4/8] NE entitlements referenced in pbxproj'
Test-GrepExactly -Name '4. NE entitlements referenced' -Pattern 'CODE_SIGN_ENTITLEMENTS = NetworkExtension/OpenE2eeTunnelProvider\.entitlements' -Path $Pbxproj -Expected 2

Write-Host '[5/8] Tunnel bundle id in pbxproj'
Test-GrepExactly -Name '5. Tunnel bundle id' -Pattern 'PRODUCT_BUNDLE_IDENTIFIER = com\.opene2ee\.opene2ee\.tunnel' -Path $Pbxproj -Expected 2

Write-Host '[6/8] AppDelegate.tunnelBundleId matches NE bundle id'
Test-GrepExactly -Name '6. tunnelBundleId in AppDelegate' -Pattern 'tunnelBundleId = "com\.opene2ee\.opene2ee\.tunnel"' -Path $AppDelegate -Expected 1

Write-Host '[7/8] NE entitlements contain packet-tunnel-provider + allow-vpn'
Test-GrepAtLeast -Name '7a. packet-tunnel-provider in NE entitlements' -Pattern 'packet-tunnel-provider' -Path $NeEntitlements -Expected 1
Test-GrepAtLeast -Name '7b. allow-vpn in NE entitlements' -Pattern 'allow-vpn' -Path $NeEntitlements -Expected 1

Write-Host '[8/8] NE Info.plist has packet-tunnel extension point'
# The string appears in comments AND in the actual plist string value.
# Match only plist string lines (inside <string>...</string>) to avoid
# comment noise. Expect exactly 1.
Test-GrepExactly -Name '8. NE Info.plist extension point' -Pattern '<string>com\.apple\.networkextension\.packet-tunnel</string>' -Path $NeInfoPlist -Expected 1

Write-Host ''
Write-Host '=== PR-29 iOS Xcode project static-validation (follow-up) ==='
Write-Host ''

Write-Host '[9/16] RunnerTests target exists in pbxproj'
Test-GrepAtLeast -Name '9a. Native targets declared (Runner + NE + RunnerTests)' -Pattern 'isa = PBXNativeTarget;' -Path $Pbxproj -Expected 3
Test-GrepAtLeast -Name '9b. unit-test productType' -Pattern 'com\.apple\.product-type\.bundle\.unit-test' -Path $Pbxproj -Expected 1
Test-GrepAtLeast -Name '9c. RunnerTests.xctest file ref' -Pattern 'RunnerTests\.xctest' -Path $Pbxproj -Expected 3

Write-Host '[10/16] OpenE2eeTunnelProviderTests.swift in RunnerTests Sources phase'
Test-GrepAtLeast -Name '10a. test file Compile Sources entry' -Pattern 'OpenE2eeTunnelProviderTests\.swift in Sources' -Path $Pbxproj -Expected 1
Test-GrepAtLeast -Name '10b. 3 Sources phases (Runner + NE + RunnerTests)' -Pattern 'isa = PBXSourcesBuildPhase;' -Path $Pbxproj -Expected 3

Write-Host '[11/16] RunnerTests dependencies (Runner host + NE target)'
Test-GrepAtLeast -Name '11a. RunnerTests has proxyType=2 host proxy to Runner' -Pattern 'proxyType = 2;' -Path $Pbxproj -Expected 1
Test-GrepAtLeast -Name '11b. Two PBXContainerItemProxy entries to NE' -Pattern 'remoteInfo = OpenE2eeTunnelProvider;' -Path $Pbxproj -Expected 2
Test-GrepAtLeast -Name '11c. PBXTargetDependency Runner -> RunnerTests (D2)' -Pattern 'targetProxy = A100000000000000000000D2 /\* PBXContainerItemProxy \*/;' -Path $Pbxproj -Expected 1

Write-Host '[12/16] Runner.xcscheme has TestAction + RunnerTests testable reference'
Test-PathExists -Name '12a. Runner.xcscheme file exists' -Path $RunnerXcscheme
Test-GrepAtLeast -Name '12b. Runner.xcscheme TestAction' -Pattern '<TestAction' -Path $RunnerXcscheme -Expected 1
Test-GrepAtLeast -Name '12c. Runner.xcscheme Testables block' -Pattern '<Testables>' -Path $RunnerXcscheme -Expected 1
Test-GrepAtLeast -Name '12d. Runner.xcscheme RunnerTests references' -Pattern 'RunnerTests' -Path $RunnerXcscheme -Expected 3

Write-Host '[13/16] kVpnIosSprint3Master placeholder is deprecated'
Test-GrepAtLeast -Name '13a. @available deprecated marker' -Pattern '@available\(\*, deprecated' -Path $NeProviderSwift -Expected 1
Test-GrepExactly -Name '13b. one deprecated placeholder constant' -Pattern 'private let kVpnIosSprint3Master' -Path $NeProviderSwift -Expected 1
Test-GrepAtLeast -Name '13c. placeholder referenced in audit trail (>=3 mentions)' -Pattern 'kVpnIosSprint3Master' -Path $NeProviderSwift -Expected 3

Write-Host '[14/16] loadMasterKeyFromKeychain uses kSecClassKey + kSecAttrApplicationTag'
Test-GrepAtLeast -Name '14a. kSecClassKey lookup + add' -Pattern 'kSecClass as String: kSecClassKey' -Path $NeProviderSwift -Expected 2
Test-GrepExactly -Name '14b. application tag is opene2ee.ios.vpn.master' -Pattern 'kVpnIosKeychainApplicationTag = "opene2ee\.ios\.vpn\.master"' -Path $NeProviderSwift -Expected 1
Test-GrepAtLeast -Name '14c. SecItemCopyMatching + SecItemAdd used' -Pattern 'SecItem(CopyMatching|Add)\(' -Path $NeProviderSwift -Expected 2
Test-GrepExactly -Name '14d. access group matches entitlements' -Pattern 'kVpnIosKeychainAccessGroup = "group\.com\.opene2ee\.opene2ee"' -Path $NeProviderSwift -Expected 1
Test-GrepExactly -Name '14e. deriveSessionKey calls loadMasterKeyFromKeychain' -Pattern 'let master = try Self\.loadMasterKeyFromKeychain\(\)' -Path $NeProviderSwift -Expected 1

Write-Host '[15/16] Info.plist MinimumOSVersion bumped to 15.0'
Test-GrepExactly -Name '15a. MinimumOSVersion = 15.0' -Pattern '<string>15\.0</string>' -Path $RunnerInfoPlist -Expected 1

Write-Host '[16/16] pbxproj IPHONEOS_DEPLOYMENT_TARGET bumped to 15.0'
Test-GrepAtLeast -Name '16a. IPHONEOS_DEPLOYMENT_TARGET = 15.0 (>=3 occurrences: project Debug + Release + RunnerTests)' -Pattern 'IPHONEOS_DEPLOYMENT_TARGET = 15\.0;' -Path $Pbxproj -Expected 3
Test-GrepExactly -Name '16b. iOS 14 deny-list NSLog breadcrumb is gone' -Pattern 'ios14-fallback-tunnel-all' -Path $AppDelegate -Expected 0
Test-GrepExactly -Name '16c. Runner test bundle id follows com.opene2ee.opene2ee.RunnerTests (Debug + Release configs)' -Pattern 'PRODUCT_BUNDLE_IDENTIFIER = com\.opene2ee\.opene2ee\.RunnerTests;' -Path $Pbxproj -Expected 2

Write-Host ''
Write-Host "=== Results: $passCount passed, $failCount failed ==="
if ($failCount -gt 0) {
    Write-Host 'STATIC VALIDATION FAILED — see docs/ios/xcodeproj-structure-pr29.md for the expected layout.'
    exit 1
}
Write-Host 'All static-validation checks passed.'
exit 0
