#!/usr/bin/env python3
"""Prepare PoDoFo's native Podoco library and pinned offline Flutter asset pack."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

from verify_pdfrx_engine import verify as verify_renderer

APP = Path(__file__).resolve().parents[1]
WORKSPACE = APP.parent / "podoco"


def prepare():
    system = platform.system()
    native = {
        "Darwin": "libpodoco_ffi.dylib",
        "Windows": "podoco_ffi.dll",
        "Linux": "libpodoco_ffi.so",
    }[system]
    coreml = system == "Darwin" and platform.machine() == "arm64"
    command = [
        "cargo",
        "build",
        "--locked",
        "--release",
        "--target-dir",
        str(WORKSPACE / "target"),
        "-p",
        "podoco-ffi",
    ]
    command += ["--features", "coreml,math" if coreml else "math"]
    env = dict(os.environ)
    if system == "Darwin":
        env["MACOSX_DEPLOYMENT_TARGET"] = "15.0"
        env.pop("IPHONEOS_DEPLOYMENT_TARGET", None)
        env.pop("SDKROOT", None)
    subprocess.run(command, cwd=WORKSPACE, env=env, check=True)
    target = APP / ".podoco/native"
    target.mkdir(parents=True, exist_ok=True)
    temporary = target / "podoco_ffi.new"
    shutil.copy2(WORKSPACE / "target/release" / native, temporary)
    if system == "Darwin":
        subprocess.run(["codesign", "--force", "--sign", "-", temporary], check=True)
    temporary.replace(target / "podoco_ffi")
    (target / "provenance.json").write_text(
        json.dumps(
            {
                "system": system,
                "architecture": platform.machine(),
                "coreml": coreml,
                "math": True,
                "sha256": hashlib.sha256(
                    (target / "podoco_ffi").read_bytes()
                ).hexdigest(),
            },
            indent=2,
        )
        + "\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-config", type=Path, default=APP / "podoco-models.yaml")
    parser.add_argument("--replace-models", action="store_true",
                        help="Explicitly rebuild a verified generated package when its pins change")
    args = parser.parse_args()
    verify_renderer()
    root = APP / ".podoco"
    root.mkdir(exist_ok=True)
    lock = root / "prepare.lock"
    lock.mkdir()  # A preexisting lock needs inspection, never automatic removal.
    try:
        prepare()
        prepare_models(args.model_config.resolve(), args.replace_models)
    finally:
        lock.rmdir()


def resource_platform(system, machine):
    arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "x64", "amd64": "x64"}.get(machine.lower())
    os_name = {"Darwin": "macos", "Windows": "windows", "Linux": "linux"}.get(system)
    if arch is None or os_name is None:
        raise ValueError(f"Unsupported resource platform: {system}/{machine}")
    return f"{os_name}-{arch}"


def prepare_models(config, replace=False):
    command = ["cargo", "run", "--locked", "--release", "-p", "podoco-models", "--",
               "prepare-flutter", "--config", str(config), "--platform",
               resource_platform(platform.system(), platform.machine())]
    if replace:
        command.append("--replace")
    subprocess.run(command, cwd=WORKSPACE, check=True)


if __name__ == "__main__":
    main()
