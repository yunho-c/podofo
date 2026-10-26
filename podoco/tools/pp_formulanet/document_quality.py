#!/usr/bin/env python3
"""Separate detector recall, matched-crop recognition and whole-page coverage."""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import statistics
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def area(box):
    return max(0, box[2] - box[0]) * max(0, box[3] - box[1])


def intersection(a, b):
    return area([max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])])


def iou(a, b):
    overlap = intersection(a, b)
    return overlap / max(area(a) + area(b) - overlap, 1e-20)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--documents", type=Path, required=True)
    p.add_argument("--research", type=Path, required=True)
    a = p.parse_args()
    corpus_path = a.research / "results/ibem50-recognition-20261025/crops.json"
    corpus = json.loads(corpus_path.read_text())
    baseline_path = (
        a.research
        / "results/ppformulanet-coreml-811-20261026-ac/02-cpu-ne/predictions.jsonl"
    )
    baseline = {
        r["id"]: r for r in map(json.loads, baseline_path.read_text().splitlines())
    }
    metrics_path = a.research / "evaluation/recognition/metrics.py"
    sys.path.insert(0, str(metrics_path.parent))
    from metrics import score

    cases = json.loads((a.documents / "cases.json").read_text())
    pages = [
        r["payload"]["page"]
        for r in map(json.loads, (a.documents / "rust.jsonl").read_text().splitlines())
        if r["payload"]["type"] == "page_finished"
    ]
    counts = Counter()
    matched, missed, unmatched, overlaps, numbers, duplicates = [], [], [], [], [], []
    for page, case in zip(pages, cases, strict=True):
        gt = [r for r in corpus["expressions"] if r["source_image"] == case["image"]]
        assert all(r["source_sha256"] == case["image_sha256"] for r in gt)
        gt_boxes = [
            [r["bbox"][i] * [case["width"], case["height"]][i % 2] for i in range(4)]
            for r in gt
        ]
        regions = [r for r in page["regions"] if r["category"] == "formula"]
        outcomes = {r["region_id"]: r["state"]["outcome"] for r in page["formulas"]}
        counts.update({"ground_truth": len(gt), "detections": len(regions), "pages": 1})
        counts.update(r["expr_type"] for r in gt)
        for region in regions:
            counts[region["display_kind"]] += 1
            counts[outcomes[region["id"]]["status"]] += 1
        # Greedy one-to-one matching, descending IoU, stable GT/detection tie breaks.
        edges = sorted(
            (
                (-iou(box, region["bounds"]), i, j)
                for i, box in enumerate(gt_boxes)
                for j, region in enumerate(regions)
            ),
            key=lambda v: v,
        )
        used_gt, used_det = set(), set()
        for negative, i, j in edges:
            if -negative < 0.5 or i in used_gt or j in used_det:
                continue
            used_gt.add(i)
            used_det.add(j)
            outcome = outcomes[regions[j]["id"]]
            latex = (
                outcome.get("formula", {}).get("latex", outcome.get("partial_latex"))
                or ""
            )
            record = {
                "page": case["id"],
                "gt": gt[i]["id"],
                "region_id": regions[j]["id"],
                "iou": -negative,
                "kind": gt[i]["expr_type"],
                "display_kind": regions[j]["display_kind"],
                "status": outcome["status"],
                "prediction": latex,
                "score": score(latex, gt[i]),
                "gt_crop_score": score(baseline[gt[i]["id"]]["prediction"], gt[i]),
            }
            matched.append(record)
        missed.extend(r["id"] for i, r in enumerate(gt) if i not in used_gt)
        unmatched.extend(
            {"page": case["id"], "region_id": r["id"]}
            for j, r in enumerate(regions)
            if j not in used_det
        )
        for i, first in enumerate(regions):
            for second in regions[i + 1 :]:
                overlap = iou(first["bounds"], second["bounds"])
                if overlap > 0:
                    overlaps.append(
                        {
                            "page": case["id"],
                            "regions": [first["id"], second["id"]],
                            "iou": overlap,
                            "inline": first["display_kind"] == "inline"
                            or second["display_kind"] == "inline",
                        }
                    )
            for number in page["regions"]:
                if number["category"] == "formula_number":
                    covered = intersection(first["bounds"], number["bounds"]) / max(
                        area(number["bounds"]), 1e-20
                    )
                    if covered >= 0.5:
                        numbers.append(
                            {
                                "page": case["id"],
                                "formula": first["id"],
                                "number": number["id"],
                                "number_fraction": covered,
                            }
                        )
        for i, first in enumerate(page["regions"]):
            for second in page["regions"][i + 1 :]:
                overlap = iou(first["bounds"], second["bounds"])
                if first["category"] == second["category"] and overlap >= 0.95:
                    duplicates.append(
                        {
                            "page": case["id"],
                            "category": first["category"],
                            "regions": [first["id"], second["id"]],
                            "iou": overlap,
                        }
                    )
    exact = sum(r["score"]["exact"] and r["status"] == "recognized" for r in matched)
    summary = {
        "counts": counts,
        "matched_iou050": len(matched),
        "detection_recall_iou050": len(matched) / counts["ground_truth"],
        "detection_precision_iou050": len(matched) / counts["detections"],
        "matched_recognition_exact": exact,
        "matched_recognition_mean_similarity": statistics.mean(
            r["score"]["similarity"] for r in matched
        ),
        "matched_gt_crop_exact": sum(r["gt_crop_score"]["exact"] for r in matched),
        "matched_gt_crop_mean_similarity": statistics.mean(
            r["gt_crop_score"]["similarity"] for r in matched
        ),
        "whole_pipeline_exact_over_all_gt": exact / counts["ground_truth"],
        "missed_ground_truth": missed,
        "unmatched_detections": unmatched,
        "overlapping_formula_pairs": overlaps,
        "number_overlap": numbers,
        "duplicate_regions_iou095": duplicates,
        "sources": {
            "corpus_sha256": sha(corpus_path),
            "baseline_sha256": sha(baseline_path),
            "metrics_sha256": sha(metrics_path),
            "native_sha256": sha(a.documents / "rust.jsonl"),
            "script_sha256": sha(Path(__file__)),
        },
        "interpretation": "50-document convenience sample. IoU >= 0.5 greedy one-to-one matching. LaTeX token edit similarity is not mathematical equivalence. GT baseline has two-pixel context; deployed detector crops have zero added context. No extra NMS, equation-number merging or duplicate suppression.",
    }
    (a.documents / "quality-matches.json").write_text(
        json.dumps(matched, indent=2, ensure_ascii=False) + "\n"
    )
    (a.documents / "quality-summary.json").write_text(
        json.dumps(summary, indent=2) + "\n"
    )
    print(
        json.dumps(
            {k: v for k, v in summary.items() if not isinstance(v, list)}, indent=2
        )
    )


if __name__ == "__main__":
    main()
