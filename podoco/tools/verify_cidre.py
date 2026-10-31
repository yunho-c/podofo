#!/usr/bin/env python3
"""Verify the pinned, patched cidre source without network access."""

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def verify():
    provenance = json.loads((ROOT / "third_party/cidre-source.json").read_text())
    source = ROOT / "third_party/cidre"
    actual = {
        file.relative_to(source).as_posix(): hashlib.sha256(
            file.read_bytes()
        ).hexdigest()
        for file in source.rglob("*")
        if file.is_file()
    }
    expected = provenance["files"]
    mismatches = sorted(
        name
        for name in actual.keys() | expected.keys()
        if actual.get(name) != expected.get(name)
    )
    if mismatches:
        raise RuntimeError(
            "Vendored cidre differs from its pin: " + ", ".join(mismatches)
        )
    patch = ROOT / "third_party" / provenance["patch"]
    if hashlib.sha256(patch.read_bytes()).hexdigest() != provenance["patch_sha256"]:
        raise RuntimeError("The adopted cidre patch differs from its pin.")
    print(
        f"Verified {len(actual)} pinned cidre files and the observer patch.", flush=True
    )


if __name__ == "__main__":
    verify()
