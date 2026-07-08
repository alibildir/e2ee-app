// mobile/android/build.gradle.kts
//
// PR-28 (Sprint 5) — root project build script.
// Sprint 9.6.4 hotfix: AGP 8.1.4 → 8.6.1 (Flutter SDK 3.44.1 minimum).
// Sprint 9.6.5 hotfix: AGP 8.6.1 → 8.11.1 + Kotlin 1.9.22 → 2.2.20
//   (Flutter 3.44.1 soon-dropped floors for both).
//
// Minimal — Flutter's Android module is fully configured in
// `app/build.gradle.kts`. We only need to declare the plugin versions
// in one place (so `subprojects { ... }` can re-use them) and pin the
// repositories used for transitive resolution.

plugins {
    // Applied in subprojects via the `id("...")` shorthand in their own
    // `plugins {}` block. Versions are declared HERE so the AGP /
    // Kotlin / Flutter plugin loaders agree.
    //
    // Sprint 9.6.4 hotfix rationale (live build test 2026-07-08 15:59):
    //   Sprint 9.6.3 successfully resolved `flutter_tools/gradle`
    //   (PATH-based `which flutter`) and bumped Gradle 8.5 → 8.10 LTS,
    //   but the live workflow_dispatch run AFTER Sprint 9.6.3 cherry-pick
    //   failed at `mobile/android/app/build.gradle.kts:80` with:
    //
    //     Error: Your project's Android Gradle Plugin version (8.1.4)
    //            is lower than Flutter's minimum supported version of
    //            Android Gradle Plugin version 8.6.0. Please upgrade
    //            your Android Gradle Plugin version.
    //
    //   Flutter SDK 3.44.1 (project-wide pin via env.FLUTTER_VERSION in
    //   all 4 workflows) requires AGP >= 8.6.0. Sprint 9.6.4 picked
    //   8.6.1 (latest 8.6.x patch) for stability.
    //
    // Sprint 9.6.5 hotfix rationale (live build test 2026-07-08 16:38):
    //   Sprint 9.6.4 cherry-pick succeeded (`:gradle:jar` + `:app:configure`
    //   passed with AGP 8.6.1) but Flutter emitted a deprecation warning
    //   on the next run:
    //
    //     Warning: Flutter support for your project's Android Gradle
    //              Plugin version (8.6.1) will soon be dropped.
    //              Please upgrade your Android Gradle Plugin version to
    //              a version of at least 8.11.1 soon.
    //     Warning: Flutter support for your project's Kotlin version
    //              (1.9.22) will soon be dropped.
    //              Please upgrade your Kotlin version to a version of
    //              at least 2.2.20 soon.
    //
    //   Then the Kotlin DSL compiler emitted 6 errors at
    //   `mobile/android/app/build.gradle.kts` lines 145-151, 218:
    //   "Unresolved reference: util" / "Unresolved reference: load" /
    //   "No cast needed" / "variant parameter never used".
    //
    //   We picked AGP 8.11.1 (matches Flutter's "soon-dropped" floor)
    //   and Kotlin 2.2.20 (same). AGP 8.11+ requires Gradle 8.13+ (we
    //   have 8.14 LTS). Kotlin 2.2+ requires JDK 17+ (we have 17). The
    //   app/build.gradle.kts Kotlin DSL syntax was also updated to be
    //   compatible with Kotlin 2.0+ (explicit `java.util.Properties`
    //   import, smart cast for property access, unused parameter rename
    //   to `_`).
    //
    //   See `tools/workflow-yaml-audit.py` check_agp_version() +
    //   check_kotlin_version() + check_app_build_gradle_syntax() invariants.
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
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