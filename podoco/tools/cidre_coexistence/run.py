#!/usr/bin/env python3
"""Compare cidre 0.29.0 observer exclusion/namespacing without changing consumers."""

import argparse
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

TOOLS = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--mlsr", required=True, type=Path, help="Existing MLSR checkout")
parser.add_argument(
    "--cidre-source", type=Path, help="Unmodified cidre 0.29.0 crate source"
)
parser.add_argument(
    "--output",
    required=True,
    type=Path,
    help="New directory for all generated evidence",
)
parser.add_argument(
    "--target-dir", type=Path, help="Optional existing Cargo build cache"
)
args = parser.parse_args()
if sys.platform != "darwin":
    parser.error("Requires macOS and Xcode")
MLSR = args.mlsr.resolve()
SOURCE = args.cidre_source
if SOURCE is None:
    candidates = list((Path.home() / ".cargo/registry/src").glob("*/cidre-0.29.0"))
    if len(candidates) != 1:
        parser.error("Supply --cidre-source pointing to the unmodified 0.29.0 crate")
    SOURCE = candidates[0]
SOURCE = SOURCE.resolve()
expected_hashes = json.loads((TOOLS / "source-checksums.json").read_text())
for name, digest in expected_hashes.items():
    if hashlib.sha256((SOURCE / name).read_bytes()).hexdigest() != digest:
        parser.error(f"Unexpected cidre source: {name}")
if not (MLSR / "crates/mlsr/examples/coreml_ffi_probe.rs").is_file():
    parser.error("MLSR checkout does not contain the expected Core ML probe")
ROOT = args.output.resolve()
ROOT.mkdir(parents=True, exist_ok=False)
TARGET = args.target_dir.resolve() if args.target_dir else ROOT / "target"
for variant in ["stock", "optional", "split", "namespaced"]:
    destination = ROOT / "sources" / variant
    shutil.copytree(
        SOURCE,
        destination,
        ignore=shutil.ignore_patterns(".cargo-ok", ".cargo-checksum.json"),
    )
    if variant != "stock":
        patch = TOOLS / "patches" / f"cidre-0.29.0-{variant}.patch"
        result = subprocess.run(
            ["patch", "-p1", "-t", "-i", str(patch)],
            cwd=destination,
            capture_output=True,
            text=True,
        )
        (ROOT / f"{variant}.patch.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"Patch failed: {result.stdout}{result.stderr}")
(ROOT / "probe.rs").write_text(
    (MLSR / "crates/mlsr/examples/coreml_ffi_probe.rs").read_text()
    + "\n"
    + (TOOLS / "kvo_probe.rs").read_text()
)
shutil.copyfile(TOOLS / "load_pair.py", ROOT / "runner.py")
ENV = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="15.0")
ENV.pop("CIDRE_OBJC_CLASS_PREFIX", None)
ENV.pop("RUSTFLAGS", None)
ENV.pop("CARGO_ENCODED_RUSTFLAGS", None)
ARTIFACTS = ROOT / "artifacts"
ARTIFACTS.mkdir(exist_ok=True)
LOGS = ROOT / "logs"
LOGS.mkdir(exist_ok=True)
RESULTS = {
    "host": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
    "architecture": subprocess.check_output(["uname", "-m"], text=True).strip(),
    "rust": subprocess.check_output(
        ["rustc", "+stable", "--version"], text=True
    ).strip(),
    "mlsr_head": subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=MLSR, text=True
    ).strip(),
    "mlsr_probe_sha256": hashlib.sha256(
        (MLSR / "crates/mlsr/examples/coreml_ffi_probe.rs").read_bytes()
    ).hexdigest(),
    "cidre_source_commit": json.loads((SOURCE / ".cargo_vcs_info.json").read_text())[
        "git"
    ]["sha1"],
    "profile": "release (and explicit debug cases), strip=none, CPU-only inference",
    "builds": {},
    "pairs": {},
}


def save():
    (ROOT / "results.json").write_text(json.dumps(RESULTS, indent=2) + "\n")


