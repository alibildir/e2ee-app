"""
PyYAML audit for 4 GH Actions workflows + Gradle wrapper + AGP + Kotlin
+ app/build.gradle.kts syntax invariants.
Per memory rule: PyYAML 1.1 parses `on:` as boolean `True` — use d[True].
Applies to all workflow files; tracks the Sprint 9.6.2 + 9.6.3 + 9.6.4 +
9.6.5 fix invariants (added 2026-07-08 after Sprint 9.6.1 PR #13 push CI
FAIL, Sprint 9.6.2 PR #14 push CI FAIL, Sprint 9.6.3 PR #15 push CI FAIL,
and Sprint 9.6.4 PR #15 (PUSHED) live build test CI FAIL).

Verifies:
  1. All 4 workflows have ONLY workflow_dispatch trigger (no push/pull_request).
  2. android-debug.yml has subosito/flutter-action@v2 step.
  3. android-debug.yml's `Setup Flutter` step pins flutter-version
     (Sprint 9.6.2 fix — Sprint 9.6.1 had `channel: stable` only, which
     caused ${FLUTTER_HOME} to resolve to empty in the runner).
  4. android-debug.yml's `Generate local.properties` step writes flutter.sdk
     echo derived from `which flutter` (Sprint 9.6.2 fix — Sprint 9.6.1
     used `${FLUTTER_HOME}` which was empty, causing settings.gradle.kts
     `includeBuild("")` = `/packages/flutter_tools/gradle` to FAIL).
  5. android-debug.yml has `Verify Flutter SDK path` step
     (fast-fail signal BEFORE ./gradlew assembleDebug).
  6. ci.yml/ios.yml/android-release.yml have NO inputs.runner
     (matrix/single-runner workflows don't need it).
  7. **Sprint 9.6.3:** gradle-wrapper.properties distributionUrl must be
     >= 8.7.0 (Flutter 3.44.1 minimum). Sprint 9.6.2 fix made
     `flutter_tools/gradle` resolve correctly, but a live workflow_dispatch
     run after Sprint 9.6.2 PR #14 push failed at app/build.gradle.kts:80
     with "Your project's Gradle version (8.5.0) is lower than Flutter's
     minimum supported version of 8.7.0".
  8. **Sprint 9.6.4:** mobile/android/build.gradle.kts AGP plugin version
     must be >= 8.6.0 (Flutter 3.44.1 minimum). Sprint 9.6.3 cherry-pick
     bumped Gradle 8.5 → 8.10, but Flutter then emitted a deprecation
     warning (Gradle 8.10 soon-dropped) and failed at app/build.gradle.kts:80
     with "Your project's Android Gradle Plugin version (8.1.4) is lower
     than Flutter's minimum supported version of Android Gradle Plugin
     version 8.6.0".
  9. **Sprint 9.6.5:** build.gradle.kts Kotlin plugin version must be
     >= 2.2 (Flutter 3.44.1 soon-dropped floor). Sprint 9.6.4 cherry-pick
     bumped AGP 8.1.4 → 8.6.1, but Flutter emitted a deprecation warning
     and the Kotlin 2.0+ DSL compiler rejected the Sprint 5 era
     `java.util.Properties().apply { ... }` block (no explicit import)
     + `as String` casts (smart cast handles) + unused parameter
     `variant` (rename to `_`).
 10. **Sprint 9.6.5:** app/build.gradle.kts must `import java.util.Properties`
     explicitly if it uses Properties (Kotlin 2.0+ stricter on implicit
     imports). Static check for the import + Properties usage pairing.
"""
import re
import yaml
import sys
from pathlib import Path

WORKFLOWS_DIR = Path(__file__).resolve().parent.parent / ".github" / "workflows"
REPO_ROOT = Path(__file__).resolve().parent.parent
TARGETS = ["android-debug.yml", "ci.yml", "ios.yml", "android-release.yml"]

