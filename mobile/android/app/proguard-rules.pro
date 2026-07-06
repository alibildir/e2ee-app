# mobile/android/app/proguard-rules.pro
#
# PR-39 (Sprint 6) — R8/ProGuard keep rules for the OpenE2EE Android app.
# Enabled via `mobile/android/app/build.gradle.kts` `buildTypes.release`
# (MOB-3 fix). Keep rules below ensure R8 does not strip symbols the
# Flutter embedding, MethodChannels, or our Kotlin VPN service reflect
# against at runtime.
#
# Verification:
#   - `flutter build apk --release` produces an APK that launches.
#   - VPN handshake (MainActivity → VpnService.prepare → RESULT_OK) still
#     resolves the `OpenE2eeVpnService` class.
#   - `flutter_secure_storage` reads/writes still work.
#   - JSON serialization in `device_identity.dart` (Ed25519 keys) still
#     round-trips via the Keystore-backed blob.
#
# References:
#   - https://developer.android.com/build/shrink-code
#   - https://docs.flutter.dev/deployment/android#shrinking-your-code-with-r8
#   - cyber-security Sprint 6 review (MOB-3) — July 2026

# ---------------------------------------------------------------------------
# Flutter embedding + MethodChannels
# ---------------------------------------------------------------------------
# The Flutter engine reflectively loads these classes via JNI. R8 must not
# strip or rename them.
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }

# GeneratedPluginRegistrant — built at `flutter pub get` time, lists every
# plugin entry point. Must not be renamed; Flutter reflection looks it up
# by FQCN.
-keep class io.flutter.plugins.GeneratedPluginRegistrant { *; }

# ---------------------------------------------------------------------------
# Our Kotlin sources — keep the public surface so AndroidManifest references
# resolve, and keep `companion object` constants that the Dart MethodChannel
# reads via reflection.
# ---------------------------------------------------------------------------
-keep class com.opene2ee.opene2ee.MainActivity { *; }
-keep class com.opene2ee.opene2ee.vpn.OpenE2eeVpnService { *; }
-keep class com.opene2ee.opene2ee.vpn.OpenE2eeVpnService$Companion { *; }
-keepclassmembers class com.opene2ee.opene2ee.** {
    public static ** Companion;
}

# ---------------------------------------------------------------------------
# flutter_secure_storage — keeps the platform-channel side intact. The
# upstream library ships its own consumer-rules.pro but listing the class
# here adds defence-in-depth against R8 stripping the method-channel
# handler.
# ---------------------------------------------------------------------------
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# ---------------------------------------------------------------------------
# AndroidX / Kotlin metadata
# ---------------------------------------------------------------------------
# Kotlin metadata is reflectively read by some AndroidX libs (e.g.
# Lifecycle, ViewModel). Keep it so Kotlin reflection from the Flutter
# embedding still resolves.
-keep class kotlin.Metadata { *; }
-keep class kotlin.reflect.** { *; }
-keepclassmembers class **$WhenMappings { <fields>; }
-keepclassmembers class kotlin.Metadata { public <methods>; }

# ---------------------------------------------------------------------------
# Standard Android keep rules (parity with android-optimize.txt)
# ---------------------------------------------------------------------------
# Keep custom view constructors / setters so XML inflation works.
-keepclasseswithmembers class * {
    public <init>(android.content.Context, android.util.AttributeSet);
}
-keepclasseswithmembers class * {
    public <init>(android.content.Context, android.util.AttributeSet, int);
}

# Keep `Parcelable` CREATOR fields (Android's IPC layer reflects against
# these).
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}

# Keep `Serializable` plumbing.
-keepclassmembers class * implements java.io.Serializable {
    static final long serialVersionUID;
    private static final java.io.ObjectStreamField[] serialPersistentFields;
    private void writeObject(java.io.ObjectOutputStream);
    private void readObject(java.io.ObjectInputStream);
    java.lang.Object writeReplace();
    java.lang.Object readResolve();
}

# ---------------------------------------------------------------------------
# Crash reporting hygiene
# ---------------------------------------------------------------------------
# Keep source file + line number metadata so a future Crashlytics / Sentry
# integration can still symbolicate stack traces against the original
# Kotlin sources. R8 emits a mapping.txt at
# `mobile/build/app/outputs/mapping/release/mapping.txt` per Flutter docs;
# upload that to the crash-reporting backend on each release.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile