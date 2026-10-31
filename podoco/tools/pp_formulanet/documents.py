#!/usr/bin/env python3
"""Qualify complete documents and original-pixel detector crops in explicit stages."""

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def dump(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def native(a):
    from PIL import Image

    a.output.mkdir(parents=True, exist_ok=False)
    cases = [
        r
        for r in json.loads((a.fixtures / "cases.json").read_text())
        if r["id"].startswith("ibem-")
    ]
    assert len(cases) == 50
    entries, paths = [], []
    document = {"id": "png-sequence", "revision": "1"}
    for i, r in enumerate(cases):
        raw = a.fixtures / (r["id"] + ".rgba")
        assert sha(raw) == r["rgba_sha256"]
        image = Image.frombytes("RGBA", (r["width"], r["height"]), raw.read_bytes())
        path = a.output / (r["id"] + ".png")
        image.save(path)
        paths.append(str(path))
        entries.append(
            {
                "page": {
                    "key": {"document": document, "page_index": i},
                    "space": [r["width"], r["height"]],
                },
                "image": {
                    "width": r["width"],
                    "height": r["height"],
                    "row_stride": r["width"] * 4,
                    "format": "rgba8",
                    "alpha": "straight",
                },
                "pixel_to_page": [1, 0, 0, 1, 0, 0],
                "render_profile": "png-pixel-space-v1",
                "pixels": raw.as_uri(),
            }
        )
    dump(a.output / "pages.json", {"document": document, "pages": entries})
    dump(a.output / "cases.json", cases)
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
            "document_layout",
        ],
        cwd=ROOT,
        check=True,
    )
    binary = ROOT / "target/release/examples/document_layout"
    args = [
        "--formula",
        str(a.formula),
        "2048",
        str(48 * 1024**2),
        str(a.layout),
        "cpu-ne",
        str(16 * 1024**2),
        str(128 * 1024**2),
        str(4 * 1024**2),
        str(2 * 1024**2),
        "2",
    ]
    dump(a.output / "cli-args.json", args)
    sources = {
        str(p.relative_to(ROOT)): sha(p)
        for p in [
            ROOT / "Cargo.lock",
            *sorted((ROOT / "crates/podoco/src").rglob("*.rs")),
            ROOT / "crates/podoco/examples/document_layout.rs",
            Path(__file__),
        ]
    }
    counts, first_formula, started = Counter(), None, time.perf_counter()
    with (
        (a.output / "rust.jsonl").open("w") as out,
        (a.output / "rust.log").open("w") as log,
    ):
        process = subprocess.Popen(
            [str(binary), *args, *paths],
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=log,
            text=True,
        )
        for line in process.stdout:
            out.write(line)
            out.flush()
            row = json.loads(line)
            kind = row["payload"]["type"]
            counts[kind] += 1
            if kind == "formula_finished" and first_formula is None:
                first_formula = time.perf_counter() - started
            if kind == "page_finished":
                print(
                    f"Native page {counts[kind]}/50; {counts['formula_finished']} formulas",
                    flush=True,
                )
        code = process.wait()
    failures = []
    if code or counts["page_finished"] != 50 or counts["document_finished"] != 1:
        failures.append("incomplete native document")
    for p, digest in sources.items():
        if sha(ROOT / p) != digest:
            failures.append(f"source changed: {p}")
    dump(
        a.output / "native-summary.json",
        {
            "binary_sha256": sha(binary),
            "sources": sources,
            "layout_manifest": sha(a.layout / "podoco-bundle.yaml"),
            "formula_manifest": sha(a.formula / "podoco-bundle.yaml"),
            "cases_sha256": sha(a.output / "cases.json"),
            "output_sha256": sha(a.output / "rust.jsonl"),
            "exit_code": code,
            "updates": counts,
            "first_formula_seconds": first_formula,
            "document_seconds": time.perf_counter() - started,
            "failures": failures,
            "boundary": "One serial native CPU+ANE document job on an active host; timings are diagnostics only.",
        },
    )
    if failures:
        raise RuntimeError(failures)


def reference(a):
    import yaml
    import torch
    from PIL import Image
    from transformers import AutoProcessor

    # Execute only the exact research runner included in the pinned handoff.
    pin = yaml.safe_load(
        (ROOT / "model-manifests/pp-formulanet-plus-l-coreml-v1.yaml").read_text()
    )
    runner = a.research / "conversion/formulanet/benchmark.py"
    handoff = json.loads(
        (a.research / "results/ppformulanet-coreml-20261025/manifest.json").read_text()
    )
    assert (
        sha(a.research / "results/ppformulanet-coreml-20261025/manifest.json")
        == pin["handoff_sha256"]
    )
    for path, entry in handoff["sources"].items():
        assert sha(a.research / path) == entry["sha256"]
    from importlib.metadata import version
    import inspect
    from transformers.models.pp_formulanet import (
        image_processing_pp_formulanet,
        processing_pp_formulanet,
    )

    for name, expected in pin["packages"].items():
        assert version(name) == expected
    for module in [image_processing_pp_formulanet, processing_pp_formulanet]:
        path = Path(inspect.getfile(module))
        assert sha(path) == pin["processor_sources"][path.name]
    for path, entry in pin["checkpoint"].items():
        if path != "model.safetensors":
            assert sha(a.formula / "checkpoint" / path) == entry["sha256"]
    sys.path.insert(0, str(runner.parent))
    from benchmark import CoreMLRunner

    torch.set_num_threads(6)
    processor = AutoProcessor.from_pretrained(
        a.formula / "checkpoint", local_files_only=True
    )
    model = CoreMLRunner(a.formula / "export", "cpu-ne")
    pages = [
        json.loads(line)["payload"]["page"]
        for line in (a.output / "rust.jsonl").read_text().splitlines()
        if json.loads(line)["payload"]["type"] == "page_finished"
    ]
    cases = json.loads((a.output / "cases.json").read_text())
    failures, counts = [], Counter()
    with (a.output / "reference.jsonl").open("x") as out:
        for page, case in zip(pages, cases, strict=True):
            image = Image.open(a.output / (case["id"] + ".png")).convert("RGB")
            regions = {r["id"]: r for r in page["regions"]}
            for formula in page["formulas"]:
                region = regions[formula["region_id"]]
                left, top, right, bottom = region["bounds"]
                crop = [
                    max(0, math.floor(left)),
                    max(0, math.floor(top)),
                    min(image.width, math.ceil(right)),
                    min(image.height, math.ceil(bottom)),
                ]
                pixels = processor(images=image.crop(crop), return_tensors="pt")[
                    "pixel_values"
                ]
                ids, _ = model.generate(pixels, 2048)
                raw = processor.decode(ids, skip_special_tokens=True)
                latex = processor.post_process_generation(raw)
                status = (
                    "recognized"
                    if ids[-1] == 2 and latex.strip()
                    else "failed"
                    if ids[-1] == 2
                    else "truncated"
                )
                actual = formula["state"]["outcome"]
                actual_latex = actual.get("formula", {}).get(
                    "latex", actual.get("partial_latex")
                )
                matched = status == actual["status"] and (latex or None) == actual_latex
                record = {
                    "page": case["id"],
                    "region_id": region["id"],
                    "display_kind": region["display_kind"],
                    "crop": crop,
                    "pixels_sha256": hashlib.sha256(
                        pixels.numpy().tobytes()
                    ).hexdigest(),
                    "ids": ids,
                    "raw": raw,
                    "latex": latex,
                    "status": status,
                    "matched": matched,
                }
                out.write(json.dumps(record, ensure_ascii=False) + "\n")
                out.flush()
                counts[status] += 1
                counts[region["display_kind"]] += 1
                if not matched:
                    failures.append({"page": case["id"], "region_id": region["id"]})
            print(
                f"Reference {case['id']}: {sum(counts[k] for k in ['recognized', 'truncated', 'failed'])} crops",
                flush=True,
            )
    dump(
        a.output / "reference-summary.json",
        {
            "counts": counts,
            "mismatches": failures,
            "reference_sha256": sha(a.output / "reference.jsonl"),
            "runner_sha256": sha(runner),
        },
    )
    if failures:
        raise RuntimeError(failures)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("stage", choices=["native", "reference"])
    for name in ["layout", "formula", "fixtures", "research", "output"]:
        p.add_argument("--" + name, type=lambda v: Path(v).resolve(), required=True)
    a = p.parse_args()
    {"native": native, "reference": reference}[a.stage](a)


if __name__ == "__main__":
    main()