# Flutter 3.44.1 minimum version pins (env.FLUTTER_VERSION in all 4
# workflows; cross-cycle consistency).
FLUTTER_MIN_GRADLE = (8, 7)
FLUTTER_MIN_AGP = (8, 6)
FLUTTER_MIN_KOTLIN = (2, 2)


def audit_workflow(path: Path) -> list[str]:
    """Return list of findings (empty = pass)."""
    findings = []
    name = path.name

    with path.open(encoding="utf-8") as f:
        docs = list(yaml.safe_load_all(f))
    if len(docs) != 1 or docs[0] is None:
        findings.append(f"{name}: YAML parse failed (expected 1 doc, got {len(docs)})")
        return findings
    d = docs[0]

    # PyYAML 1.1 quirk: `on:` -> True (boolean). Use d[True].
    on_block = d.get(True)
    if on_block is None:
        findings.append(f"{name}: `on:` block missing or None")
        return findings
    if not isinstance(on_block, dict):
        findings.append(f"{name}: `on:` block is not a dict: {type(on_block).__name__}")
        return findings

    trigger_keys = sorted(on_block.keys())
    expected = ["workflow_dispatch"]
    if trigger_keys != expected:
        findings.append(
            f"{name}: `on:` triggers = {trigger_keys}, expected exactly {expected}"
        )

    # Workflow-level checks
    if name == "android-debug.yml":
        jobs = d.get("jobs", {})
        for job_name, job_def in jobs.items():
            steps = job_def.get("steps", []) if isinstance(job_def, dict) else []

            has_flutter_setup = False
            flutter_version_pinned = False
            has_which_flutter_echo = False
            has_verify_step = False

            for s in steps:
                if not isinstance(s, dict):
                    continue
                step_uses = str(s.get("uses", ""))

                # Setup Flutter step with pinned version
                if "subosito/flutter-action" in step_uses:
                    has_flutter_setup = True
                    step_with = s.get("with", {})
                    if isinstance(step_with, dict) and "flutter-version" in step_with:
                        flutter_version_pinned = True
                    continue

                step_name = str(s.get("name", ""))
                run_text = str(s.get("run", ""))

                # Generate local.properties: flutter.sdk derived from which flutter
                if "Generate local.properties" in step_name:
                    if "which flutter" in run_text and "flutter.sdk=" in run_text:
                        has_which_flutter_echo = True

                # Verify Flutter SDK path step
                if "Verify Flutter SDK path" in step_name:
                    if "flutter_tools/gradle" in run_text:
                        has_verify_step = True

            if not has_flutter_setup:
                findings.append(
                    f"{name}: job '{job_name}' missing subosito/flutter-action@v2 step"
                )
            if not flutter_version_pinned:
                findings.append(
                    f"{name}: job '{job_name}' Setup Flutter step missing `flutter-version` pin "
                    "(Sprint 9.6.2 fix — was channel:stable only in Sprint 9.6.1)"
                )
            if not has_which_flutter_echo:
                findings.append(
                    f"{name}: job '{job_name}' Generate local.properties step missing "
                    "`which flutter` derivation (Sprint 9.6.2 fix — was ${FLUTTER_HOME} "
                    "in Sprint 9.6.1 which resolved to empty in the runner shell)"
                )
            if not has_verify_step:
                findings.append(
                    f"{name}: job '{job_name}' missing `Verify Flutter SDK path` fast-fail step"
                )

    # Check inputs.runner absence for matrix/single-runner workflows
    if name in ("ci.yml", "ios.yml", "android-release.yml"):
        wd = on_block.get("workflow_dispatch")
        if isinstance(wd, dict) and "inputs" in wd:
            findings.append(
                f"{name}: has `inputs.runner` but matrix/single-runner workflow doesn't need it"
            )

    return findings


