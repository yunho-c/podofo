#!/usr/bin/env python3
"""Offline PP-DocLayoutV3 fixture checking, eager capture, and saved-output replay.

Decode follows the box/order subset of Transformers 5.8.1's Apache-2.0
PPDocLayoutV3ImageProcessor (PaddlePaddle and Hugging Face). Its exact source hash
is pinned in the bundle manifest. Polygon qualification remains outside M1.
"""

import argparse
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "tests/fixtures/pp_doclayout_v3"
MANIFEST = ROOT / "model-manifests/pp-doclayout-v3-coreml.yaml"
SMALL_OUTPUTS = ("logits", "pred_boxes", "order_logits")


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    Path(path).write_text(
        json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    )


def checked_pages():
    data = json.loads((FIXTURES / "pages.json").read_text())
    assert sha(ROOT / data["generator"]) == data["generator_sha256"], (
        "fixture generator changed"
    )
    for page in data["pages"]:
        path = FIXTURES / page["image"]
        assert sha(path) == page["sha256"], f"changed fixture: {path}"
        header = path.read_bytes()[:24]
        assert header[:8] == b"\x89PNG\r\n\x1a\n"
        assert struct.unpack(">II", header[16:24]) == (page["width"], page["height"])
    summary_path = FIXTURES / "reference-summary.json"
    if summary_path.exists():
        summary = json.loads(summary_path.read_text())
        by_name = {p["image"]: p for p in data["pages"]}
        for record in summary["pages"]:
            assert record["image_sha256"] == by_name[record["image"]]["sha256"]
            assert sha(FIXTURES / record["decoded"]) == record["decoded_sha256"]
    return data["pages"]


def load_reference(checkpoint):
    # No implicit Hub access, including when files are missing.
    os.environ["HF_HUB_OFFLINE"] = "1"
    import yaml
    import torch
    from transformers import AutoImageProcessor
    import transformers.models.pp_doclayout_v3.image_processing_pp_doclayout_v3 as processor_module
    import transformers.models.pp_doclayout_v3.modeling_pp_doclayout_v3 as model_module

    manifest = yaml.safe_load(MANIFEST.read_text())
    for name in ("torch", "torchvision", "transformers", "numpy", "Pillow"):
        assert version(name) == manifest["conversion"]["packages"][name], (
            f"reference version drift: {name}"
        )
    assert (
        sha(processor_module.__file__)
        == manifest["conversion"]["processor_source_sha256"]
    )
    assert sha(model_module.__file__) == manifest["conversion"]["model_source_sha256"]
    for name, expected in manifest["source"]["files"].items():
        assert sha(checkpoint / name) == expected, f"checkpoint drift: {name}"
    torch.set_num_threads(6)
    torch.manual_seed(0)
    processor = AutoImageProcessor.from_pretrained(checkpoint, local_files_only=True)
    return manifest, processor


def pixels(processor, page):
    from PIL import Image

    rgba = Image.open(FIXTURES / page["image"]).convert("RGBA")
    rgb = Image.alpha_composite(
        Image.new("RGBA", rgba.size, (255, 255, 255, 255)), rgba
    ).convert("RGB")
    return processor(images=rgb, return_tensors="pt")["pixel_values"]


def decode(processor, outputs, width, height):
    """Exact tensor operations/order of the pinned processor, preserving query IDs."""
    import torch

    logits, boxes = outputs["logits"], outputs["pred_boxes"]
    centers, dimensions = torch.split(boxes, 2, dim=-1)
    xyxy = torch.cat([centers - 0.5 * dimensions, centers + 0.5 * dimensions], dim=-1)
    xyxy = xyxy * torch.tensor([width, height, width, height])[None, None, :]
    scores, flat = torch.topk(logits.sigmoid().flatten(1), logits.shape[1], dim=-1)
    labels, query = flat % logits.shape[2], flat // logits.shape[2]
    boxes = xyxy.gather(1, query.unsqueeze(-1).repeat(1, 1, 4))
    ranks = processor._get_order_seqs(outputs["order_logits"]).gather(1, query)
    selected = scores[0] >= 0.30
    order, permutation = torch.sort(ranks[0][selected])
    return dict(
        query_ids=query[0][selected][permutation].tolist(),
        class_ids=labels[0][selected][permutation].tolist(),
        scores=scores[0][selected][permutation].tolist(),
        boxes=boxes[0][selected][permutation].tolist(),
        order_ranks=order.tolist(),
    )


