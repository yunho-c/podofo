#!/usr/bin/env python3
"""Qualify experimental Copy/Listen using explicit local models and muted audio."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

APP = Path(__file__).resolve().parents[1]
REPO = APP.parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("layout", "formula", "rules", "pdf", "output"):
        parser.add_argument(f"--{name}", required=True, type=Path)
    parser.add_argument("--flutter-sdk", required=True, type=Path)
    parser.add_argument("--skip-build", action="store_true",
                        help="Use the prepared native assets and existing Release app")
    args = parser.parse_args()
    sdk = args.flutter_sdk.resolve(strict=True)
    layout, formula, rules, pdf = [getattr(args, k).resolve(strict=True)
                                    for k in ("layout", "formula", "rules", "pdf")]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, CARGO_INCREMENTAL="0", FLUTTER_BIN=str(sdk / "bin/flutter"),
               PODOCO_M2_BUNDLE=str(layout), PODOCO_M6_BUNDLE=str(formula),
               PODOCO_M7_RULES=str(rules), PODOCO_M8_PDF=str(pdf),
               PODOCO_M9_OUTPUT=str(output))

    def run(name, command):
        print(name, flush=True)
        with (output / f"{name}.log").open("w") as log:
            subprocess.run([str(v) for v in command], cwd=APP, env=env,
                           stdout=log, stderr=subprocess.STDOUT, check=True)

    if not args.skip_build:
        run("prepare", [sys.executable, "tool/prepare_podoco.py"])
        run("build", ["bash", "tool/build_macos_local.sh", "release"])
    run("analyze", [sdk / "bin/flutter", "analyze", "--no-pub"])
    # Keep the concurrency test separate from other native model workloads.
    run("native", [sys.executable, "tool/test_macos.py", "--flutter-sdk", sdk,
                   "test/equation_native_test.dart"])
    run("ui-and-lifecycle", [sys.executable, "tool/test_macos.py", "--flutter-sdk", sdk,
                            "test/equation_controller_test.dart", "test/equation_controls_test.dart",
                            "test/equation_widget_test.dart", "test/analysis_store_test.dart",
                            "test/narration_controller_test.dart"])
    screenshots = {}
    for name in ("podoco-equation-selected", "podoco-equation-controls"):
        source = APP / f"build/test-artifacts/{name}.png"
        shutil.copy2(source, output / source.name)
        screenshots[source.name] = digest(source)
    sources = {
        *APP.glob("lib/src/analysis/*.dart"),
        APP / "lib/src/narration/narration_controller.dart",
        APP / "lib/src/providers/analysis_provider.dart",
        APP / "lib/src/widgets/components/custom_pdf_viewer.dart",
        APP / "lib/src/widgets/components/layout_analysis_controls.dart",
        APP / "lib/src/widgets/components/equation_controls.dart",
        *APP.glob("test/equation*_test.dart"),
        APP / "test/fixtures/analysis_fixture.dart", APP / "tool/prepare_podoco.py",
        Path(__file__),
    }
    report = {
        "gate": "m9-experimental-integration-v1", "passed": True,
        "production_model_promotion": False, "human_listening_acceptance": False,
        "sandbox_picker_acceptance": False,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=APP, text=True).strip(),
        "git_status": subprocess.check_output(["git", "status", "--porcelain"], cwd=APP, text=True),
        "flutter": json.loads(subprocess.check_output([sdk / "bin/flutter", "--version", "--machine"], text=True)),
        "layout_manifest_sha256": digest(layout / "podoco-bundle.yaml"),
        "formula_manifest_sha256": digest(formula / "podoco-bundle.yaml"),
        "rules_manifest_sha256": digest(rules / "podoco-rules.yaml"),
        "native_artifact": json.loads((APP / ".podoco/native/provenance.json").read_text()),
        "pdf_sha256": digest(pdf), "screenshots": screenshots,
        "source_sha256": {str(p.relative_to(REPO)): digest(p) for p in sorted(sources)},
        "native": json.loads((output / "native.json").read_text()),
    }
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    main()