def check_gradle_wrapper_version() -> list[str]:
    """Sprint 9.6.3: gradle-wrapper.properties distributionUrl >= Flutter minimum.

    Flutter 3.44.1 (project-wide pin via env.FLUTTER_VERSION in all 4 workflows)
    requires Gradle >= 8.7.0. Sprint 9.6.2 fix made `flutter_tools/gradle`
    resolve correctly, but a live workflow_dispatch run after Sprint 9.6.2
    PR #14 push failed at app/build.gradle.kts:80 with:
        "Your project's Gradle version (8.5.0) is lower than Flutter's
         minimum supported version of 8.7.0."
    This check parses `gradle-wrapper.properties` distributionUrl and
    fails if the embedded Gradle version is below FLUTTER_MIN_GRADLE.
    """
    findings = []
    gradle_props_path = REPO_ROOT / "mobile" / "android" / "gradle" / "wrapper" / "gradle-wrapper.properties"
    if not gradle_props_path.exists():
        findings.append(
            f"{gradle_props_path.name}: file missing (Sprint 9.6.3 invariant)"
        )
        return findings
    text = gradle_props_path.read_text(encoding="utf-8")
    # Pattern: distributionUrl=.../gradle-X.Y(-bin).zip
    match = re.search(r"gradle-(\d+)\.(\d+)(?:-bin)?\.zip", text)
    if not match:
        findings.append(
            f"gradle-wrapper.properties: distributionUrl pattern not recognized "
            "(expected `gradle-X.Y-bin.zip`)"
        )
        return findings
    gradle_version = (int(match.group(1)), int(match.group(2)))
    if gradle_version < FLUTTER_MIN_GRADLE:
        findings.append(
            f"gradle-wrapper.properties: distributionUrl Gradle {gradle_version[0]}.{gradle_version[1]} "
            f"< Flutter 3.44.1 minimum {FLUTTER_MIN_GRADLE[0]}.{FLUTTER_MIN_GRADLE[1]} "
            "(Sprint 9.6.3 fix — was 8.5 in Sprint 9.6.2, live run failed at "
            "app/build.gradle.kts:80 with Flutter Gradle plugin version check)"
        )
    return findings


def check_agp_version() -> list[str]:
    """Sprint 9.6.4: mobile/android/build.gradle.kts AGP plugin version >= 8.6.0.

    Flutter SDK 3.44.1 minimum AGP is 8.6.0. Sprint 9.6.3 cherry-pick
    bumped Gradle 8.5 -> 8.10 LTS (passed `:gradle:jar`) but a live
    workflow_dispatch run AFTER Sprint 9.6.3 cherry-pick failed at
    `mobile/android/app/build.gradle.kts:80` with:
        "Your project's Android Gradle Plugin version (Android Gradle
         Plugin version 8.1.4) is lower than Flutter's minimum
         supported version of Android Gradle Plugin version 8.6.0.
         Please upgrade your Android Gradle Plugin version."

    This check parses the AGP plugin block in the root build.gradle.kts:
        plugins {
            id("com.android.application") version "X.Y.Z" apply false
            ...
        }
    and fails if the declared AGP version is below FLUTTER_MIN_AGP.

    Note: settings.gradle.kts uses `id("com.android.application")` without
    version (in the subproject's plugins block); the VERSION is declared
    ONCE in the root build.gradle.kts plugins block. So this check
    targets the root file.
    """
    findings = []
    build_gradle_path = REPO_ROOT / "mobile" / "android" / "build.gradle.kts"
    if not build_gradle_path.exists():
        findings.append(
            f"{build_gradle_path.name}: file missing (Sprint 9.6.4 AGP invariant)"
        )
        return findings
    text = build_gradle_path.read_text(encoding="utf-8")
    # Pattern: id("com.android.application") version "X.Y.Z" apply false
    # Match `id("com.android.application")` (with opening + closing
    # double-quotes around plugin ID) followed by `version "X.Y.Z"`.
    match = re.search(
        r'id\("com\.android\.application"\)\s+version\s+"(\d+)\.(\d+)(?:\.(\d+))?"',
        text,
    )
    if not match:
        findings.append(
            f"build.gradle.kts: AGP plugin version pattern not recognized "
            "(expected `id(\"com.android.application\") version \"X.Y.Z\" apply false`)"
        )
        return findings
    agp_major = int(match.group(1))
    agp_minor = int(match.group(2))
    agp_version = (agp_major, agp_minor)
    if agp_version < FLUTTER_MIN_AGP:
        findings.append(
            f"build.gradle.kts: AGP version {agp_major}.{agp_minor} "
            f"< Flutter 3.44.1 minimum {FLUTTER_MIN_AGP[0]}.{FLUTTER_MIN_AGP[1]} "
            "(Sprint 9.6.4 fix — was 8.1.4 before; live run after Sprint 9.6.3 "
            "cherry-pick failed at app/build.gradle.kts:80 with Flutter Gradle "
            "plugin AGP version check)"
        )
    return findings