def capture(checkpoint, output):
    import numpy as np
    import torch
    from transformers import AutoModelForObjectDetection

    pages = checked_pages()
    manifest, processor = load_reference(checkpoint)
    output.mkdir(parents=True, exist_ok=False)
    model = AutoModelForObjectDetection.from_pretrained(
        checkpoint, local_files_only=True, attn_implementation="eager"
    ).eval()
    records = []
    with torch.inference_mode():
        for page in pages:
            tensor = pixels(processor, page)
            prediction = model(pixel_values=tensor)
            small = {name: getattr(prediction, name) for name in SMALL_OUTPUTS}
            assert all(
                torch.isfinite(v).all()
                for v in [tensor, prediction.out_masks, *small.values()]
            )
            decoded = decode(processor, small, page["width"], page["height"])
            # Compare the selected subset with the actual upstream method. No
            # polygon data is promoted or exposed as a Podoco capability.
            official = processor.post_process_object_detection(
                prediction,
                threshold=0.30,
                target_sizes=[(page["height"], page["width"])],
            )[0]
            for ours, upstream in [
                ("scores", "scores"),
                ("class_ids", "labels"),
                ("boxes", "boxes"),
                ("order_ranks", "order_seq"),
            ]:
                assert decoded[ours] == official[upstream].tolist(), (
                    f"upstream mismatch: {ours}"
                )
            selected = list(dict.fromkeys(decoded["query_ids"]))[:8]
            mask_logits = prediction.out_masks[0, selected].numpy()
            archive = output / (Path(page["image"]).stem + ".npz")
            np.savez_compressed(
                archive,
                pixel_values=tensor.numpy(),
                **{name: value.numpy() for name, value in small.items()},
                selected_queries=np.array(selected, dtype=np.int64),
                selected_mask_logits=mask_logits,
                selected_masks_score030=(
                    torch.from_numpy(mask_logits).sigmoid() > 0.30
                ).numpy(),
                selected_masks_logit_zero=mask_logits > 0,
            )
            decoded_path = output / (archive.stem + "-decoded.json")
            write_json(decoded_path, decoded)
            records.append(
                dict(
                    image=page["image"],
                    image_sha256=page["sha256"],
                    archive=archive.name,
                    archive_sha256=sha(archive),
                    decoded=decoded_path.name,
                    decoded_sha256=sha(decoded_path),
                    detection_count=len(decoded["query_ids"]),
                    selected_mask_queries=selected,
                )
            )
            print(
                f"Captured {page['image']}: {len(decoded['query_ids'])} detections",
                flush=True,
            )
    report = dict(
        schema_version=1,
        manifest_sha256=sha(MANIFEST),
        runner_sha256=sha(__file__),
        decoded_coordinates="Source pixel-edge coordinates; pages.json supplies pixel_to_page and canonical page_space",
        reference="Unmodified eager FP32 CPU, six Torch threads; no Core ML execution or performance measurement",
        packages=manifest["conversion"]["packages"],
        pages=records,
        mask_note="Selected mask logits and both thresholds retained; logit-zero diagnostic is distinct from processor sigmoid > 0.30; no polygon qualification",
    )
    write_json(output / "capture.json", report)
    return report


