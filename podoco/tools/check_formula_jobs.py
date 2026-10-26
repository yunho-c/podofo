#!/usr/bin/env python3
"""Qualify C/Dart formula jobs and complete multipage output against Rust."""

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


def sha(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ["layout", "formula", "documents", "output"]:
        p.add_argument("--" + name, type=lambda v: Path(v).resolve(), required=True)
    p.add_argument("--dart", default="dart")
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    with (a.output / "build.log").open("w") as log:
        subprocess.run(
            [
                "cargo",
                "build",
                "--locked",
                "--release",
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
    native = ROOT / "target/release/libpodoco_ffi.dylib"
    env = dict(
        os.environ,
        PODOCO_M2_BUNDLE=str(a.layout),
        PODOCO_M6_BUNDLE=str(a.formula),
        PODOCO_M6_DOCUMENTS=str(a.documents),
    )
    source_paths = [
        *sorted((ROOT / "crates/podoco-ffi/src").glob("*.rs")),
        *sorted((ROOT / "bindings/dart/lib").rglob("*.dart")),
        ROOT / "bindings/dart/test/formula_jobs_test.dart",
        Path(__file__),
    ]
    sources = {str(p.relative_to(ROOT)): sha(p) for p in source_paths}
    native_sha = sha(native)
    with tempfile.TemporaryDirectory(prefix="podoco-m6-") as temp:
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
        for name, command in [
            ("pub", [a.dart, "pub", "get", "--enforce-lockfile"]),
            (
                "tests",
                [
                    a.dart,
                    "test",
                    "test/formula_jobs_test.dart",
                    "--concurrency=1",
                    "--reporter=expanded",
                ],
            ),
        ]:
            with (a.output / (name + ".log")).open("w") as log:
                subprocess.run(
                    command,
                    cwd=package,
                    env=env,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=True,
                )
        tests = (a.output / "tests.log").read_text()
        passed = re.findall(r"\+(\d+): All tests passed!", tests)
        if not passed or int(passed[-1]) != 6 or "Skip:" in tests:
            raise RuntimeError("Native formula tests skipped or incomplete")
        args = json.loads((a.documents / "cli-args.json").read_text())
        with (
            (a.output / "dart.jsonl").open("w") as out,
            (a.output / "dart.log").open("w") as log,
        ):
            result = subprocess.run(
                [
                    a.dart,
                    "run",
                    "example/document_layout.dart",
                    *args,
                    str(a.documents / "pages.json"),
                ],
                cwd=package,
                env=env,
                stdout=out,
                stderr=log,
            )
    rows = [
        json.loads(line[line.index("{") :])
        for line in (a.output / "dart.jsonl").read_text().splitlines()
        if "{" in line
    ]
    expected = [
        json.loads(line)
        for line in (a.documents / "rust.jsonl").read_text().splitlines()
    ]
    failures = []
    if len(rows) != len(expected):
        failures.append("update count differs")
    for i, (actual, wanted) in enumerate(zip(rows, expected)):
        for field in ["sequence", "payload", "schema_version"]:
            if actual[field] != wanted[field]:
                failures.append(f"update {i} differs: {field}")
    status = rows[-1]["payload"]["summary"]["status"] if rows else None
    if result.returncode != (0 if status == "completed" else 1) or status not in [
        "completed",
        "partial",
    ]:
        failures.append("unexpected CLI completion")
    if sha(native) != native_sha:
        failures.append("native library changed during qualification")
    for path, digest in sources.items():
        if sha(ROOT / path) != digest:
            failures.append(f"source changed: {path}")
    summary = {
        "tests_passed": int(passed[-1]),
        "updates_compared": len(rows),
        "status": status,
        "dart_version": subprocess.check_output(
            [a.dart, "--version"], text=True
        ).strip(),
        "native_sha256": native_sha,
        "sources": sources,
        "rust_updates_sha256": sha(a.documents / "rust.jsonl"),
        "dart_updates_sha256": sha(a.output / "dart.jsonl"),
        "failures": failures,
    }
    (a.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "sources"}), flush=True)
    if failures:
        raise RuntimeError(failures)


if __name__ == "__main__":
    main()
