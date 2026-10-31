#!/usr/bin/env python3
"""Explicit offline M2 integration qualification; leaves M1's oracle unchanged."""

import argparse
import json
import os
from pathlib import Path
import subprocess

from reference import (
    FIXTURES,
    ROOT,
    SMALL_OUTPUTS,
    checked_pages,
    load_reference,
    sha,
    write_json,
)


def stable_decode(outputs, width, height):
    import torch

    logits = torch.from_numpy(outputs["logits"])
    boxes = torch.from_numpy(outputs["pred_boxes"])
    order = torch.from_numpy(outputs["order_logits"])
    scores = logits.sigmoid().flatten()
    candidates = torch.argsort(scores, descending=True, stable=True)[:300]
    candidates = candidates[scores[candidates] >= 0.30].tolist()
    probabilities = order.sigmoid()
    votes = (
        probabilities.triu(1).sum(dim=1)
        + (1 - probabilities.transpose(1, 2)).tril(-1).sum(dim=1)
    )[0]
    candidates.sort(key=lambda i: (float(votes[i // 25]), i // 25, i % 25))
    center, size = boxes.split(2, dim=-1)
    xyxy = torch.cat([center - 0.5 * size, center + 0.5 * size], dim=-1)[0]
    xyxy *= torch.tensor([width, height, width, height])
    return dict(
        ids=candidates,
        scores=[float(scores[i]) for i in candidates],
        boxes=[xyxy[i // 25].tolist() for i in candidates],
        votes=votes.tolist(),
    )


def prepare(args):
    import numpy as np
    from PIL import Image

    _, processor = load_reference(args.checkpoint)
    args.output.mkdir(parents=True, exist_ok=False)
    cases = []

    def save(name, rgba, archive=None):
        rgb = Image.alpha_composite(
            Image.new("RGBA", rgba.size, (255, 255, 255, 255)), rgba
        ).convert("RGB")
        tensor = processor(images=rgb, return_tensors="pt")["pixel_values"].numpy()
        rgba_path = args.output / f"{name}.rgba"
        rgba_path.write_bytes(rgba.tobytes())
        tensor.astype("<f4").tofile(args.output / f"{name}.reference-input.f32")
        case = dict(
            id=name, width=rgba.width, height=rgba.height, rgba_sha256=sha(rgba_path)
        )
        if archive:
            with np.load(archive, allow_pickle=False) as saved:
                outputs = {n: saved[n] for n in SMALL_OUTPUTS}
                for n, v in outputs.items():
                    v.astype("<f4").tofile(args.output / f"{name}.{n}.f32")
                if "pixel_values" in saved:
                    np.testing.assert_array_equal(tensor, saved["pixel_values"])
                write_json(
                    args.output / f"{name}.reference-decoded.json",
                    stable_decode(outputs, rgba.width, rgba.height),
                )
            case["archive_sha256"] = sha(archive)
        cases.append(case)

    for page in checked_pages():
        name = Path(page["image"]).stem
        save(
            name,
            Image.open(FIXTURES / page["image"]).convert("RGBA"),
            args.capture / f"{name}.npz",
        )
    rng = np.random.default_rng(1729)
    for width, height in [
        (1, 1),
        (1, 19),
        (37, 1),
        (799, 801),
        (1603, 173),
        (37, 2033),
        (800, 800),
    ]:
        save(
            f"random-{width}x{height}",
            Image.fromarray(rng.integers(0, 256, (height, width, 4), dtype=np.uint8)),
        )
    write_json(args.output / "cases.json", cases)
    write_json(
        args.output / "provenance.json",
        dict(
            runner_sha256=sha(__file__),
            checkpoint=str(args.checkpoint),
            capture=str(args.capture),
            reference="Pinned processor; original eager saved outputs; stable v1 ties",
        ),
    )


def rust(args):
    env = dict(os.environ, PODOCO_M2_EXCHANGE=str(args.output.resolve()))
    subprocess.run(
        [
            "cargo",
            "test",
            "--release",
            "-p",
            "podoco",
            "--lib",
            "qualification_exchange",
            "--",
            "--ignored",
            "--exact",
            "pipelines::layout::tests::qualification_exchange",
        ],
        cwd=ROOT,
        env=env,
        check=True,
    )


def compare(args):
    import numpy as np

    records = []
    for case in json.loads((args.output / "cases.json").read_text()):
        name = case["id"]
        expected = np.fromfile(args.output / f"{name}.reference-input.f32", dtype="<f4")
        actual = np.fromfile(args.output / f"{name}.rust-input.f32", dtype="<f4")
        np.testing.assert_array_equal(actual, expected, err_msg=name)
        record = dict(id=name, input_exact=True)
        path = args.output / f"{name}.reference-decoded.json"
        if path.exists():
            reference = json.loads(path.read_text())
            regions = json.loads(
                (args.output / f"{name}.rust-decoded.json").read_text()
            )["regions"]
            assert [r["id"] for r in regions] == reference["ids"], (
                f"{name}: selected pair/order mismatch"
            )
            scores = np.array([r["score"] for r in regions])
            boxes = np.array([r["bounds"] for r in regions])
            # Scores and normalized coordinates have separate stated gates.
            np.testing.assert_allclose(scores, reference["scores"], rtol=0, atol=1e-6)
            scale = np.array([case["width"], case["height"]] * 2)
            np.testing.assert_allclose(
                boxes / scale, np.array(reference["boxes"]) / scale, rtol=0, atol=1e-6
            )
            record.update(
                detections=len(regions),
                selected_pairs_and_order_exact=True,
                max_score_error=float(
                    np.max(np.abs(scores - reference["scores"]), initial=0)
                ),
                max_normalized_box_error=float(
                    np.max(
                        np.abs((boxes - np.array(reference["boxes"])) / scale),
                        initial=0,
                    )
                ),
            )
        records.append(record)
        print(
            f"{name}: exact preprocessing; decoding checked where captured", flush=True
        )
    write_json(
        args.output / "comparison.json",
        dict(cases=records, runner_sha256=sha(__file__)),
    )


def append_corpus(args):
    import numpy as np
    from PIL import Image

    _, processor = load_reference(args.checkpoint)
    cases = json.loads((args.output / "cases.json").read_text())
    for case in cases:
        case["native_policies"] = (
            ["cpu", "cpu-ne", "all"]
            if case["id"] in ["columns", "equations", "raster"]
            else []
        )
    assert not any(c["id"].startswith("ibem-") for c in cases), (
        "corpus already appended"
    )
    index = json.loads((FIXTURES / "ibem50.json").read_text())
    assert sha(args.corpus / "annotations.json") == index["corpus_annotations_sha256"]
    for page in index["pages"]:
        name = f"ibem-{page['index']:02d}"
        path = args.corpus / page["image"]
        assert sha(path) == page["image_sha256"]
        archive = args.research / page["archive"]
        assert sha(archive) == page["archive_sha256"]
        rgba = Image.open(path).convert("RGBA")
        rgba_path = args.output / f"{name}.rgba"
        rgba_path.write_bytes(rgba.tobytes())
        tensor = processor(images=rgba.convert("RGB"), return_tensors="pt")[
            "pixel_values"
        ].numpy()
        tensor.astype("<f4").tofile(args.output / f"{name}.reference-input.f32")
        with np.load(archive, allow_pickle=False) as saved:
            outputs = {n: saved[f"actual_{n}"] for n in SMALL_OUTPUTS}
            for n, v in outputs.items():
                v.astype("<f4").tofile(args.output / f"{name}.{n}.f32")
            write_json(
                args.output / f"{name}.reference-decoded.json",
                stable_decode(outputs, rgba.width, rgba.height),
            )
            # Eager-vs-export evidence stays separate from integration parity.
            eager = {n: saved[f"reference_{n}"] for n in SMALL_OUTPUTS}
            write_json(
                args.output / f"{name}.eager-decoded.json",
                stable_decode(eager, rgba.width, rgba.height),
            )
        policies = ["cpu-ne"]
        if page["image"] in index["known_extra_detection_pages"]:
            policies = ["cpu", "cpu-ne", "all"]
        cases.append(
            dict(
                id=name,
                width=rgba.width,
                height=rgba.height,
                rgba_sha256=sha(rgba_path),
                image=page["image"],
                image_sha256=page["image_sha256"],
                archive_sha256=page["archive_sha256"],
                native_policies=policies,
            )
        )
    write_json(args.output / "cases.json", cases)
    print(
        "Appended 50 verified corpus pages; shared Pillow-decoded RGBA input",
        flush=True,
    )


def native_rust(args):
    env = dict(
        os.environ,
        PODOCO_M2_EXCHANGE=str(args.output.resolve()),
        PODOCO_M2_BUNDLE=str(args.bundle.resolve()),
        PODOCO_M2_POLICY=args.policy,
    )
    subprocess.run(
        [
            "cargo",
            "test",
            "--release",
            "--locked",
            "-p",
            "podoco",
            "--features",
            "coreml",
            "--lib",
            "native_qualification_exchange",
            "--",
            "--ignored",
            "--exact",
            "pipelines::layout::tests::native_qualification_exchange",
        ],
        cwd=ROOT,
        env=env,
        check=True,
    )


def native_python(args):
    import numpy as np
    import coremltools as ct
    import platform
    import time
    from importlib.metadata import version

    assert version("coremltools") == "9.0"
    source = json.loads((args.output / "provenance.json").read_text())
    load_reference(Path(source["checkpoint"]))
    policy = {
        "cpu": ct.ComputeUnit.CPU_ONLY,
        "cpu-ne": ct.ComputeUnit.CPU_AND_NE,
        "all": ct.ComputeUnit.ALL,
    }[args.policy]
    start = time.perf_counter()
    model = ct.models.CompiledMLModel(
        str(args.bundle / "optimized-mixed.mlmodelc"), compute_units=policy
    )
    opened = time.perf_counter() - start
    records = []
    for case in json.loads((args.output / "cases.json").read_text()):
        if args.policy not in case.get("native_policies", []):
            continue
        name = case["id"]
        tensor = np.fromfile(
            args.output / f"{name}.reference-input.f32", dtype="<f4"
        ).reshape(1, 3, 800, 800)
        for repeat in range(2):
            start = time.perf_counter()
            outputs = model.predict({"pixel_values": tensor})
            elapsed = time.perf_counter() - start
            assert all(np.isfinite(value).all() for value in outputs.values())
            for label in SMALL_OUTPUTS:
                outputs[label].astype("<f4").tofile(
                    args.output / f"{name}.{args.policy}.python-{repeat}.{label}.f32"
                )
            write_json(
                args.output / f"{name}.{args.policy}.python-{repeat}.json",
                stable_decode(outputs, case["width"], case["height"]),
            )
            records.append(
                dict(
                    id=name,
                    repeat=repeat,
                    prediction_seconds=elapsed,
                    masks_finite=True,
                )
            )
    write_json(
        args.output / f"{args.policy}.python-native-report.json",
        dict(
            open_seconds=opened,
            records=records,
            host=platform.platform(),
            runner_sha256=sha(__file__),
        ),
    )


def native_compare(args):
    import numpy as np

    records = []
    for case in json.loads((args.output / "cases.json").read_text()):
        if args.policy not in case.get("native_policies", []):
            continue
        name = case["id"]
        record = dict(id=name, tensors={})
        for label in SMALL_OUTPUTS:

            def load(language, repeat):
                return np.fromfile(
                    args.output
                    / f"{name}.{args.policy}.{language}-{repeat}.{label}.f32",
                    dtype="<f4",
                )

            p0, p1, r0, r1 = (
                load("python", 0),
                load("python", 1),
                load("rust", 0),
                load("rust", 1),
            )
            assert p0.shape == r0.shape == p1.shape == r1.shape
            control = float(np.max(np.abs(p0 - p1), initial=0))
            rust_control = float(np.max(np.abs(r0 - r1), initial=0))
            integration = float(
                max(
                    np.max(np.abs(r0 - p0), initial=0),
                    np.max(np.abs(r1 - p1), initial=0),
                )
            )
            record["tensors"][label] = dict(
                python_repeat_max=control,
                rust_repeat_max=rust_control,
                integration_max=integration,
            )
            assert integration <= max(control, rust_control), (
                f"{name}/{label}: Rust differs outside repeated-control envelope: {record}"
            )
        for repeat in range(2):
            expected = json.loads(
                (args.output / f"{name}.{args.policy}.python-{repeat}.json").read_text()
            )
            regions = json.loads(
                (args.output / f"{name}.{args.policy}.rust-{repeat}.json").read_text()
            )["regions"]
            assert [r["id"] for r in regions] == expected["ids"], (
                f"{name}: native decoded order mismatch"
            )
            np.testing.assert_allclose(
                [r["score"] for r in regions], expected["scores"], rtol=0, atol=1e-6
            )
            scale = np.array([case["width"], case["height"]] * 2)
            np.testing.assert_allclose(
                np.array([r["bounds"] for r in regions]) / scale,
                np.array(expected["boxes"]) / scale,
                rtol=0,
                atol=1e-6,
            )
        records.append(record)
    assert records, "no controls selected"
    write_json(
        args.output / f"{args.policy}.native-comparison.json",
        dict(cases=records, runner_sha256=sha(__file__)),
    )
    print(
        f"{args.policy}: {len(records)} pages x 2 predictions; raw tensors within repeated-control envelope; decoded parity passed",
        flush=True,
    )


def classify_ties(args):
    import numpy as np
    import torch
    from reference import decode

    _, processor = load_reference(args.checkpoint)
    records = []
    shapes = {
        "logits": (1, 300, 25),
        "pred_boxes": (1, 300, 4),
        "order_logits": (1, 300, 300),
    }
    for case in json.loads((args.output / "cases.json").read_text()):
        name = case["id"]
        if not (args.output / f"{name}.logits.f32").exists():
            continue
        outputs = {
            k: torch.from_numpy(
                np.fromfile(args.output / f"{name}.{k}.f32", dtype="<f4").reshape(shape)
            )
            for k, shape in shapes.items()
        }
        old = decode(processor, outputs, case["width"], case["height"])
        old_ids = [q * 25 + c for q, c in zip(old["query_ids"], old["class_ids"])]
        stable = json.loads(
            (args.output / f"{name}.reference-decoded.json").read_text()
        )
        assert set(old_ids) == set(stable["ids"])
        ranks = {v: i for i, v in enumerate(stable["ids"])}
        inversions = []
        for i, a in enumerate(old_ids):
            for b in old_ids[i + 1 :]:
                if ranks[a] > ranks[b]:
                    assert stable["votes"][a // 25] == stable["votes"][b // 25]
                    inversions.append([a, b])
        if inversions:
            records.append(dict(id=name, tie_only_inversions=inversions))
    write_json(
        args.output / "tie-classification.json",
        dict(
            pages=records,
            all_selected_pairs_unchanged=True,
            all_untied_order_unchanged=True,
            runner_sha256=sha(__file__),
        ),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=[
            "prepare",
            "append-corpus",
            "rust",
            "compare",
            "native-rust",
            "native-python",
            "native-compare",
            "classify-ties",
        ],
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument(
        "--capture", type=Path, default=ROOT / "evaluation-output/m1-reference-v2"
    )
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--research", type=Path)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--policy", choices=["cpu", "cpu-ne", "all"], default="cpu-ne")
    args = parser.parse_args()
    if (
        args.command in ["prepare", "append-corpus", "classify-ties"]
        and args.checkpoint is None
    ):
        parser.error(f"{args.command} requires --checkpoint")
    if args.command == "append-corpus" and (
        args.corpus is None or args.research is None
    ):
        parser.error("append-corpus requires --corpus and --research")
    if args.command in ["native-rust", "native-python"] and args.bundle is None:
        parser.error(f"{args.command} requires --bundle")
    globals()[args.command.replace("-", "_")](args)


if __name__ == "__main__":
    main()
