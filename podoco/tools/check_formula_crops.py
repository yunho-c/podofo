#!/usr/bin/env python3
"""Qualify queued explicit crops, release ordering and ABI-2 feature gating."""

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
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def run(command, cwd, env, log):
    with log.open("w") as output:
        subprocess.run(command, cwd=cwd, env=env, stdout=output,
                       stderr=subprocess.STDOUT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ["layout", "formula", "reference", "documents", "output"]:
        parser.add_argument("--" + name, type=lambda v: Path(v).resolve(), required=True)
    parser.add_argument("--legacy-native", type=lambda v: Path(v).resolve())
    parser.add_argument("--dart", default="dart")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, CARGO_INCREMENTAL="0", PODOCO_M2_BUNDLE=str(args.layout),
               PODOCO_M6_BUNDLE=str(args.formula), PODOCO_M6_REFERENCE=str(args.reference),
               PODOCO_M6_DOCUMENTS=str(args.documents),
               PODOCO_CROP_OUTPUT=str(args.output / "outcomes.json"))
    env["MACOSX_DEPLOYMENT_TARGET"] = "15.0"
    env.pop("SDKROOT", None)
    env.pop("IPHONEOS_DEPLOYMENT_TARGET", None)
    legacy = None
    if args.legacy_native:
        legacy = args.output / "legacy-podoco-ffi.dylib"
        # Snapshot before any native rebuild can replace the selected old artifact.
        shutil.copy2(args.legacy_native, legacy)
    source_paths = [ROOT / "Cargo.lock", ROOT / "Cargo.toml", ROOT / "include/podoco.h",
                    *sorted((ROOT / "crates").rglob("*.rs")),
                    *sorted((ROOT / "crates").rglob("Cargo.toml")),
                    *sorted((ROOT / "bindings/dart").glob("pubspec.*")),
                    *sorted((ROOT / "bindings/dart/lib").rglob("*.dart")),
                    *sorted((ROOT / "bindings/dart/test").glob("*formula*test.dart")),
                    Path(__file__)]
    sources = {str(path.relative_to(ROOT)): sha(path) for path in source_paths}
    run(["cargo", "build", "--locked", "--release", "-p", "podoco-ffi",
         "--features", "coreml,math"], ROOT, env, args.output / "build.log")
    # Test an immutable snapshot, not a shared Cargo output that app preparation
    # or another feature build may replace while the qualification is running.
    native = args.output / "libpodoco_ffi.dylib"
    shutil.copy2(ROOT / "target/release/libpodoco_ffi.dylib", native)
    native_sha = sha(native)
    suites = [("crops", native, "test/explicit_formula_test.dart", 6, env),
              ("documents", native, "test/formula_jobs_test.dart", 6, env)]
    if legacy:
        suites.append(("legacy", legacy, "test/explicit_formula_legacy_test.dart", 1,
                       dict(env, PODOCO_EXPECT_NO_CROP="1")))
    passed = {}
    for name, library, test, expected, environment in suites:
        with tempfile.TemporaryDirectory(prefix="podoco-crops-") as temporary:
            package = Path(temporary) / "package"
            shutil.copytree(ROOT / "bindings/dart", package,
                            ignore=shutil.ignore_patterns(".dart_tool", "build", ".DS_Store"))
            manifest = package / "pubspec.yaml"
            manifest.write_text(manifest.read_text() + "\nhooks:\n  user_defines:\n    podoco:\n"
                                f"      native-library: {json.dumps(str(library))}\n")
            run([args.dart, "pub", "get", "--enforce-lockfile"], package, environment,
                args.output / f"{name}-pub.log")
            log = args.output / f"{name}-tests.log"
            run([args.dart, "test", test, "--concurrency=1", "--reporter=expanded"],
                package, environment, log)
            text = log.read_text()
            counts = re.findall(r"\+(\d+): All tests passed!", text)
            if not counts or int(counts[-1]) != expected or "Skip:" in text:
                raise RuntimeError(f"{name}: native tests skipped or incomplete")
            passed[name] = int(counts[-1])
    outcomes = json.loads((args.output / "outcomes.json").read_text())
    if outcomes["compared"] != 32 or outcomes["native_handles_after"] != 0:
        raise RuntimeError("Incomplete reference comparisons or leaked handles")
    if sha(native) != native_sha or any(sha(ROOT / p) != h for p, h in sources.items()):
        raise RuntimeError("Native library or source changed during qualification")
    summary = {
        "tests_passed": passed, "compared": outcomes["compared"],
        "native_handles_after": outcomes["native_handles_after"],
        "native_sha256": native_sha, "legacy_native_sha256": sha(legacy) if legacy else None,
        "reference_sha256": sha(args.reference / "reference.json"),
        "document_reference_sha256": sha(args.documents / "rust.jsonl"),
        "outcomes_sha256": sha(args.output / "outcomes.json"),
        "dart_version": subprocess.check_output([args.dart, "--version"], text=True).strip(),
        "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "sources": sources,
    }
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({k: v for k, v in summary.items() if k != "sources"}), flush=True)


if __name__ == "__main__":
    main()
