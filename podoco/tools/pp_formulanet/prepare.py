#!/usr/bin/env python3
"""Prepare the pinned FormulaNet bundle from explicit local sources, offline.

Compilation is explicit and writes only to a fresh destination. Large payloads
use APFS clones on macOS; no changes are made to the research checkout/cache.
"""

import argparse
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / "model-manifests/pp-formulanet-plus-l-coreml-v1.yaml"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check(path, entry):
    if path.stat().st_size != entry["bytes"] or digest(path) != entry["sha256"]:
        raise ValueError(f"pinned bytes changed: {path}")


def compilation():
    compiler = Path(
        subprocess.check_output(
            ["xcrun", "--find", "coremlcompiler"], text=True
        ).strip()
    )
    return {
        "coremlcompiler_sha256": digest(compiler),
        "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
        "macos": platform.mac_ver()[0],
        "architecture": platform.machine(),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--research", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    pin = yaml.safe_load(PIN.read_text())
    export = args.research / "output/formulanet-optimized"
    for name, entry in pin["sources"].items():
        check(args.research / name, entry)
    for name, entry in pin["artifacts"].items():
        check(export / name, entry)
    for name, entry in pin["checkpoint"].items():
        check(args.checkpoint / name, entry)
    args.output.mkdir(parents=True, exist_ok=False)
    for source, names, prefix in [
        (export, pin["artifacts"], Path("export")),
        (args.checkpoint, pin["checkpoint"], Path("checkpoint")),
    ]:
        for name in names:
            if name == "model.safetensors":
                continue
            target = args.output / prefix / name
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["cp", "-c", str((source / name).resolve()), str(target)], check=True
            )
    compiled = args.output / "compiled"
    compiled.mkdir()
    for model in ("encoder", "decoder-c256", "decoder-c2048"):
        subprocess.run(
            [
                "xcrun",
                "coremlcompiler",
                "compile",
                str(args.output / "export" / f"{model}.mlpackage"),
                str(compiled),
            ],
            check=True,
        )
    files = []
    for path in sorted(args.output.rglob("*")):
        if path.is_file():
            files.append(
                {
                    "path": str(path.relative_to(args.output)),
                    "size_bytes": path.stat().st_size,
                    "sha256": digest(path),
                }
            )
    manifest = {
        "schema_version": 1,
        "id": pin["id"],
        "profile": pin["profile"],
        "qualification": "experimental",
        "contract_sha256": digest(PIN),
        "compilation": compilation(),
        "files": files,
    }
    (args.output / "podoco-bundle.yaml").write_text(
        yaml.safe_dump(manifest, sort_keys=False)
    )
    print(
        json.dumps(
            {
                "bundle": str(args.output),
                "files": len(files),
                "manifest_sha256": digest(args.output / "podoco-bundle.yaml"),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
