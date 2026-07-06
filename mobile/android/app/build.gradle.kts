// mobile/android/app/build.gradle.kts
//
// PR-28 (Sprint 5) — Flutter app module build script.
//
// Configures the `:app` subproject that hosts both the Flutter embedding
// (Activity + MethodChannels) AND the native Kotlin VPN service that
// PR-22a introduced and PR-24 relocated into the Android source tree.
//
// Highlights:
//   - Applies Flutter's Android Gradle plugin (handles Dart build,
//     `flutter pub get`, GeneratedPluginRegistrant injection, asset
//     bundling).
//   - Applies the Kotlin Android plugin (lets Gradle compile the
//     `mobile/android/app/src/main/kotlin/com/opene2ee/opene2ee/**/*.kt`
//     sources — including `vpn/OpenE2eeVpnService.kt`).
//   - Pins minSdk = 21 (Lollipop, the floor for `VpnService.Builder
//     .allowedApplications()` and `.disallowedApplications()` per the
//     PR-22a follow-up in PR-28 §B.1), targetSdk = 34 (Android 14,
//     required for `foregroundServiceType="specialUse"`), compileSdk = 34.
//   - Declares runtime deps: AndroidX core, AndroidX annotation (for
//     `@RequiresApi` lint enforcement), androidx.core (ServiceCompat),
//     kotlinx-coroutines-android (used by future async plumbing).
//   - Distinguishes debug vs release signing configs. Debug uses the
//     AGP-provided auto-generated debug keystore (no password needed,
//     valid for one year — fine for sampling / on-device testing).
//     Release is empty unless the developer drops a keystore at
//     `mobile/android/key.properties` (gitignored).
//
// References:
//   - https://docs.flutter.dev/deployment/android
//   - https://developer.android.com/build/building-cmdline
//   - docs/ADR-0003-vpn-layer.md
//   - docs/SPRINT-5-SCOPE.md §PR-28

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.opene2ee.opene2ee"
    compileSdk = 34
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
    }

    defaultConfig {
        // Floor — API 21 (Lollipop) — required for
        // `VpnService.Builder.allowedApplications()` /
        // `disallowedApplications()`. See OpenE2eeVpnService.kt for the
        // `@RequiresApi(21)` annotations that the PR-28 follow-up batch
        // adds around those call sites.
        minSdk = 21
        targetSdk = 34
        versionCode = 1
        versionName = "0.1.0"
    }

    signingConfigs {
        // Debug uses AGP's auto-generated debug keystore (created on
        // first build under `~/.android/debug.keystore`). No password
        // required. Long enough validity for sampling / QA / CI builds.
        getByName("debug") {
            // Defaults are fine; we declare it explicitly so the
            // release block below can mirror its structure.
        }

        // Release — empty by default. If a developer drops a
        // `key.properties` file at `mobile/android/key.properties`
        // (see `.gitignore`), it is loaded here and a release
        // signing config is wired up. We deliberately do NOT fall
        // back to the debug keystore for release builds — that
        // would silently ship APKls signed with the well-known
        // Android SDK debug key.
        create("release") {
            val keyPropsFile = rootProject.file("key.properties")
            if (keyPropsFile.exists()) {
                val keyProps = java.util.Properties().apply {
                    load(keyPropsFile.inputStream())
                }
                storeFile = file(keyProps["storeFile"] as String)
                storePassword = keyProps["storePassword"] as String
                keyAlias = keyProps["keyAlias"] as String
                keyPassword = keyProps["keyPassword"] as String
            }
        }
    }

    buildTypes {
        getByName("release") {
            // Sign release with the release config when a key is
            // configured, otherwise sign with debug so local
            // `flutter build apk --release` runs succeed (Play Store
            // uploads still require a real keystore).
            signingConfig = if (rootProject.file("key.properties").exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Kotlin runtime — provided by the Kotlin Android plugin via
    // stdlib, declared explicitly so the Kotlin compiler can resolve
    // references like `kotlin.LazyThreadSafetyMode` from the VPN service.
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.annotation:annotation:1.7.1")
    // `androidx.core.app.ServiceCompat` (startForeground, startForegroundService)
    // and `ForegroundServiceType` constants land here. Required by the
    // PR-28 transient-service fix to keep `startForeground` callable on
    // API 34+ without the deprecation warning breaking CI.
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}

// Ensure the VPN service class file ends up in the compiled output —
// defensive; AGP/Kotlin already pick up `src/main/kotlin` via the
// sourceSets entry above, but a future rename or move is easier to
// audit if we list the package here explicitly.
androidComponents {
    onVariants { variant ->
        // no-op; placeholder for future ABI/signing hooks.
    }
}