#!/usr/bin/env python3
"""Generate original, redistributable M1 pages using Pillow 10.4.0.

Only fixture regeneration requires Pillow; checking committed PNG hashes does not.
Text and page designs are original Apache-2.0 project fixtures. Pillow's bundled
font is used for rasterization; no font program or third-party document is copied.
"""

import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, __version__

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "tests/fixtures/pp_doclayout_v3"


def main():
    if __version__ != "10.4.0":
        raise RuntimeError("Fixture regeneration requires the pinned Pillow 10.4.0")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    large = ImageFont.load_default(size=32)
    body = ImageFont.load_default(size=17)
    math = ImageFont.load_default(size=28)
    records = []

    def save(image, name, transform, space, description):
        path = OUTPUT / name
        image.save(path, compress_level=9)
        records.append(
            dict(
                image=name,
                sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                width=image.width,
                height=image.height,
                mode=image.mode,
                pixel_to_page=transform,
                page_space=space,
                description=description,
            )
        )

    image = Image.new("RGB", (640, 800), "white")
    draw = ImageDraw.Draw(image)
    draw.text((35, 30), "A small document experiment", font=large, fill="black")
    for column, x in enumerate([35, 340]):
        draw.text((x, 100), f"Section {column + 1}", font=math, fill="black")
        for row in range(14):
            draw.text(
                (x, 150 + row * 27),
                [
                    "We study a simple example.",
                    "The page has two columns.",
                    "Each line is original text.",
                ][row % 3],
                font=body,
                fill="black",
            )
    draw.rectangle((45, 580, 590, 715), outline="black", width=2)
    for y in [625, 670]:
        draw.line((45, y, 590, y), fill="black", width=1)
    for x in [220, 405]:
        draw.line((x, 580, x, 715), fill="black", width=1)
    draw.text((65, 595), "Input", font=body, fill="black")
    draw.text((245, 595), "Output", font=body, fill="black")
    draw.text((430, 595), "Check", font=body, fill="black")
    save(
        image,
        "columns.png",
        [1, 0, 0, 1, 0, 0],
        [640, 800],
        "Original two-column prose and table geometry",
    )

    image = Image.new("RGB", (800, 1000), "white")
    draw = ImageDraw.Draw(image)
    draw.text((50, 40), "Notes on simple equations", font=large, fill="black")
    for y, text in [
        (130, "Let x = y + 1 describe the first relation."),
        (180, "The expression a + b occurs inside this sentence."),
        (370, "Substitute the first relation into the next equation."),
        (610, "The two lines below form one displayed calculation."),
        (850, "These examples test layout, not mathematical accuracy."),
    ]:
        draw.text((50, y), text, font=body, fill="black")
    for y, text in [
        (270, "x^2 + y^2 = z^2"),
        (470, "f(x) = (x + 1) / (x - 1)"),
        (700, "a + b = c"),
        (745, "c - b = a"),
    ]:
        draw.text((210, y), text, font=math, fill="black")
    draw.text((715, 275), "(1)", font=body, fill="black")
    draw.text((715, 475), "(2)", font=body, fill="black")
    save(
        image,
        "equations.png",
        [1, 0, 0, 1, 0, 0],
        [800, 1000],
        "Original inline and displayed equation-like text with separate numbers",
    )

    image = Image.new("RGBA", (257, 193), (255, 255, 255, 0))
    draw = ImageDraw.Draw(image)
    draw.rectangle((0, 0, 45, 35), fill=(255, 0, 0, 255))
    draw.rectangle((210, 0, 256, 35), fill=(0, 255, 0, 128))
    draw.rectangle((210, 155, 256, 192), fill=(0, 0, 255, 64))
    draw.rectangle((0, 155, 45, 192), fill=(0, 0, 0, 255))
    draw.text((35, 80), "A + B = C", font=math, fill=(0, 0, 0, 255))
    save(
        image,
        "raster.png",
        [0, 1, -1, 0, 193, 0],
        [193, 257],
        "Odd raster dimensions, straight alpha, colored corners, rotated page mapping",
    )
    manifest = dict(
        schema_version=1,
        license="Apache-2.0",
        provenance="Original synthetic project pages; no third-party document pages",
        generator="tools/pp_doclayout_v3/generate.py",
        generator_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        pillow=__version__,
        font="Pillow bundled default font, rasterized only",
        pages=records,
    )
    (OUTPUT / "pages.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Generated {len(records)} original page fixtures")


if __name__ == "__main__":
    main()
