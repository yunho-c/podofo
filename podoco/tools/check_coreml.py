#!/usr/bin/env python3
"""Build and co-load Podoco's actual cidre dependency on macOS."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

from verify_cidre import verify

ROOT = Path(__file__).resolve().parents[1]


def load_pair(model, libraries):
    """Run in a fresh child so Objective-C registration warnings are observable."""
    loaded = [ctypes.CDLL(str(path), mode=ctypes.RTLD_LOCAL) for path in libraries]
    probes = []
    for library in loaded:
        if hasattr(library, "podoco_coreml_probe"):
            probe = library.podoco_coreml_probe
            probe.argtypes = [ctypes.c_char_p]
            probe.restype = ctypes.c_int
            probes.append(probe)
        else:
            version = library.mlsr_version
            version.argtypes = []
            version.restype = ctypes.c_char_p
            if not version():
                raise RuntimeError("MLSR did not return its version")
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda probe: probe(os.fsencode(model)), probes * 4))
    if not probes or any(results):
        raise RuntimeError(f"Core ML inference failed: {results}")
    print(json.dumps({"probe_calls": len(results), "predictions": len(results) * 3}))


def check(output, mlsr_library):
    if sys.platform != "darwin":
        raise RuntimeError("The Core ML coexistence check requires macOS and Xcode")
    verify()
    output.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="15.0")
    environment.pop("RUSTFLAGS", None)
    environment.pop("CARGO_ENCODED_RUSTFLAGS", None)
    records = {
        "status": "running",
        "host": platform.mac_ver()[0],
        "architecture": platform.machine(),
        "rust": subprocess.check_output(
            ["rustc", "--version"], cwd=ROOT, text=True
        ).strip(),
        "cargo_lock_sha256": hashlib.sha256(
            (ROOT / "Cargo.lock").read_bytes()
        ).hexdigest(),
        "cidre_pin_sha256": hashlib.sha256(
            (ROOT / "third_party/cidre-source.json").read_bytes()
        ).hexdigest(),
        "builds": {},
        "pairs": {},
    }
    (output / "results.json").write_text(json.dumps(records, indent=2) + "\n")

    def command(label, arguments, env=environment):
        result = subprocess.run(
            arguments, cwd=ROOT, env=env, capture_output=True, text=True, timeout=300
        )
        (output / f"{label}.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(f"{label} failed:\n{result.stdout}{result.stderr}")
        return result

    def build(label, *, observer=False, debug=False, force_objc=False):
        arguments = [
            "cargo",
            "build",
            "--locked",
            "-p",
            "podoco",
            "--example",
            "coreml_probe",
            "--features",
            "coreml,cidre/ns-observer" if observer else "coreml",
            "--target-dir",
            str(ROOT / "target"),
        ]
        if not debug:
            arguments.append("--release")
        env = environment.copy()
        if force_objc:
            env["RUSTFLAGS"] = "-C link-arg=-ObjC"
        command(label, arguments, env)
        profile = "debug" if debug else "release"
        library = output / f"{label}.dylib"
        shutil.copyfile(
            ROOT / f"target/{profile}/examples/libcoreml_probe.dylib", library
        )
        symbols = command(label + "-symbols", ["nm", "-a", str(library)]).stdout
        has_observer = "_OBJC_CLASS_$_CidreObserver" in symbols
        if has_observer != observer:
            raise RuntimeError(
                f"{label}: unexpected CidreObserver presence: {has_observer}"
            )
        # Ensure absence is measured in a library that actually uses Core ML.
        if "_ML_MODEL" not in symbols:
            raise RuntimeError(f"{label}: the Core ML bridge was not linked")
        records["builds"][label] = {
            "bytes": library.stat().st_size,
            "sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
            "observer": has_observer,
        }
        print(f"{label}: observer={has_observer}", flush=True)
        return library

    model_dir = output / "model"
    model_dir.mkdir(exist_ok=True)
    command(
        "compile-model",
        [
            "xcrun",
            "coremlcompiler",
            "compile",
            str(ROOT / "tests/fixtures/coreml/affine.mlmodel"),
            str(model_dir),
        ],
    )
    model = model_dir / "affine.mlmodelc"
    # Enabled control has the same unprefixed class as an unpatched MLSR build.
    control = build("observer-enabled", observer=True)
    candidates = [
        build("observer-disabled"),
        build("observer-disabled-debug", debug=True),
        build("observer-disabled-objc", force_objc=True),
    ]

    def pair(label, libraries):
        for reverse in [False, True]:
            name = label + ("-reverse" if reverse else "-forward")
            paths = list(reversed(libraries)) if reverse else libraries
            result = command(
                name,
                [
                    sys.executable,
                    str(Path(__file__).resolve()),
                    "--load",
                    str(model),
                    *map(str, paths),
                ],
            )
            if " is implemented in both " in result.stderr:
                raise RuntimeError(
                    f"{name}: duplicate Objective-C class:\n{result.stderr}"
                )
            records["pairs"][name] = json.loads(result.stdout)
            print(f"{name}: {result.stdout.strip()}", flush=True)

    for candidate in candidates:
        pair(candidate.stem, [candidate, control])
    if mlsr_library:
        pair("existing-mlsr", [candidates[0], mlsr_library.resolve(strict=True)])
        records["mlsr_library_sha256"] = hashlib.sha256(
            mlsr_library.read_bytes()
        ).hexdigest()
    records["status"] = "passed"
    records["scope"] = (
        "CPU-only affine fixture; existing MLSR identity only when supplied"
    )
    (output / "results.json").write_text(json.dumps(records, indent=2) + "\n")
    print(f"Core ML coexistence checks passed. Evidence: {output}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "target/coreml-check")
    parser.add_argument("--mlsr-library", type=Path)
    parser.add_argument("--load", nargs="+", help=argparse.SUPPRESS)
    args = parser.parse_args()
    try:
        if args.load:
            load_pair(Path(args.load[0]), [Path(path) for path in args.load[1:]])
        else:
            check(args.output.resolve(), args.mlsr_library)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Core ML check failed: {error}\n")


if __name__ == "__main__":
    main()
