# Target preview baseline fixtures

`linked_objects.pdf` is a deterministic three-page PDF with six real internal
links: two adjacent bibliography entries, a two-panel figure and caption, a
table and caption, an equation and number, and a section opening. Its JSON
manifest defines the intended complete objects and unrelated neighboring content.

`real_papers.json` freezes eight source links in two locally available papers:
MathReader (`2501.07088v2`) and UniGVC (`2610.13023v1`). These PDFs are not vendored.
Use the exact SHA-256 identities in the manifest, not just matching filenames.
The seed is for development; it is not the later held-out accuracy evaluation.

All rectangles are `[left, top, right, bottom]` in displayed-page PDF points;
page numbers are one-based. `required_parts` are separately identified portions
of the complete target, and `excluded_neighbors` identify content that should
not appear. The region annotations were reviewed against rendered pages. The
seed pages have no rotation or CropBox offset; existing native preview tests
cover those coordinate cases separately. Real named destinations retain both
raw PDF coordinates and converted points. Source annotation indices are from
PyMuPDF; the native test matches source rectangles instead of relying on order.

The two UniGVC Figure 4/5 links deliberately share the same named destination.
They require different target regions according to their source text. The current
contextual renderer produces identical crops for them. A future resolver must
use source identity or abstain; treating the destination alone as identity fails.

From `podofo_frontend_one`, with a locally built Debug macOS app:

```sh
python3 tool/test_macos.py --build-mode debug \
  test/target_preview_fixture_test.dart

TARGET_PREVIEW_CORPUS_DIR=/path/to/pdfs \
  python3 tool/test_macos.py --build-mode debug \
  test/target_preview_fixture_test.dart
```

Pass `--flutter-sdk /path/to/flutter` if the repository's `.fvm` link is absent.
The real-paper case explicitly skips without `TARGET_PREVIEW_CORPUS_DIR`.
The test verifies hashes, native source rectangles and destinations, page sizes,
text identity, valid non-overlapping target/exclusion regions, bounded native
rendering, and unchanged document/navigation state. It writes contextual PNGs
to `build/target-preview-m0/native`. These are baseline captures, not assertions
that the current contextual crop meets the future target-completeness rules.
PDFium's discretionary-hyphen marker is normalized only for text sanity checks.

To regenerate the synthetic PDF and JSON byte-for-byte, install
`reportlab==5.1.0` in a Python environment, then run:

```sh
python tool/create_target_preview_fixture.py
```

The generator uses ReportLab's invariant mode and built-in fonts. M0 validation
also rendered and visually reviewed all three pages and checked that a second
run left both PDF and JSON hashes unchanged. See
[the baseline report](../../../../docs/target_aware_link_preview_m0.md) for the
integrated build, model checks, and remaining native-window gate.
