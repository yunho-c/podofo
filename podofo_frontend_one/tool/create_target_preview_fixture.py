#!/usr/bin/env python3
"""Generate the deterministic M0 linked-object PDF and its geometry manifest.

Requires reportlab==5.1.0. Bounds in the manifest are displayed-page points,
top-left origin. This fixture defines targets; it does not implement resolution.
"""

import hashlib
import json
from pathlib import Path

from reportlab.lib.colors import HexColor
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.pdfgen.canvas import Canvas

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "test/fixtures/target_preview"
WIDTH, HEIGHT = 612, 792


def generate():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    path = OUTPUT / "linked_objects.pdf"
    canvas = Canvas(str(path), pagesize=(WIDTH, HEIGHT), invariant=1)
    canvas.setTitle("PoDoFo linked target baseline")
    canvas.setAuthor("PoDoFo test fixtures")
    cases = []

    def text(x, y, value, size=11, bold=False):
        canvas.setFillColor(HexColor("#172033"))
        canvas.setFont("Helvetica-Bold" if bold else "Helvetica", size)
        canvas.drawString(x, HEIGHT - y, value)

    def lines(x, y, values, size=10, leading=15):
        for index, value in enumerate(values):
            text(x, y + index * leading, value, size)

    def box(bounds, color):
        left, top, right, bottom = bounds
        canvas.setFillColor(HexColor(color))
        canvas.rect(left, HEIGHT - bottom, right - left, bottom - top, fill=1, stroke=0)

    def anchor(name, left, top):
        canvas.bookmarkPage(name, fit="XYZ", left=left, top=HEIGHT - top, zoom=0)

    def footer(number):
        text(48, 755, "PoDoFo M0 fixture - synthetic content", 9)
        text(550, 755, str(number), 9)

    specifications = [
        ("reference-23", "Citation [23]", "citation", 2, [48, 78],
         [[48, 78, 292, 129]], [[48, 146, 292, 197]],
         ["[23] Ada Example", "A complete bibliography entry."]),
        ("reference-24", "Citation [24]", "citation", 2, [48, 146],
         [[48, 146, 292, 197]], [[48, 78, 292, 129]],
         ["[24] Grace Example", "The neighboring bibliography entry."]),
        ("figure-4", "Figure 4", "figure", 2, [326, 230],
         [[326, 78, 564, 218], [326, 230, 564, 269]],
         [[326, 290, 564, 315]], ["Figure 4.", "Panel A", "Panel B"]),
        ("table-2", "Table 2", "table", 3, [48, 70],
         [[48, 70, 548, 98], [48, 110, 548, 250]],
         [[48, 290, 548, 330]], ["Table 2.", "Method", "Baseline"]),
        ("equation-7", "Equation (7)", "equation", 2, [326, 384],
         [[326, 384, 568, 422]], [[326, 458, 568, 496]],
         ["E = m c", "(7)"]),
        ("section-2-1", "Section 2.1", "section", 2, [48, 328],
         [[48, 328, 292, 407]], [[48, 444, 292, 485]],
         ["2.1 Target aware previews", "The opening paragraph"]),
    ]

    text(48, 60, "Linked target baseline", 24, True)
    lines(48, 92, [
        "Each link points to a specific object on a later page.",
        "The current reader shows a contextual crop. Future milestones will",
        "use the recorded target parts to evaluate semantic crop completeness.",
    ], 11, 18)
    for index, (name, label, kind, page, point, required, excluded, expected) in enumerate(specifications):
        top = 180 + index * 65
        right = 48 + stringWidth(label, "Helvetica", 14) + 20
        bounds = [48, top, right, top + 30]
        box(bounds, "#edf3ff")
        text(58, top + 20, label, 14)
        canvas.linkRect("", name, (48, HEIGHT - top - 30, right, HEIGHT - top),
                        relative=0, thickness=0)
        cases.append({
            "id": name, "kind": kind, "source_page": 1,
            "source_text": label, "source_bounds": bounds,
            "destination": {"page": page, "command": "xyz", "point": point},
            "required_parts": required, "excluded_neighbors": excluded,
            "expected_target_text": expected,
        })
    footer(1)
    canvas.showPage()

    text(48, 44, "References and visual targets", 18, True)
    anchor("reference-23", 48, 78)
    lines(48, 91, ["[23] Ada Example and Alan Sample.",
                  "A complete bibliography entry.",
                  "Journal of Preview Testing, 2026."])
    anchor("reference-24", 48, 146)
    lines(48, 159, ["[24] Grace Example and Edsger Sample.",
                   "The neighboring bibliography entry.",
                   "Proceedings of Nearby Objects, 2026."])
    box([326, 78, 439, 218], "#dceafe")
    box([451, 78, 564, 218], "#dff1e8")
    text(350, 104, "Panel A", 12, True)
    text(475, 104, "Panel B", 12, True)
    for offset, height in [(0, 30), (25, 65), (50, 45)]:
        box([343 + offset, 200 - height, 359 + offset, 200], "#4383bd")
        box([468 + offset, 200 - height / 2, 484 + offset, 200], "#3b8b6c")
    anchor("figure-4", 326, 230)
    lines(326, 243, ["Figure 4. Two related panels.",
                   "Both panels and this caption are required."])
    lines(326, 303, ["Unrelated prose below the figure."], 10)

    anchor("section-2-1", 48, 328)
    text(48, 343, "2.1 Target aware previews", 13, True)
    lines(48, 368, ["The opening paragraph belongs to this section.",
                   "It provides context without including the next",
                   "heading or the separate right-hand column."])
    text(48, 460, "2.2 An unrelated section", 13, True)
    text(48, 480, "This content must remain outside the target.", 10)

    anchor("equation-7", 326, 384)
    text(360, 408, "E = m c", 17)
    text(421, 400, "2", 10)
    text(542, 408, "(7)", 12)
    text(360, 482, "a + b = c", 17)
    text(542, 482, "(8)", 12)
    footer(2)
    canvas.showPage()

    text(48, 44, "Table target", 18, True)
    anchor("table-2", 48, 70)
    text(48, 87, "Table 2. Timing and rate for two synthetic methods.", 12)
    box([48, 110, 548, 155], "#edf3ff")
    canvas.setStrokeColor(HexColor("#718198"))
    for y in [110, 155, 202, 250]:
        canvas.line(48, HEIGHT - y, 548, HEIGHT - y)
    for x in [48, 280, 414, 548]:
        canvas.line(x, HEIGHT - 110, x, HEIGHT - 250)
    for x, value in [(60, "Method"), (292, "Rate"), (426, "Time")]:
        text(x, 138, value, 12, True)
    for y, row in [(184, ["Baseline", "0.30", "10 ms"]),
                   (232, ["Target aware", "0.25", "12 ms"])]:
        for x, value in zip([60, 292, 426], row):
            text(x, y, value, 12)
    lines(48, 304, ["The paragraph after the table is not part of its caption.",
                   "A complete crop includes all rows and the caption above."], 11)
    footer(3)
    canvas.save()
    manifest = {
        "schema_version": 1, "coordinate_space": "displayed_page_points_top_left",
        "page_numbering": "one_based", "pdf": path.name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "page_sizes": [[WIDTH, HEIGHT]] * 3, "cases": cases,
    }
    (OUTPUT / "linked_objects.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Created {path}: {len(cases)} internal links")


if __name__ == "__main__":
    generate()
