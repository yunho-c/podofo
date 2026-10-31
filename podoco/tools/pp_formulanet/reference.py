#!/usr/bin/env python3
"""Capture exact offline processor inputs/text outputs; never run inference."""

import argparse
import hashlib
from importlib.metadata import version
import inspect
import json
import yaml
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--research", type=Path, required=True)
    ap.add_argument("--bundle", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--all", action="store_true")
    a = ap.parse_args()
    import numpy as np
    from PIL import Image
    import torch
    from transformers import AutoProcessor
    from transformers.models.pp_formulanet import (
        image_processing_pp_formulanet as ip,
        processing_pp_formulanet as pp,
    )

    pin = yaml.safe_load(
        (ROOT / "model-manifests/pp-formulanet-plus-l-coreml-v1.yaml").read_text()
    )
    for name, expected in pin["packages"].items():
        assert version(name) == expected, (name, version(name), expected)
    for module in [ip, pp]:
        path = Path(inspect.getfile(module))
        assert sha(path) == pin["processor_sources"][path.name]
    checkpoint = a.bundle / "checkpoint"
    for name, entry in pin["checkpoint"].items():
        if name != "model.safetensors":
            assert sha(checkpoint / name) == entry["sha256"]
    p = AutoProcessor.from_pretrained(checkpoint, local_files_only=True)
    torch.set_num_threads(6)
    a.output.mkdir(parents=True, exist_ok=False)
    corpus = a.research / "results/ibem50-recognition-20261025/crops.json"
    crops = json.loads(corpus.read_text())
    selected = (
        crops["expressions"]
        if a.all
        else [r for r in crops["expressions"] if r["id"] in crops["pilot_ids"]]
    )
    images = []
    for record in selected:
        path = corpus.parent / record["image"]
        assert sha(path) == record["crop_sha256"]
        images.append((record["id"], Image.open(path).convert("RGBA")))
    rng = np.random.default_rng(1641)
    for w, h in [
        (1, 1),
        (31, 17),
        (17, 31),
        (768, 768),
        (1001, 97),
        (93, 1043),
        (997, 1013),
        (2048, 3),
    ]:
        images.append(
            (
                f"random-{w}x{h}",
                Image.fromarray(
                    rng.integers(0, 256, (h, w, 3), dtype=np.uint8)
                ).convert("RGBA"),
            )
        )
    for color in [(255, 255, 255, 255), (0, 0, 0, 255), (12, 52, 87, 128)]:
        images.append((f"uniform-{color[0]}", Image.new("RGBA", (57, 29), color)))
    records = []
    marker = Image.new("RGBA", (11, 9), "white")
    for y in range(3, 6):
        for x in range(3, 8):
            marker.putpixel((x, y), (12, 12, 12, 255))
    marker.putpixel((1, 1), (220, 222, 52, 255))
    images.append(("gray-fma-boundary", marker))
    # All RGB triples in blue/red/green order qualify fused grayscale rounding.
    from torchvision.transforms.v2.functional import rgb_to_grayscale

    red_green = np.indices((256, 256)).astype(np.uint8)
    gray_hash = hashlib.sha256()
    for blue in range(256):
        rgb = np.stack(
            [red_green[0], red_green[1], np.full((256, 256), blue, np.uint8)]
        )
        gray_hash.update(rgb_to_grayscale(torch.from_numpy(rgb)).numpy().tobytes())
    for name, image in images:
        rgb = Image.alpha_composite(
            Image.new("RGBA", image.size, "white"), image
        ).convert("RGB")
        values = (
            p(images=rgb, return_tensors="pt")["pixel_values"].numpy().astype("<f4")
        )
        rgba = a.output / f"{name}.rgba"
        rgba.write_bytes(image.tobytes())
        image.save(a.output / f"{name}.png")
        records.append(
            {
                "id": name,
                "width": image.width,
                "height": image.height,
                "rgba_sha256": sha(rgba),
                "pixels_sha256": hashlib.sha256(values.tobytes()).hexdigest(),
            }
        )
        # Small pilot tensors aid diagnosis without saving 811 full tensors.
        if not a.all:
            (a.output / f"{name}.f32").write_bytes(values.tobytes())
    text_records = []
    for path in [
        a.research
        / "results/ppformulanet-coreml-811-20261026-ac"
        / run
        / "predictions.jsonl"
        for run in ["04-cpu", "02-cpu-ne"]
    ]:
        for line in path.read_text().splitlines():
            r = json.loads(line)
            raw = p.decode(r["token_ids"], skip_special_tokens=True)
            latex = p.post_process_generation(raw)
            assert raw == r["raw_decoded"] and latex == r["prediction"]
            text_records.append(
                {
                    "id": r["id"],
                    "run": path.parent.name,
                    "ids": r["token_ids"],
                    "raw": raw,
                    "latex": latex,
                }
            )
    special = [
        r"\text {中文} + x = 1",
        r"\mathrm { \alpha x }",
        r"\text {hello world}",
        "x &lt; 2",
        "e\u0301 + ﬁ + Ａ + ’",
        "cafÃ©",
        '"x"',
        "x\x1b[31m + y\r\n",
    ]
    extra = [{"raw": s, "latex": p.post_process_generation(s)} for s in special]
    (a.output / "reference.json").write_text(
        json.dumps(
            {
                "images": records,
                "texts": text_records,
                "special": extra,
                "rgb_grayscale_sha256": gray_hash.hexdigest(),
                "corpus_sha256": sha(corpus),
                "generator_sha256": sha(Path(__file__)),
            },
            ensure_ascii=False,
            indent=2,
        )
        + "\n"
    )
    print(
        json.dumps(
            {"images": len(records), "texts": len(text_records), "special": len(extra)}
        )
    )


if __name__ == "__main__":
    main()
