#!/usr/bin/env python3
"""Prepare pinned MathCAT rules from an existing offline 0.7.7 crate directory."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import yaml

ROOT = Path(__file__).resolve().parents[2]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--source", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    a = p.parse_args()
    pin_path = ROOT / "model-manifests/mathcat-rules-v1.yaml"
    pin = yaml.safe_load(pin_path.read_text())
    if a.output.exists() or a.output.is_symlink():
        raise FileExistsError(a.output)
    for entry in pin["files"]:
        path = a.source / entry["path"]
        if (
            path.stat().st_size != entry["size_bytes"]
            or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]
        ):
            raise ValueError(f"Rule payload differs: {path}")
    a.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".podoco-rules-", dir=a.output.parent
    ) as temporary:
        staged = Path(temporary) / "bundle"
        staged.mkdir()
        for entry in pin["files"]:
            source, dest = a.source / entry["path"], staged / entry["path"]
            dest.parent.mkdir(parents=True, exist_ok=True)
            if sys.platform == "darwin":
                subprocess.run(["cp", "-c", str(source), str(dest)], check=True)
            else:
                shutil.copyfile(source, dest)
            if hashlib.sha256(dest.read_bytes()).hexdigest() != entry["sha256"]:
                raise ValueError(f"Copied rule payload differs: {dest}")
        shutil.copyfile(pin_path, staged / "podoco-rules.yaml")
        if a.output.exists() or a.output.is_symlink():
            raise FileExistsError(a.output)
        staged.rename(a.output)
    print(f"Prepared {len(pin['files'])} verified files at {a.output}")


if __name__ == "__main__":
    main()