def check_kotlin_version() -> list[str]:
    """Sprint 9.6.5: mobile/android/build.gradle.kts Kotlin plugin version >= 2.2.

    Flutter SDK 3.44.1 soon-dropped floor for Kotlin is 2.2.20. Sprint
    9.6.4 cherry-pick bumped AGP 8.1.4 → 8.6.1 (passed `:app:configure`)
    but the live workflow_dispatch run AFTER Sprint 9.6.4 push (PR
    #15 PUSHED) emitted a deprecation warning and the Kotlin 2.0+
    DSL compiler rejected the Sprint 5 era `app/build.gradle.kts`:
        Warning: Flutter support for your project's Kotlin version
                 (1.9.22) will soon be dropped.
                 Please upgrade your Kotlin version to a version of
                 at least 2.2.20 soon.
        Unresolved reference: util (Kotlin 2.0+ requires explicit import
                               for fully-qualified class names)
        Unresolved reference: load
        No cast needed (Kotlin 2.0+ smart cast handles `as String`)
        variant parameter never used (rename to `_`)

    This check parses the Kotlin Android plugin version in the root
    build.gradle.kts plugins block and fails if below FLUTTER_MIN_KOTLIN.
    """
    findings = []
    build_gradle_path = REPO_ROOT / "mobile" / "android" / "build.gradle.kts"
    if not build_gradle_path.exists():
        findings.append(
            f"{build_gradle_path.name}: file missing (Sprint 9.6.5 Kotlin invariant)"
        )
        return findings
    text = build_gradle_path.read_text(encoding="utf-8")
    # Pattern: id("org.jetbrains.kotlin.android") version "X.Y.Z" apply false
    match = re.search(
        r'id\("org\.jetbrains\.kotlin\.android"\)\s+version\s+"(\d+)\.(\d+)(?:\.(\d+))?"',
        text,
    )
    if not match:
        findings.append(
            f"build.gradle.kts: Kotlin Android plugin version pattern not recognized "
            "(expected `id(\"org.jetbrains.kotlin.android\") version \"X.Y.Z\" apply false`)"
        )
        return findings
    kotlin_major = int(match.group(1))
    kotlin_minor = int(match.group(2))
    kotlin_version = (kotlin_major, kotlin_minor)
    if kotlin_version < FLUTTER_MIN_KOTLIN:
        findings.append(
            f"build.gradle.kts: Kotlin version {kotlin_major}.{kotlin_minor} "
            f"< Flutter 3.44.1 soon-dropped floor {FLUTTER_MIN_KOTLIN[0]}.{FLUTTER_MIN_KOTLIN[1]} "
            "(Sprint 9.6.5 fix — was 1.9.22; live run after Sprint 9.6.4 "
            "PR #15 PUSHED failed at app/build.gradle.kts:145 with Kotlin 2.0+ "
            "DSL compiler errors: Unresolved reference util/load, No cast needed, "
            "variant parameter never used)"
        )
    return findings


