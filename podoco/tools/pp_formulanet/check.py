#!/usr/bin/env python3
"""Serial native single-crop qualification against a captured reference."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--bundle", type=Path, required=True)
    p.add_argument("--reference", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument(
        "--policies", nargs="+", choices=["cpu", "cpu-ne"], default=["cpu", "cpu-ne"]
    )
    a = p.parse_args()
    a.bundle, a.reference, a.output = (
        a.bundle.resolve(),
        a.reference.resolve(),
        a.output.resolve(),
    )
    a.output.mkdir(parents=True, exist_ok=False)
    subprocess.run(
        [
            "cargo",
            "build",
            "--locked",
            "--release",
            "-p",
            "podoco",
            "--features",
            "coreml",
            "--example",
            "formula",
        ],
        cwd=ROOT,
        check=True,
    )
    executable = ROOT / "target/release/examples/formula"
    reference = json.loads((a.reference / "reference.json").read_text())
    corpus_ids = {r["id"] for r in reference["texts"]}
    crops = [r for r in reference["images"] if r["id"] in corpus_ids]
    source_paths = [
        ROOT / "Cargo.lock",
        ROOT / "crates/podoco/Cargo.toml",
        *sorted((ROOT / "crates/podoco/src/formula").glob("*.rs")),
        ROOT / "crates/podoco/src/runtime/coreml/formula.rs",
        ROOT / "crates/podoco/src/runtime/coreml/tensor.rs",
        Path(__file__),
    ]
    sources = {str(path.relative_to(ROOT)): sha(path) for path in source_paths}
    summary = {
        "started": datetime.now(timezone.utc).isoformat(),
        "macos": platform.mac_ver()[0],
        "hardware": subprocess.check_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"], text=True
        ).strip(),
        "power_start": subprocess.check_output(["pmset", "-g", "batt"], text=True),
        "binary_sha256": sha(executable),
        "manifest_sha256": sha(a.bundle / "podoco-bundle.yaml"),
        "reference_sha256": sha(a.reference / "reference.json"),
        "sources": sources,
        "runs": [],
        "boundary": "Parity qualification, one serial process per policy; active host, no performance comparison or placement claim.",
    }
    failures = []
    for policy in a.policies:
        path = a.output / f"{policy}.jsonl"
        with path.open("w") as output, (a.output / f"{policy}.log").open("w") as errors:
            completed = subprocess.run(
                [
                    str(executable),
                    str(a.bundle),
                    policy,
                    "2048",
                    *[str(a.reference / (r["id"] + ".png")) for r in crops],
                ],
                cwd=ROOT,
                stdout=output,
                stderr=errors,
            )
        rows = [json.loads(line) for line in path.read_text().splitlines()]
        expected = {
            r["id"]: r
            for r in reference["texts"]
            if r["run"] == {"cpu": "04-cpu", "cpu-ne": "02-cpu-ne"}[policy]
        }
        mismatches = []
        for row in rows:
            name = Path(row["input"]).stem
            ref = expected[name]
            outcome = row["outcome"]
            latex = outcome.get("formula", {}).get(
                "latex", outcome.get("partial_latex")
            )
            for field, actual, wanted in [
                ("tokens", row["stats"]["last_token_ids"], ref["ids"]),
                ("raw", row["stats"]["last_raw_text"], ref["raw"]),
                ("latex", latex, ref["latex"]),
                (
                    "status",
                    outcome["status"],
                    "recognized" if ref["ids"][-1] == 2 else "truncated",
                ),
            ]:
                if actual != wanted:
                    mismatches.append({"id": name, "field": field})
        run = {
            "policy": policy,
            "exit_code": completed.returncode,
            "expected": len(crops),
            "completed": len(rows),
            "mismatches": mismatches,
            "output_sha256": sha(path),
            "cache_peak": max(
                (r["stats"]["peak_decoder_cache_bytes"] for r in rows), default=0
            ),
            "tensor_peak": max(
                (r["stats"]["peak_tensor_bytes"] for r in rows), default=0
            ),
        }
        summary["runs"].append(run)
        if completed.returncode or len(rows) != len(crops) or mismatches:
            failures.append(policy)
        print(json.dumps(run), flush=True)
    for path, digest in sources.items():
        if sha(ROOT / path) != digest:
            failures.append(f"changed source: {path}")
    if (
        sha(executable) != summary["binary_sha256"]
        or sha(a.bundle / "podoco-bundle.yaml") != summary["manifest_sha256"]
    ):
        failures.append("binary or manifest changed during qualification")
    summary.update(
        completed=datetime.now(timezone.utc).isoformat(),
        failures=failures,
        power_end=subprocess.check_output(["pmset", "-g", "batt"], text=True),
    )
    (a.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    sys.exit(bool(failures))


if __name__ == "__main__":
    main()