def build(variant, member, *, kvo=False, prefix=None, force=False, debug=False):
    workspace = ROOT / "workspaces" / variant
    workspace.mkdir(parents=True, exist_ok=True)
    manifest = f"""[workspace]
members = ["probe-a", "probe-b"]
resolver = "3"
[patch.crates-io]
cidre = {{ path = {json.dumps(str(ROOT / "sources" / variant))} }}
[profile.release]
strip = "none"
[profile.dev]
strip = "none"
"""
    (workspace / "Cargo.toml").write_text(manifest)
    for name in ["probe-a", "probe-b"]:
        package = workspace / name
        package.mkdir(exist_ok=True)
        (package / "Cargo.toml").write_text(f'''[package]
name = "{name}"
version = "0.1.0"
edition = "2024"
[lib]
path = {json.dumps(str(ROOT / "probe.rs"))}
crate-type = ["cdylib"]
[features]
kvo = []
[dependencies]
mlsr = {{ path = {json.dumps(str(MLSR / "crates/mlsr"))}, features = ["coreml"] }}
cidre = {{ version = "=0.29.0", default-features = false, features = ["ml", "macos_15_0", "ios_18_0"] }}
''')
    lock = workspace / "Cargo.lock"
    if not lock.exists():
        shutil.copyfile(MLSR / "Cargo.lock", lock)
    label = "-".join(
        [
            variant,
            member,
            "kvo" if kvo else "ml",
            prefix or "default",
            "objc" if force else "normal",
            "debug" if debug else "release",
        ]
    )
    env = ENV.copy()
    if prefix is not None:
        env["CIDRE_OBJC_CLASS_PREFIX"] = prefix
    if force:
        env["RUSTFLAGS"] = "-C link-arg=-ObjC"
    args = [
        "cargo",
        "+stable",
        "build",
        "--offline",
        "-p",
        member,
        "--target-dir",
        str(TARGET),
    ]
    if not debug:
        args.append("--release")
    if kvo:
        args += [
            "--features",
            "kvo,cidre/ns-observer" if variant == "optional" else "kvo",
        ]
    result = subprocess.run(
        args, cwd=workspace, env=env, capture_output=True, text=True
    )
    (LOGS / f"{label}.build.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        print(result.stdout + result.stderr, flush=True)
        raise RuntimeError(f"{label} failed")
    source = (
        TARGET
        / ("debug" if debug else "release")
        / f"lib{member.replace('-', '_')}.dylib"
    )
    destination = ARTIFACTS / f"{label}.dylib"
    shutil.copyfile(source, destination)
    symbols = subprocess.check_output(["nm", "-a", str(destination)], text=True)
    (LOGS / f"{label}.symbols.txt").write_text(symbols)
    classes = sorted(set(re.findall(r"\b[stS] +_OBJC_CLASS_\$_(\w+)", symbols)))
    RESULTS["builds"][label] = {
        "bytes": destination.stat().st_size,
        "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
        "observer_classes": [n for n in classes if "CidreObserver" in n],
    }
    expected_classes = [f"{prefix}_CidreObserver" if prefix else "CidreObserver"]
    if (variant == "optional" and not kvo) or (
        variant == "split" and not kvo and not force
    ):
        expected_classes = []
    assert RESULTS["builds"][label]["observer_classes"] == expected_classes
    save()
    print(label, RESULTS["builds"][label], flush=True)
    return destination


def pair(label, libraries, expected_warning):
    for reverse in [False, True]:
        name = label + ("-reverse" if reverse else "-forward")
        paths = list(reversed(libraries)) if reverse else libraries
        config = LOGS / f"{name}.json"
        config.write_text(
            json.dumps(
                {
                    "libraries": list(map(str, paths)),
                    "model": str(ROOT / "model/affine.mlmodelc"),
                }
            )
        )
        result = subprocess.run(
            [sys.executable, str(ROOT / "runner.py"), str(config)],
            capture_output=True,
            text=True,
            timeout=90,
        )
        (LOGS / f"{name}.load.log").write_text(
            f"exit={result.returncode}\n{result.stdout}{result.stderr}"
        )
        warning = (
            "Class " in result.stderr and " is implemented in both " in result.stderr
        )
        row = {
            "exit": result.returncode,
            "duplicate_class_warning": warning,
            "stdout": result.stdout.strip(),
            "expected_warning": expected_warning,
        }
        RESULTS["pairs"][name] = row
        save()
        print(name, row, flush=True)
        if result.returncode != 0 or (
            expected_warning is not None and warning != expected_warning
        ):
            raise RuntimeError(f"{name} failed: {result.stderr}")


def main():
    (ROOT / "model").mkdir(exist_ok=True)
    subprocess.run(
        [
            "xcrun",
            "coremlcompiler",
            "compile",
            str(MLSR / "tests/fixtures/coreml/affine.mlmodel"),
            str(ROOT / "model"),
        ],
        check=True,
    )
    stock = [build("stock", n) for n in ["probe-a", "probe-b"]]
    pair("stock-coreml", stock, True)
    optional = [build("optional", n) for n in ["probe-a", "probe-b"]]
    pair("optional-off-coreml", optional, False)
    pair(
        "optional-off-plus-existing-mlsr",
        [optional[0], MLSR / "target/release/libmlsr_ffi.dylib"],
        False,
    )
    optional_kvo = [build("optional", n, kvo=True) for n in ["probe-a", "probe-b"]]
    pair("optional-on-kvo", optional_kvo, True)
    split = [build("split", n) for n in ["probe-a", "probe-b"]]
    pair("split-coreml", split, False)
    split_kvo = [build("split", n, kvo=True) for n in ["probe-a", "probe-b"]]
    pair("split-kvo", split_kvo, True)
    namespaced = [
        build("namespaced", n, kvo=True, prefix=prefix)
        for n, prefix in [("probe-a", "MlsrProbe"), ("probe-b", "PodocoProbe")]
    ]
    pair("namespaced-kvo", namespaced, False)
    split_force = [build("split", n, force=True) for n in ["probe-a", "probe-b"]]
    pair("split-forced-objc", split_force, True)
    optional_force = [build("optional", n, force=True) for n in ["probe-a", "probe-b"]]
    pair("optional-off-forced-objc", optional_force, False)
    optional_debug = [build("optional", n, debug=True) for n in ["probe-a", "probe-b"]]
    pair("optional-off-debug", optional_debug, False)

    same_prefix = build("namespaced", "probe-b", kvo=True, prefix="MlsrProbe")
    pair("namespaced-same-prefix-control", [namespaced[0], same_prefix], True)
    for label, variant, prefix, expected in [
        ("optional-api-disabled", "optional", None, "Observer"),
        (
            "invalid-namespace",
            "namespaced",
            "invalid-prefix!",
            "CIDRE_OBJC_CLASS_PREFIX must be",
        ),
    ]:
        environment = ENV.copy()
        if prefix is not None:
            environment["CIDRE_OBJC_CLASS_PREFIX"] = prefix
        command = [
            "cargo",
            "+stable",
            "build",
            "--offline",
            "--release",
            "-p",
            "probe-a",
            "--features",
            "kvo",
            "--target-dir",
            str(TARGET),
        ]
        result = subprocess.run(
            command,
            cwd=ROOT / "workspaces" / variant,
            env=environment,
            capture_output=True,
            text=True,
        )
        (LOGS / f"{label}.log").write_text(result.stdout + result.stderr)
        assert result.returncode != 0 and expected in result.stderr, label
        RESULTS.setdefault("negative_checks", {})[label] = {
            "expected_failure": True,
            "exit": result.returncode,
        }
        save()
    # The selected dependency inherits coreml from the workspace's probe crates.
    # Cargo rejects --features when -p selects a non-workspace package.
    command = [
        "cargo",
        "+stable",
        "test",
        "--offline",
        "-p",
        "mlsr",
        "--lib",
        "runtime::",
        "--target-dir",
        str(TARGET),
        "--",
        "--test-threads=1",
    ]
    result = subprocess.run(
        command,
        cwd=ROOT / "workspaces/optional",
        env=ENV,
        capture_output=True,
        text=True,
    )
    (LOGS / "mlsr-runtime-tests.log").write_text(result.stdout + result.stderr)
    assert result.returncode == 0, result.stderr
    assert (
        "runtime::coreml::tests::real_model_validates_inputs_retains_outputs_and_recovers_after_errors"
        in result.stdout
    )
    RESULTS["mlsr_runtime_tests"] = {
        "exit": result.returncode,
        "summary": [
            line
            for line in result.stdout.splitlines()
            if line.startswith("test result:")
        ],
    }
    save()
    print("Completed observer investigation:", ROOT, flush=True)


if __name__ == "__main__":
    main()