def replay(checkpoint, output):
    import numpy as np
    import torch

    pages = {p["image"]: p for p in checked_pages()}
    _, processor = load_reference(checkpoint)
    report = json.loads((output / "capture.json").read_text())
    assert report["manifest_sha256"] == sha(MANIFEST), "manifest changed since capture"
    assert report["runner_sha256"] == sha(__file__), (
        "reference runner changed since capture"
    )
    assert {p["image"] for p in report["pages"]} == set(pages)
    for record in report["pages"]:
        assert sha(output / record["archive"]) == record["archive_sha256"]
        assert sha(output / record["decoded"]) == record["decoded_sha256"]
        page = pages[record["image"]]
        assert record["image_sha256"] == page["sha256"]
        with np.load(output / record["archive"], allow_pickle=False) as arrays:
            np.testing.assert_array_equal(
                pixels(processor, page).numpy(), arrays["pixel_values"]
            )
            decoded = decode(
                processor,
                {n: torch.from_numpy(arrays[n]) for n in SMALL_OUTPUTS},
                page["width"],
                page["height"],
            )
            assert decoded == json.loads((output / record["decoded"]).read_text())
            np.testing.assert_array_equal(
                arrays["selected_mask_logits"] > 0, arrays["selected_masks_logit_zero"]
            )
            np.testing.assert_array_equal(
                (
                    torch.from_numpy(arrays["selected_mask_logits"]).sigmoid() > 0.30
                ).numpy(),
                arrays["selected_masks_score030"],
            )
        print(
            f"Replayed {page['image']}: exact input, decoded layout/order, and selected-mask checks",
            flush=True,
        )


def index_legacy(research_root, corpus, output):
    """Retain the 50-page existing evidence inventory; never rerun inference."""
    evidence = research_root / "results/ppdoclayoutv3-coreml-20261025"
    arrays = research_root / "output/ppdoclayoutv3-prototype/validation-optimized-50"
    pages = json.loads((evidence / "validation-pages.json").read_text())
    assert len(pages) == 50
    records = []
    for page in pages:
        image = Path(page["image"]).name
        assert sha(corpus / image) == page["sha256"]
        archive = arrays / f"page-{page['index']:02d}.npz"
        records.append(
            dict(
                index=page["index"],
                image=image,
                image_sha256=page["sha256"],
                archive=str(archive.relative_to(research_root)),
                archive_sha256=sha(archive),
                decoded_reference=page["reference_predictions"],
                conversion_agreement=page["parity"]["detection"],
            )
        )
    write_json(
        output,
        dict(
            schema_version=1,
            source="docling-layout-heron-coreml",
            report="results/ppdoclayoutv3-coreml-20261025/REPORT.md",
            report_sha256=sha(evidence / "REPORT.md"),
            pages_json_sha256=sha(evidence / "validation-pages.json"),
            corpus_annotations_sha256=sha(corpus / "annotations.json"),
            known_extra_detection_pages=["0005219_page07.jpg", "0009027_page01.jpg"],
            note="External original corpus and captures; score-sorted legacy comparison data, not the native processor's reading-order-sorted SDK result schema. No new inference or redistribution of page images.",
            pages=records,
        ),
    )
    print("Indexed 50 existing hashed page captures; no inference run")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("check-fixtures")
    for command in ["capture", "replay"]:
        child = sub.add_parser(command)
        child.add_argument("--checkpoint", type=Path, required=True)
        child.add_argument("--output", type=Path, required=True)
    child = sub.add_parser("index-legacy")
    child.add_argument("--research-root", type=Path, required=True)
    child.add_argument("--corpus", type=Path, required=True)
    child.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "check-fixtures":
        print(
            f"Verified {len(checked_pages())} original PNG fixtures without ML dependencies"
        )
    elif args.command == "capture":
        capture(args.checkpoint, args.output)
    elif args.command == "replay":
        replay(args.checkpoint, args.output)
    else:
        index_legacy(args.research_root, args.corpus, args.output)


if __name__ == "__main__":
    main()
