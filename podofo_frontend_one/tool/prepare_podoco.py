#!/usr/bin/env python3
"""Build PoDoFo's host Podoco artifact; model preparation remains explicit."""

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
    verify_renderer()
    root = APP / ".podoco"
    root.mkdir(exist_ok=True)
    lock = root / "prepare.lock"
    lock.mkdir()  # A preexisting lock needs inspection, never automatic removal.
    try:
        prepare()
    finally:
        lock.rmdir()


if __name__ == "__main__":
    main()
