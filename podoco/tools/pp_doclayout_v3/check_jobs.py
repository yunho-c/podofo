#!/usr/bin/env python3
"""Explicit M3 native-job parity gate using an existing verified local bundle."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def run(command, log, *, env=None):
    with log.open("w") as output:
        subprocess.run(
            command,
            cwd=ROOT,
            env=env,
            stdout=output,
            stderr=subprocess.STDOUT,
            check=True,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    run(
        [
            "cargo",
            "test",
            "--release",
            "--locked",
            "-p",
            "podoco",
            "--features",
            "coreml",
            "jobs::tests::native_document_jobs_match_blocking_pages_and_reuse_model",
            "--",
            "--ignored",
            "--exact",
        ],
        output / "native-test.log",
        env=dict(os.environ, PODOCO_M2_BUNDLE=str(bundle)),
    )
    run(
        [
            "cargo",
            "build",
            "--release",
            "--locked",
            "-p",
            "podoco",
            "--features",
            "coreml",
            "--example",
            "page_layout",
            "--example",
            "document_layout",
        ],
        output / "build.log",
    )
    pages = [
        ROOT / "tests/fixtures/pp_doclayout_v3" / f"{name}.png"
        for name in ("columns", "equations", "raster")
    ]
    base = [str(bundle), "cpu-ne", "4000000", "96000000"]
    for name, extra in [
        ("page_layout", ["250000"]),
        ("document_layout", ["500000", "250000", "2"]),
    ]:
        with (output / f"{name}.jsonl").open("w") as data:
            with (output / f"{name}-report.json").open("w") as report:
                subprocess.run(
                    [
                        str(ROOT / "target/release/examples" / name),
                        *base,
                        *extra,
                        *map(str, pages),
                    ],
                    cwd=ROOT,
                    stdout=data,
                    stderr=report,
                    check=True,
                )
    expected = [
        json.loads(line)
        for line in (output / "page_layout.jsonl").read_text().splitlines()
    ]
    updates = [
        json.loads(line)
        for line in (output / "document_layout.jsonl").read_text().splitlines()
    ]
    outcome = json.loads((output / "document_layout-report.json").read_text())
    assert len(updates) == 7 and len(expected) == 3
    for index, page in enumerate(expected):
        for offset, kind in enumerate(("page_layout_ready", "page_finished")):
            update = updates[2 * index + offset]
            assert update["sequence"] == 2 * index + offset
            assert update["payload"] == {"type": kind, "page": page}
    assert updates[-1]["payload"]["type"] == "document_finished"
    assert updates[-1]["sequence"] == 6
    assert updates[-1]["payload"]["summary"] == outcome["summary"]
    assert outcome["status"] == "completed"
    assert outcome["delivered"] == {
        "updates_acknowledged": 7,
        "last_sequence": 6,
        "pages_finished": 3,
        "formulas_finished": 0,
        "document_finished": True,
    }
    p = outcome["progress"]
    assert p["input_bytes"] == p["pending_result_bytes"] == p["pending_updates"] == 0
    assert p["peak_input_bytes"] <= 4_000_000
    assert p["peak_result_bytes"] <= 500_000 and p["peak_pending_updates"] <= 2
    summary = {
        "gate": "m3-native-jobs-v1",
        "policy": "cpu_and_neural_engine",
        "native_test": {
            "predictions": 9,
            "model_loads": 1,
            "pages": 3,
            "document_repetitions": 2,
            "exact_page_equality": True,
            "rotated_mapping": True,
        },
        "cli": {
            "predictions": 6,
            "updates": 7,
            "exact_page_equality": True,
            "outcome": outcome,
        },
        "source_sha256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted((ROOT / "crates/podoco/src/jobs").glob("*.rs"))
        },
        "fixture_sha256": {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in pages
        },
        "manifest_sha256": hashlib.sha256(
            (bundle / "podoco-bundle.yaml").read_bytes()
        ).hexdigest(),
        "scope": "Integration parity and bounded job lifecycle; no new quality or performance claim",
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("M3 native jobs and CLI parity passed (15 predictions).")


if __name__ == "__main__":
    main()
