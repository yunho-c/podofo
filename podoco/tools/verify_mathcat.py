#!/usr/bin/env python3
"""Verify the pinned MathCAT host integration without network access."""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def verify():
    pin = json.loads((ROOT / "third_party/mathcat-source.json").read_text())
    root = ROOT / "third_party/mathcat"
    actual = {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in sorted(root.rglob("*"))
        if p.is_file()
    }
    if actual != pin["files"]:
        raise RuntimeError("Vendored MathCAT differs from its pinned inventory")
    if (
        hashlib.sha256((ROOT / "third_party" / pin["patch"]).read_bytes()).hexdigest()
        != pin["patch_sha256"]
    ):
        raise RuntimeError("MathCAT host patch differs from its pin")
    print(
        f"Verified {len(actual)} MathCAT source files and the host integration patch.",
        flush=True,
    )


if __name__ == "__main__":
    verify()
