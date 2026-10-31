#!/usr/bin/env python3
"""Build and qualify the experimental PoDoFo layout slice with explicit local assets."""

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
    parser.add_argument("--bundle", required=True, type=Path)
    parser.add_argument("--flutter-sdk", type=Path, default=REPO / ".fvm/flutter_sdk")
    args = parser.parse_args()
    sdk = args.flutter_sdk.resolve(strict=True)
    bundle = args.bundle.resolve(strict=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = APP / "build/podoco-qualification" / stamp
    output.mkdir(parents=True)
    env = dict(
        os.environ, FLUTTER_BIN=str(sdk / "bin/flutter"), PODOCO_M2_BUNDLE=str(bundle)
    )

    def run(name, command, cwd=APP):
        print(name, flush=True)
        with (output / f"{name}.log").open("w") as log:
            subprocess.run(
                [str(v) for v in command],
                cwd=cwd,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
                check=True,
            )

    run("prepare", [sys.executable, "tool/prepare_podoco.py"])
    run("packages", [sdk / "bin/flutter", "pub", "get", "--enforce-lockfile"])
    run("analyze", [sdk / "bin/flutter", "analyze", "--no-pub"])
    run("build", ["bash", "tool/build_macos_local.sh", "release"])
    run("tests", [sys.executable, "tool/test_macos.py", "--flutter-sdk", sdk])
    frameworks = (
        APP / "build/macos/Build/Products/Release/PoDoFo.app/Contents/Frameworks"
    )
    podoco = frameworks / "podoco_ffi.framework/podoco_ffi"
    mlsr = frameworks / "mlsr_ffi.framework/mlsr_ffi"
    run(
        "coexistence",
        [
            sys.executable,
            REPO / "podoco/tools/check_ffi_jobs.py",
            "--podoco",
            podoco,
            "--mlsr",
            mlsr,
            "--bundle",
            bundle,
            "--output",
            output / "coexistence",
        ],
    )
    images = {}
    for name in [
        "podoco-layout-overlay",
        "podoco-layout-rotated",
        "podoco-layout-controls",
    ]:
        path = APP / f"build/test-artifacts/{name}.png"
        shutil.copy2(path, output / path.name)
        images[path.name] = digest(path)
    sources = [
        *APP.glob("lib/src/analysis/*.dart"),
        APP / "lib/src/providers/analysis_provider.dart",
        APP / "lib/src/services/pdf_session.dart",
        APP / "lib/src/widgets/components/custom_pdf_viewer.dart",
        APP / "lib/src/widgets/components/layout_analysis_controls.dart",
        *APP.glob("test/analysis*_test.dart"),
        APP / "test/fixtures/analysis_fixture.dart",
        APP / "test/fixtures/pdf_fixture.dart",
        Path(__file__),
        APP / "tool/prepare_podoco.py",
    ]
    report = {
        "gate": "m5-app-layout-v1",
        "passed": True,
        "date": stamp,
        "flutter": json.loads(
            subprocess.check_output(
                [sdk / "bin/flutter", "--version", "--machine"], text=True
            )
        ),
        "manifest_sha256": digest(bundle / "podoco-bundle.yaml"),
        "source_sha256": {str(p.relative_to(REPO)): digest(p) for p in sorted(sources)},
        "screenshots": images,
        "coexistence": json.loads((output / "coexistence/summary.json").read_text()),
        "test_result": (output / "tests.log").read_text().strip().splitlines()[-1],
    }
    (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    main()
