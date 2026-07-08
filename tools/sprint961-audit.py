"""
Sprint 9.6.1 — PyYAML audit for 4 GH Actions workflows.
Per memory rule: PyYAML 1.1 parses `on:` as boolean `True` — use d[True].
Verifies:
  1. All 4 workflows have ONLY workflow_dispatch trigger (no push/pull_request).
  2. android-debug.yml has subosito/flutter-action@v2 step.
  3. android-debug.yml's Generate local.properties step writes flutter.sdk echo.
  4. ci.yml/ios.yml/android-release.yml have NO inputs.runner (matrix/single-runner
     workflows don't need it).
"""
import yaml
import sys
from pathlib import Path

WORKFLOWS_DIR = Path(r"C:\repos\e2ee-app-pr-s961item1\.github\workflows")
TARGETS = ["android-debug.yml", "ci.yml", "ios.yml", "android-release.yml"]


def audit_workflow(path: Path) -> list[str]:
    """Return list of findings (empty = pass)."""
    findings = []
    name = path.name

    with path.open(encoding="utf-8") as f:
        # round-trip loader preserves structure
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

    # Check 2: android-debug.yml has subosito/flutter-action@v2 step
    if name == "android-debug.yml":
        jobs = d.get("jobs", {})
        for job_name, job_def in jobs.items():
            steps = job_def.get("steps", []) if isinstance(job_def, dict) else []
            has_flutter_setup = any(
                isinstance(s, dict) and "subosito/flutter-action" in str(s.get("uses", ""))
                for s in steps
            )
            if not has_flutter_setup:
                findings.append(
                    f"{name}: job '{job_name}' missing subosito/flutter-action@v2 step"
                )

            # Check 3: Generate local.properties has flutter.sdk echo
            for s in steps:
                if not isinstance(s, dict):
                    continue
                if "Generate local.properties" in str(s.get("name", "")):
                    run_text = str(s.get("run", ""))
                    if "flutter.sdk=" not in run_text:
                        findings.append(
                            f"{name}: job '{job_name}' Generate local.properties step missing `flutter.sdk=` echo"
                        )
                    if "FLUTTER_HOME" not in run_text:
                        findings.append(
                            f"{name}: job '{job_name}' Generate local.properties step missing ${{FLUTTER_HOME}} reference"
                        )

    # Check 4: ci.yml/ios.yml/android-release.yml should NOT have inputs.runner
    if name in ("ci.yml", "ios.yml", "android-release.yml"):
        wd = on_block.get("workflow_dispatch")
        if isinstance(wd, dict) and "inputs" in wd:
            findings.append(
                f"{name}: has `inputs.runner` but matrix/single-runner workflow doesn't need it"
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
    if all_findings:
        print("\nFINDINGS:")
        for f in all_findings:
            print(f"  - {f}")
        return 1
    print("\nALL 4 WORKFLOWS PASS PyYAML AUDIT.")
    return 0


if __name__ == "__main__":
    sys.exit(main())