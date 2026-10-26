#!/usr/bin/env python3
"""Run the Dart document SDK tests against an explicit Core ML artifact."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("bundle", "fixtures", "reference", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument(
        "--hook-build",
        action="store_true",
        help="Also build a fresh consumer with the explicit coreml hook option",
    )
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    native = ROOT / "target/release/libpodoco_ffi.dylib"
    with (args.output / "build.log").open("w") as log:
        subprocess.run(
            [
                "cargo",
                "build",
                "--release",
                "--locked",
                "-p",
                "podoco-ffi",
                "--features",
                "coreml",
            ],
            cwd=ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            check=True,
        )
    env = dict(
        os.environ,
        PODOCO_M2_BUNDLE=str(args.bundle.resolve()),
        PODOCO_M4_FIXTURES=str(args.fixtures.resolve()),
        PODOCO_M4_REFERENCE=str(args.reference.resolve()),
    )
    reference = [json.loads(line) for line in args.reference.read_text().splitlines()]
    pages = {
        "document": reference[0]["page"]["key"]["document"],
        "pages": [
            {
                "page": page["page"],
                "image": page["provenance"]["image"],
                "pixel_to_page": page["provenance"]["pixel_to_page"],
                "render_profile": page["provenance"]["render_profile"],
                "pixels": (args.fixtures / f"{name}.rgba").resolve().as_uri(),
            }
            for name, page in zip(
                ("columns", "equations", "raster"), reference, strict=True
            )
        ],
    }
    pages_path = args.output.resolve() / "pages.json"
    pages_path.write_text(json.dumps(pages, indent=2) + "\n")
    cli_args = [
        str(args.bundle.resolve()),
        "cpu-ne",
        "4000000",
        "96000000",
        "500000",
        "250000",
        "2",
        str(pages_path),
    ]
    hook_report = None
    with tempfile.TemporaryDirectory(prefix="podoco-m4-") as temp:
        package = Path(temp) / "package"
        shutil.copytree(
            ROOT / "bindings/dart",
            package,
            ignore=shutil.ignore_patterns(".dart_tool", "build", ".DS_Store"),
        )
        manifest = package / "pubspec.yaml"
        manifest.write_text(
            manifest.read_text() + "\nhooks:\n  user_defines:\n    podoco:\n"
            f"      native-library: {json.dumps(str(native))}\n"
        )
        for name, command in (
            ("pub", ["dart", "pub", "get", "--enforce-lockfile"]),
            (
                "tests",
                [
                    "dart",
                    "test",
                    "--concurrency=1",
                    "--reporter=expanded",
                    *[
                        str(p.relative_to(package))
                        for p in sorted((package / "test").glob("*_test.dart"))
                        if p.name != "formula_jobs_test.dart"
                    ],
                ],
            ),
        ):
            with (args.output / f"{name}.log").open("w") as log:
                subprocess.run(
                    command,
                    cwd=package,
                    env=env,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=True,
                )
        log = (args.output / "tests.log").read_text()
        passed = re.findall(r"\+(\d+): All tests passed!", log)
        if not passed or int(passed[-1]) < 14 or "Skip:" in log:
            raise RuntimeError("Native Dart tests were skipped or incomplete")
        with (args.output / "cli.jsonl").open("w") as data:
            with (args.output / "cli.log").open("w") as log:
                subprocess.run(
                    ["dart", "run", "example/document_layout.dart", *cli_args],
                    cwd=package,
                    env=env,
                    stdout=data,
                    stderr=log,
                    check=True,
                )
        # `dart run` writes a build-hooks prefix to stdout before program output.
        lines = (args.output / "cli.jsonl").read_text().splitlines()
        updates = [json.loads(line[line.index("{") :]) for line in lines if "{" in line]
        assert len(updates) == 7
        for index, page in enumerate(reference):
            assert updates[index * 2]["payload"]["page"] == page
            assert updates[index * 2 + 1]["payload"]["page"] == page
        if args.hook_build:
            consumer = Path(temp) / "hook-consumer"
            consumer.mkdir()
            (consumer / "pubspec.yaml").write_text(
                "name: podoco_coreml_check\nenvironment:\n  sdk: '>=3.13.0 <4.0.0'\n"
                "dependencies:\n  podoco:\n"
                f"    path: {json.dumps(str(ROOT / 'bindings/dart'))}\n"
                "hooks:\n  user_defines:\n    podoco:\n      coreml: true\n"
            )
            shutil.copyfile(
                ROOT / "bindings/dart/example/document_layout.dart",
                consumer / "main.dart",
            )
            with (args.output / "hook.log").open("w") as log:
                subprocess.run(
                    ["dart", "pub", "get"],
                    cwd=consumer,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=True,
                )
                subprocess.run(
                    ["dart", "run", "main.dart", *cli_args],
                    cwd=consumer,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=True,
                )
            libraries = [
                p
                for p in consumer.rglob("libpodoco_ffi.dylib")
                if "cargo" not in p.parts
            ]
            if not libraries:
                raise RuntimeError("Core ML hook did not bundle a library")
            commands = subprocess.check_output(
                ["otool", "-l", str(libraries[0])], text=True
            )
            minimum = re.findall(r"minos ([0-9.]+)", commands)
            if not minimum or any(int(v.split(".")[0]) < 15 for v in minimum):
                raise RuntimeError("Core ML hook omitted the macOS 15 deployment floor")
            (args.output / "hook-load-commands.txt").write_text(commands)
            hook_report = {
                "minimum_macos": minimum,
                "native_sha256": hashlib.sha256(libraries[0].read_bytes()).hexdigest(),
            }
    hashes = {
        name: hashlib.sha256((args.fixtures / f"{name}.rgba").read_bytes()).hexdigest()
        for name in ("columns", "equations", "raster")
    }
    report = {
        "gate": "m4-dart-document-v1",
        "passed": True,
        "fixture_rgba_sha256": hashes,
        "reference_sha256": hashlib.sha256(args.reference.read_bytes()).hexdigest(),
        "native_sha256": hashlib.sha256(native.read_bytes()).hexdigest(),
        "dart_tests": int(passed[-1]),
        "cli_updates": len(updates),
        "hook_build": hook_report,
    }
    (args.output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Dart native document tests passed.")


if __name__ == "__main__":
    main()
