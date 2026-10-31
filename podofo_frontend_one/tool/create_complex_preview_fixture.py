#!/usr/bin/env python3
"""M4 target oracle: original PDF pixels plus hand-annotated layout boundaries.

These annotations isolate grouping/rendering tests; they are not model output.
Requires reportlab==5.1.0 and pypdf==6.21.4. All annotations use displayed page points.
"""
import hashlib
import json
from pathlib import Path

from pypdf import PdfReader, PdfWriter
from reportlab.lib.colors import HexColor
from reportlab.pdfbase.pdfmetrics import stringWidth
from reportlab.pdfgen.canvas import Canvas

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "test/fixtures/target_preview"
W, H = 612, 792


def generate():
    raw = OUT / "complex_objects.unrotated.pdf"
    final = OUT / "complex_objects.pdf"
    c = Canvas(str(raw), pagesize=(W, H), invariant=1)
    c.setTitle("PoDoFo complete target fixtures")
    c.setAuthor("PoDoFo test fixtures")
    pages, regions = [], []

    def text(x, y, value, size=10, bold=False):
        c.setFillColor(HexColor("#172033"))
        c.setFont("Helvetica-Bold" if bold else "Helvetica", size)
        c.drawString(x, H - y, value)

    def lines(x, y, values, indent=12):
        for i, value in enumerate(values):
            text(x + (indent if i else 0), y + 15 * i, value)

    def region(category, subtype, bounds):
        regions.append({"id": len(regions) + 1, "category": category,
                        "native_subtype": subtype, "bounds": bounds})

    def anchor(name, x, y):
        c.bookmarkPage(name, fit="XYZ", left=x, top=H-y, zoom=0)

    def panel(bounds, label, color):
        x, top, right, bottom = bounds
        c.setFillColor(HexColor(color))
        c.rect(x, H-bottom, right-x, bottom-top, fill=1, stroke=0)
        text(x+12, top+24, label, 14, True)
        c.setStrokeColor(HexColor("#34516e"))
        c.line(x+20, H-bottom+20, right-20, H-top-42)
        region("figure", "image", bounds)

    def end(page):
        nonlocal regions
        text(36, 768, "PoDoFo M4 boundary fixtures", 8)
        text(570, 768, str(page), 8)
        pages.append({"size": [W, H], "regions": regions})
        regions = []
        c.showPage()

    def part(page, bounds):
        return {"page": page, "bounds": bounds}

    cases = [
        ("numbered-hanging", "Citation [31]", "citation", 2, [36, 78],
         [part(2, [36, 78, 284, 128])], [part(2, [36, 151, 284, 201])]),
        ("author-hanging", "Rivera et al. (2024)", "citation", 2, [328, 78],
         [part(2, [328, 78, 580, 158])], [part(2, [328, 181, 580, 231])]),
        ("cross-column", "Citation [41]", "citation", 3, [36, 663],
         [part(3, [36, 663, 284, 729]), part(3, [328, 52, 580, 103])],
         [part(3, [36, 80, 284, 131]), part(3, [328, 126, 580, 178])]),
        ("cross-page", "Citation [51]", "citation", 4, [328, 673],
         [part(4, [328, 673, 580, 724]), part(5, [36, 52, 284, 103])],
         [part(4, [328, 80, 580, 131]), part(5, [36, 126, 284, 178])]),
        ("separated-panels", "Figure 9", "figure", 2, [36, 474],
         [part(2, [36, 330, 280, 450]), part(2, [332, 330, 576, 450]),
          part(2, [36, 474, 576, 510])], [part(2, [292, 360, 320, 430])]),
        ("caption-above", "Figure 10", "figure", 3, [36, 245],
         [part(3, [36, 245, 284, 280]), part(3, [36, 300, 280, 440])],
         [part(3, [36, 470, 284, 490])]),
        ("multiline-equation", "Equation (12)", "equation", 3, [328, 357],
         [part(3, [340, 357, 516, 378]), part(3, [352, 388, 516, 410]),
          part(3, [542, 388, 576, 410])],
         [part(3, [340, 310, 576, 333]), part(3, [340, 456, 576, 479])]),
        ("section-opening", "Section 3.1", "section", 5, [328, 240],
         [part(5, [328, 240, 580, 263]), part(5, [328, 280, 580, 331])],
         [part(5, [328, 372, 580, 421])]),
        ("ambiguous-label", "Figures 9 and 10", None, 2, [36, 474], [], []),
        ("unfinished-entry", "Citation [61]", None, 5, [328, 673], [], []),
        ("rotated-cropped", "Figure 12", "figure", 6, [522, 20],
         [part(6, [542, 20, 682, 260]), part(6, [492, 20, 522, 260])],
         [part(6, [432, 20, 457, 260])]),
    ]
    manifest_cases = []
    text(36, 52, "Complete targets and hard boundaries", 21, True)
    text(36, 80, "Every included and excluded component is annotated before resolution.", 11)
    for i, (name, label, kind, page, point, required, excluded) in enumerate(cases):
        top = 122 + i * 50
        right = 48 + stringWidth(label, "Helvetica", 13)
        text(42, top+18, label, 13)
        c.linkRect("", name, (36, H-top-25, right+8, H-top), relative=0, thickness=0)
        manifest_cases.append({"id": name, "source_page": 1,
          "source_text": label, "source_bounds": [36, top, right+8, top+25],
          "kind": kind, "destination": {"page": page, "point": point},
          "required_parts": required, "excluded_neighbors": excluded})
    end(1)

    text(36, 44, "References and separated panels", 18, True)
    anchor("numbered-hanging", 36, 78)
    lines(36, 89, ["31. Ada Example and Alan Sample.",
      "A numbered entry with a hanging indent.", "Journal of Complete Targets, 2024."])
    lines(36, 162, ["32. Grace Example and Edsger Sample.",
      "This is the next bibliography entry.", "Neighboring Objects, 2025."])
    region("text", "reference", [35, 77, 285, 203])
    anchor("author-hanging", 328, 78)
    lines(328, 89, ["Rivera, A. and Park, B. (2024).",
      "Long references occupy several lines.", "The continuation has a hanging indent",
      "and belongs to the same complete entry.", "Journal of Targets, 12(3), 45-67."])
    lines(328, 192, ["Sato, C. and Ito, D. (2025).",
      "This separate entry must be excluded.", "Proceedings of Other Work, 8-19."])
    region("text", "reference", [327, 77, 581, 233])
    panel([36, 330, 280, 450], "(a) First panel", "#dceafe")
    panel([332, 330, 576, 450], "(b) Second panel", "#dff1e8")
    c.setFillColor(HexColor("#a52a35"))
    c.rect(292, H-430, 28, 70, fill=1, stroke=0)
    region("text", "text", [292, 360, 320, 430])
    anchor("separated-panels", 36, 474)
    anchor("ambiguous-label", 36, 474)
    lines(36, 486, ["Figure 9. Related panels with unrelated content in the gutter.",
      "Both panels and the complete caption are required."], indent=0)
    region("caption", "figure_title", [35, 473, 577, 511])
    end(2)

    text(36, 32, "Column continuation and equations", 17, True)
    lines(36, 91, ["[40] Earlier Author. A separate reference.",
      "Its text is unrelated to the target entry.", "Journal of Other References, 2020."])
    region("text", "reference_content", [35, 79, 285, 132])
    anchor("cross-column", 36, 663)
    lines(36, 674, ["[41] Ada Long and Alan Entry. (2022).",
      "A reference beginning at the bottom",
      "of the first column and continuing",
      "without a new entry boundary into the"])
    region("text", "reference_content", [35, 662, 285, 730])
    lines(328, 63, ["second column at the top of this page.",
      "All of these lines belong to reference 41.", "Journal of Boundary Tests, 9(2), 1-10."], indent=12)
    region("text", "reference_content", [327, 51, 581, 104])
    lines(328, 137, ["[42] Next Author. A new entry starts here.",
      "This text must not leak into reference 41.", "Other Journal, 2023."])
    region("text", "reference_content", [327, 125, 581, 179])
    anchor("caption-above", 36, 245)
    lines(36, 257, ["Figure 10. Caption above the visual.", "Its identity belongs to this panel."], indent=0)
    region("caption", "figure_title", [35, 244, 285, 281])
    panel([36, 300, 280, 440], "Panel under caption", "#e9e2f8")
    text(36, 482, "Unrelated paragraph below the figure.")
    region("text", "text", [35, 469, 285, 491])
    anchor("multiline-equation", 328, 357)
    for y, formula, number in [(325, "z = a + b", "(11)"), (373, "f(x) = a x + b", None),
                                (404, "      + c x x + d", "(12)"), (473, "g(x) = x - 1", "(13)")]:
        x = 340 if y != 404 else 352
        text(x, y, formula, 14)
        region("formula", "formula", [x-1, y-16, 518, y+4])
        if number:
            text(544, y, number, 12)
            region("formulaNumber", "formula_number", [542, y-16, 576, y+4])
    end(3)

    text(36, 44, "Reference crossing a page boundary", 18, True)
    lines(328, 91, ["[50] Another Author. Earlier entry.",
      "It is not part of the requested reference.", "Other Proceedings, 2021."])
    region("text", "reference_content", [327, 79, 581, 132])
    anchor("cross-page", 328, 673)
    lines(328, 684, ["[51] Grace Long and Edsger Entry. (2023).",
      "A bibliography entry with a page contin-",
      "uation that still needs the publication"])
    region("text", "reference_content", [327, 672, 581, 725])
    end(4)

    text(36, 32, "Continued bibliography", 17, True)
    lines(36, 63, ["details from the following page.",
      "This closes the same reference entry.", "Journal of Continuations, 2023, 15-28."])
    region("text", "reference_content", [35, 51, 285, 104])
    lines(36, 137, ["[52] New Author. The next reference.",
      "This entry starts a separate target.", "Journal of Excluded Neighbors, 2024."])
    region("text", "reference_content", [35, 125, 285, 179])
    anchor("section-opening", 328, 240)
    text(328, 257, "3.1 Complete previews", 14, True)
    region("heading", "paragraph_title", [327, 239, 581, 264])
    lines(328, 291, ["The opening paragraph provides context.",
      "It belongs to the selected section only.", "The next heading must remain excluded."], indent=0)
    region("text", "text", [327, 279, 581, 332])
    text(328, 388, "3.2 The next section", 14, True)
    text(328, 412, "This is a different section.")
    region("heading", "paragraph_title", [327, 371, 581, 393])
    region("text", "text", [327, 399, 581, 422])
    anchor("unfinished-entry", 328, 673)
    lines(328, 684, ["[61] Unfinished Author. This entry cannot",
      "establish its boundary because the next",
      "page contains unrelated material and"])
    region("text", "reference_content", [327, 672, 581, 725])
    end(5)

    text(40, 44, "Rotated and cropped page", 17, True)
    panel([40, 80, 280, 220], "Rotated panel", "#e0ecf4")
    anchor("rotated-cropped", 40, 240)
    lines(40, 252, ["Figure 12. The rotated complete target.", "Caption and visual must both survive."], indent=0)
    region("caption", "figure_title", [40, 240, 280, 270])
    text(40, 323, "Unrelated text under the rotated target.")
    region("text", "text", [40, 305, 280, 330])
    end(6)
    c.save()

    writer = PdfWriter()
    writer.clone_document_from_reader(PdfReader(raw))
    writer.pages[5].cropbox.lower_left = (20, 30)
    writer.pages[5].cropbox.upper_right = (592, 762)
    writer.pages[5].rotate(90)
    with final.open("wb") as output:
        writer.write(output)
    raw.unlink()
    # Raw coordinates are offset by the cropped top/left before rotation.
    for r in pages[5]["regions"]:
        left, top, right, bottom = r["bounds"]
        r["bounds"] = [762-bottom, left-20, 762-top, right-20]
    pages[5]["size"] = [732, 572]
    manifest = {"schema_version": 2, "pdf": final.name,
      "sha256": hashlib.sha256(final.read_bytes()).hexdigest(),
      "coordinate_space": "displayed_page_points_top_left", "page_numbering": "one_based",
      "layout_source": "hand_annotations_for_grouping_tests_not_detector_output",
      "pages": pages, "cases": manifest_cases}
    (OUT / "complex_objects.json").write_text(json.dumps(manifest, indent=2)+"\n")
    print(f"Created {final}: {len(cases)} links, {len(pages)} pages")


if __name__ == "__main__":
    generate()