def check_app_build_gradle_syntax() -> list[str]:
    """Sprint 9.6.5: app/build.gradle.kts Kotlin DSL syntax check.

    The Kotlin 2.0+ DSL compiler is stricter on implicit imports.
    Sprint 5 era `app/build.gradle.kts` used
    `java.util.Properties().apply { ... }` without an explicit
    `import java.util.Properties` and worked because Kotlin 1.9's
    compiler allowed implicit imports. Kotlin 2.0+ rejects this
    with "Unresolved reference: util".

    This check ensures that if `app/build.gradle.kts` uses
    `Properties` (or `java.util.Properties` fully-qualified), it
    also has the explicit `import java.util.Properties` statement.

    Note: this is a syntactic pair-check, not a real Kotlin compiler
    invocation. Sprint 9.7+ plan includes a real `gh workflow run`
    (Check L) for definitive verification, since static checks have
    failed 6 times in this chain.
    """
    findings = []
    app_gradle_path = REPO_ROOT / "mobile" / "android" / "app" / "build.gradle.kts"
    if not app_gradle_path.exists():
        findings.append(
            f"{app_gradle_path.name}: file missing (Sprint 9.6.5 syntax invariant)"
        )
        return findings
    text = app_gradle_path.read_text(encoding="utf-8")
    # If Properties is used (either fully-qualified or short form)
    # but the explicit import is missing, fail.
    uses_properties = (
        "java.util.Properties" in text
        or re.search(r"\bProperties\(\)\.", text) is not None
    )
    has_import = "import java.util.Properties" in text
    if uses_properties and not has_import:
        findings.append(
            "app/build.gradle.kts: uses Properties without `import java.util.Properties` "
            "(Sprint 9.6.5 fix — Kotlin 2.0+ requires explicit import; live run after "
            "Sprint 9.6.4 PR #15 PUSHED failed at line 145 with 'Unresolved reference: util')"
        )
    return findings


def main() -> int:
    all_findings = []
    for fname in TARGETS:
        path = WORKFLOWS_DIR / fname
        if not path.exists():
            all_findings.append(f"{fname}: file missing")
            continue
        findings = audit_workflow(path)
        if findings:
            all_findings.extend(findings)
        else:
            print(f"PASS: {fname}")

    # Sprint 9.6.3: Gradle wrapper version invariant check.
    gradle_findings = check_gradle_wrapper_version()
    if gradle_findings:
        all_findings.extend(gradle_findings)
    else:
        print(f"PASS: gradle-wrapper.properties distributionUrl >= {FLUTTER_MIN_GRADLE[0]}.{FLUTTER_MIN_GRADLE[1]}")

    # Sprint 9.6.4: AGP version invariant check.
    agp_findings = check_agp_version()
    if agp_findings:
        all_findings.extend(agp_findings)
    else:
        print(f"PASS: build.gradle.kts AGP version >= {FLUTTER_MIN_AGP[0]}.{FLUTTER_MIN_AGP[1]} (Flutter 3.44.1 minimum)")

    # Sprint 9.6.5: Kotlin version + app/build.gradle.kts syntax invariants.
    kotlin_findings = check_kotlin_version()
    if kotlin_findings:
        all_findings.extend(kotlin_findings)
    else:
        print(f"PASS: build.gradle.kts Kotlin version >= {FLUTTER_MIN_KOTLIN[0]}.{FLUTTER_MIN_KOTLIN[1]} (Flutter 3.44.1 soon-dropped)")

    syntax_findings = check_app_build_gradle_syntax()
    if syntax_findings:
        all_findings.extend(syntax_findings)
    else:
        print("PASS: app/build.gradle.kts Kotlin DSL syntax (explicit java.util.Properties import)")

    if all_findings:
        print("\nFINDINGS:")
        for f in all_findings:
            print(f"  - {f}")
        return 1
    print("\nALL 4 WORKFLOWS + GRADLE WRAPPER + AGP + KOTLIN + SYNTAX PASS PyYAML AUDIT.")
    return 0


if __name__ == "__main__":
    sys.exit(main())