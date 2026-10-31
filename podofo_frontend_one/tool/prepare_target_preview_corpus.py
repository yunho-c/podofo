#!/usr/bin/env python3
"""Prepare model-independent source pages for target-preview annotation.

This tool never imports or runs the resolver/model. Selection uses PDF link order
and unique named destinations, not detector success. Output is a draft: empty
eligibility/boundary fields must be reviewed before any accuracy run.
"""

import argparse
import hashlib
import json
from pathlib import Path

import pymupdf as fitz


GROUPS = {
    "cite": "citation", "figure": "figure_table", "table": "figure_table",
    "equation": "equation", "section": "section", "subsection": "section",
    "subsubsection": "section",
}


def bounds(rect):
    return [round(float(v), 3) for v in rect]


def prepare(spec, corpus, output):
    output.mkdir(parents=True, exist_ok=False)
    documents = []
    for entry in spec["documents"]:
        path = corpus / entry["pdf"]
        data = path.read_bytes()
        pdf = fitz.open(stream=data, filetype="pdf")
        names = pdf.resolve_names()
        selected, seen = [], set()
        counts = dict.fromkeys(GROUPS.values(), 0)
        controls = 0
        for page in pdf:
            for index, link in enumerate(page.get_links()):
                if link["kind"] not in (fitz.LINK_GOTO, fitz.LINK_NAMED):
                    continue
                name = link.get("nameddest", "")
                prefix = name.split(".")[0]
                group = GROUPS.get(prefix)
                if not name or name in seen or link.get("page", -1) < 0:
                    continue
                if group:
                    if counts[group] >= spec["per_document_per_group"]:
                        continue
                    counts[group] += 1
                elif prefix == "Hfootnote" and controls < 1:
                    group = "unsupported_control"
                    controls += 1
                else:
                    continue
                seen.add(name)
                source_rect = link["from"]
                target_page = pdf[link["page"]]
                # resolve_names retains raw PDF coordinates; recent MuPDF also
                # exposes those directly for LINK_NAMED, unlike LINK_GOTO.
                raw_point = fitz.Point(names[name]["to"])
                displayed_point = raw_point * target_page.transformation_matrix * target_page.rotation_matrix
                source_text = page.get_textbox(source_rect + (-1, -1, 1, 1)).strip()
                context_rect = fitz.Rect(max(0, source_rect.x0 - 100),
                    source_rect.y0 - 3, min(page.rect.width, source_rect.x1 + 100), source_rect.y1 + 3)
                selected.append({
                    "id": f'{path.stem}-{group}-{counts.get(group, controls)}',
                    "group": group,
                    "kind": "table" if prefix == "table" else "figure" if prefix == "figure" else group,
                    "source_page": page.number + 1,
                    "source_link_index_pymupdf": index,
                    "source_xref": link["xref"],
                    "source_bounds": bounds(source_rect * page.rotation_matrix),
                    "source_text": source_text,
                    "source_context": page.get_textbox(context_rect).strip(),
                    "destination": {"name": name, "page": link["page"] + 1,
                        "raw_pdf_point": bounds(raw_point), "point": bounds(displayed_point)},
                    "eligible": False if group == "unsupported_control" else None,
                    "eligibility_reason": "Footnotes are outside the four target groups" if group == "unsupported_control" else None,
                    "required_parts": [], "excluded_neighbors": [],
                    "expected_target_text": [], "reviewed": False,
                })
        directory = output / path.stem
        directory.mkdir()
        # Full target pages and native text geometry, including potential next
        # pages, are annotation inputs. No detector rectangles are included.
        pages = {c["source_page"] for c in selected}
        pages.update(c["destination"]["page"] for c in selected)
        pages.update(c["destination"]["page"] + 1 for c in selected
                     if c["destination"]["page"] < len(pdf) and c["group"] == "citation")
        for number in sorted(pages):
            page = pdf[number - 1]
            page.get_pixmap(matrix=fitz.Matrix(1.5, 1.5), alpha=False).save(directory / f"page-{number}.png")
            lines = []
            for block in page.get_text("dict")["blocks"]:
                for line in block.get("lines", []):
                    lines.append({"bounds": bounds(fitz.Rect(line["bbox"]) * page.rotation_matrix),
                        "text": "".join(span["text"] for span in line["spans"])})
            (directory / f"page-{number}-text.json").write_text(json.dumps(lines, indent=2, ensure_ascii=False) + "\n")
        documents.append({
            **entry, "id": path.stem, "sha256": hashlib.sha256(data).hexdigest(),
            "source_url": f"https://arxiv.org/abs/{path.stem}",
            "redistribution": "local_only_license_not_reviewed",
            "page_sizes": [bounds(page.rect)[2:] for page in pdf],
            "sample_counts": counts, "cases": selected,
        })
        print(path.name, entry["split"], counts, "controls", controls, flush=True)
    manifest = {
        "schema_version": 2, "annotation_status": "draft_not_qualified",
        "coordinate_space": "displayed_page_points_top_left", "page_numbering": "one_based",
        "sampling": "First two distinct named targets per group in PDF page/annotation order; first footnote as an unsupported control when present",
        "sampling_spec_sha256": hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest(),
        "documents": documents,
    }
    (output / "corpus-draft.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(json.loads(args.spec.read_text()), args.corpus, args.output)
