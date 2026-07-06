# OpenE2EE iOS Xcode Project Structure — PR-29 Follow-up (Sprint 5)

This document is the **single source of truth** for the PR-29 changes to
`mobile/ios/Runner.xcodeproj/project.pbxproj` + the new
`Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme`. It is the
follow-up to `docs/ios/xcodeproj-structure.md` (PR-25) and tracks the
three batches:

- **A.** RunnerTests Xcode wire (Sprint 3 §10)
- **B.** Keychain master (Sprint 4 §11)
- **C.** iOS 15+ deployment-target bump

## Targets

| Target                     | Product                            | Bundle ID                         | Product type                              | Notes                          |
| -------------------------- | ---------------------------------- | --------------------------------- | ----------------------------------------- | ------------------------------ |
| `Runner`                   | `Runner.app`                       | `com.opene2ee.opene2ee`           | `com.apple.product-type.application`      | (PR-25 — unchanged)            |
| `OpenE2eeTunnelProvider`   | `OpenE2eeTunnelProvider.appex`     | `com.opene2ee.opene2ee.tunnel`    | `com.apple.product-type.app-extension`    | (PR-25 — unchanged)            |
| `RunnerTests`              | `RunnerTests.xctest`               | `com.opene2ee.opene2ee.RunnerTests` | `com.apple.product-type.bundle.unit-test` | **NEW in PR-29**               |

`RunnerTests` is a **unit-test target** that:

1. Has `OpenE2eeTunnelProviderTests.swift` in its Compile Sources phase.
2. Has `Runner.app` as its **host application** (proxyType=2 dependency).
3. Has `OpenE2eeTunnelProvider.appex` as a build dependency (proxyType=1)
   so `@testable import OpenE2eeTunnelProvider` resolves at link time.
4. Uses `TEST_HOST = $(BUILT_PRODUCTS_DIR)/Runner.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Runner`
   and `BUNDLE_LOADER = $(TEST_HOST)` in its build settings.

`Runner` has a build dependency on `RunnerTests` so the test bundle is
always built alongside the app, even outside the scheme-driven flow
(e.g. `xcodebuild build -target Runner`).

## Runner scheme test action

`Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` is now
**committed to git** (PR-29). Previously it lived only in the local
Xcode user data dir; a macOS dev who pulled the repo would have had to
re-create it on first open. The committed scheme has:

- **BuildAction** with two entries:
  - `Runner` (buildForRunning + buildForTesting + buildForProfiling +
    buildForArchiving + buildForAnalyzing).
  - `RunnerTests` (buildForTesting only).
- **TestAction** with one `<Testables>` entry pointing at
  `RunnerTests.xctest`.
- **LaunchAction** for `Runner.app`.

The Xcode-generated convention is preserved (`LastUpgradeVersion=1500`,
`version="1.7"`, etc.) so a macOS dev opening the project will NOT see
UUID churn or version drift.

## Keychain master (Sprint 4 §11)

`mobile/ios/NetworkExtension/OpenE2eeTunnelProvider.swift` no longer uses
the Sprint 3 `kVpnIosSprint3Master` literal to derive the per-session
HKDF master. Instead, `loadMasterKeyFromKeychain()` (a new static helper
on `OpenE2eeTunnelProvider`) does:

1. `SecItemCopyMatching` with:
   - `kSecClass = kSecClassKey`
   - `kSecAttrApplicationTag = "opene2ee.ios.vpn.master"`
   - `kSecAttrKeyClass = kSecAttrKeyClassSymmetric`
   - `kSecAttrKeySizeInBits = 256`
   - `kSecReturnData = true`
   - `kSecMatchLimit = kSecMatchLimitOne`
   - `kSecAttrAccessGroup = "group.com.opene2ee.opene2ee"` on real devices
     (gated `#if !targetEnvironment(simulator)` because the iOS Simulator
     does not honor the Runner App Group entitlement).
2. If the lookup misses (`errSecItemNotFound`), seed the Keychain via
   `SecItemAdd` with the same deterministic
   `SHA256("opene2ee/ios/v1/master")` so a fresh install produces the
   same 32-byte master that Sprint 3 hard-coded. `errSecDuplicateItem`
   is treated as success (both seeders produce the same bytes).
3. Real failures (`errSecAuthFailed`, `errSecParam`, disk-full, etc.)
   bubble up as `NSError` with the `OpenE2EE.VPN.Keychain` domain;
   `startTunnel` surfaces them through the existing
   `transition(to: .error)` path.

The deprecated `kVpnIosSprint3Master` constant is preserved (annotated
`@available(*, deprecated, ...)`) so audit tools can grep the audit
trail across the migration boundary. The §6 review feedback remains
referenced verbatim in the deprecation comment.

## iOS 15+ deployment target (Sprint 5 §C)

`mobile/ios/Runner/Info.plist`:
- `MinimumOSVersion`: `14.0` → `15.0`.

`mobile/ios/Runner.xcodeproj/project.pbxproj`:
- Both project-level `XCBuildConfiguration`s (Debug `H1` + Release
  `H2`) have `IPHONEOS_DEPLOYMENT_TARGET = 15.0`.
- The new `RunnerTests` target's Debug `H7` and Release `H8` configs
  also pin `IPHONEOS_DEPLOYMENT_TARGET = 15.0`.

