// mobile/android/build.gradle.kts
//
// PR-28 (Sprint 5) — root project build script.
//
// Minimal — Flutter's Android module is fully configured in
// `app/build.gradle.kts`. We only need to declare the plugin versions
// in one place (so `subprojects { ... }` can re-use them) and pin the
// repositories used for transitive resolution.

plugins {
    // Applied in subprojects via the `id("...")` shorthand in their own
    // `plugins {}` block. Versions are declared HERE so the AGP /
    // Kotlin / Flutter plugin loaders agree.
    id("com.android.application") version "8.1.4" apply false
    id("org.jetbrains.kotlin.android") version "1.9.22" apply false
    id("dev.flutter.flutter-gradle-plugin") version "1.0.0" apply false
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// Sub-projects inherit the JVM target (AGP requires Java 17 for 8.1+).
subprojects {
    afterEvaluate {
        // No-op stub — populated if/when we add Kotlin-only modules.
    }
}