`mobile/ios/Runner/AppDelegate.swift` (`applyPerAppRules`):
- The outer `if #available(iOS 14.0, *) { ... } else { ... }` guard is
  removed; the deployment target is iOS 15+ so the inner branch is
  always reachable.
- The inner `if #available(iOS 15.0, *) { ... } else { ... }` deny-list
  fallback (`ios14-fallback-tunnel-all` NSLog breadcrumb) is also
  removed — `proto.excludeAppRules` is the canonical deny-list path on
  iOS 15+, no fallback needed.
- The pre-iOS 14 unreachable trailing `else` (`proto.providerConfiguration = [:]`) is
  removed.

The Sprint 3 contract is preserved: `proto.includeAllNetworks = false`,
`proto.excludeLocalNetworks = true`, and the empty-rules branch sets
`providerConfiguration = [:]`. Per-app VPN continues to cover exactly
the bundle-ids Dart sends — never the inverse.

## UUIDs (PR-29 additions)

| Object                          | UUID (deterministic)           | Section                                                |
| ------------------------------- | ------------------------------ | ------------------------------------------------------ |
| `RunnerTests` PBXNativeTarget   | `A100000000000000000000F7`     | `/* Begin PBXNativeTarget section */`                  |
| `RunnerTests` PBXGroup          | `A100000000000000000000G5`     | `/* Begin PBXGroup section */`                         |
| RunnerTests Sources phase       | `A100000000000000000000AF`     | `/* Begin PBXSourcesBuildPhase section */`             |
| RunnerTests Frameworks phase    | `A100000000000000000000B0`     | `/* Begin PBXFrameworksBuildPhase section */`          |
| RunnerTests Resources phase     | `A100000000000000000000B9`     | `/* Begin PBXResourcesBuildPhase section */`           |
| RunnerTests XCConfigList        | `A100000000000000000000F6`     | `/* Begin XCConfigurationList section */`              |
| RunnerTests Debug XCBuildConfig | `A100000000000000000000H7`     | `/* Begin XCBuildConfiguration section */`             |
| RunnerTests Release XCBuildConfig| `A100000000000000000000H8`    | `/* Begin XCBuildConfiguration section */`             |
| RunnerTests.xctest PBXFileReference | `A100000000000000000000C3`| `/* Begin PBXFileReference section */`                 |
| OpenE2eeTunnelProviderTests.swift PBXFileReference | `A100000000000000000000B7` | `/* Begin PBXFileReference section */` |
| OpenE2eeTunnelProviderTests.swift PBXBuildFile | `A100000000000000000000AE` | `/* Begin PBXBuildFile section */`        |
| RunnerTests.xctest PBXContainerItemProxy → Runner (host) | `A100000000000000000000D4` | `/* Begin PBXContainerItemProxy section */` |
| RunnerTests NE build proxy       | `A100000000000000000000D3`     | `/* Begin PBXContainerItemProxy section */`            |
| Runner→RunnerTests build proxy  | `A100000000000000000000D2`     | `/* Begin PBXContainerItemProxy section */`            |
| RunnerTests→Runner host dep     | `A100000000000000000000BB`     | `/* Begin PBXTargetDependency section */`              |
| RunnerTests→NE build dep        | `A100000000000000000000BC`     | `/* Begin PBXTargetDependency section */`              |
| Runner→RunnerTests build dep    | `A100000000000000000000BA`     | `/* Begin PBXTargetDependency section */`              |

`F3` is intentionally left as the XCConfigurationList UUID for the
existing Runner target — it was already taken in PR-25. The new
`RunnerTests` native target uses `F7`.

## macOS validation path

Once the macOS dev opens `mobile/ios/Runner.xcodeproj` in Xcode 15+:

1. The committed scheme (`xcshareddata/xcschemes/Runner.xcscheme`) is
   picked up automatically — no scheme re-creation needed.
2. **Build**: `xcodebuild -workspace Runner.xcworkspace -scheme Runner
   -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone
   15' build` compiles all three targets.
3. **Test**: `xcodebuild test -scheme Runner -destination
   'platform=iOS Simulator,name=iPhone 15'` runs the 9 XCTest cases
   from `OpenE2eeTunnelProviderTests.swift`.

If Xcode re-rolls any UUIDs on first save, the diff is acceptable churn
(UUID churn is normal). The file structure must match the table above.

## Static-validation checklist (24 PR-29 checks)

Run `bash scripts/ios/verify-xcodeproj.sh` on macOS or
`powershell -ExecutionPolicy Bypass -File scripts/ios/verify-xcodeproj.ps1`
on Windows. The script runs the 9 PR-25 baseline checks plus the
24 PR-29 follow-up checks (A: RunnerTests Xcode wire, B: Keychain
master, C: iOS 15+ bump). On a PR-29-only file the expected output is:

```
=== PR-25 iOS Xcode project static-validation ===
  ... 9 passed

=== PR-29 iOS Xcode project static-validation (follow-up) ===
  ... 24 passed

=== Results: 33 passed, 0 failed ===
All static-validation checks passed.
```

(Actual numbering: PR-29 has 8 top-level checks `[9/16]` through
`[16/16]` with multiple sub-assertions per check — the count is 24
sub-assertions, but the script reports each sub-check as a single PASS.)
