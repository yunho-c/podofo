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
contextual renderer produces identical crops for them. The M2 resolver uses
source identity to select distinct figures; destination alone cannot identify them.

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

## Cached semantic preview replay (M2)

`layout/linked_objects-page-{2,3}.json` freezes native layout-only output for the
synthetic PDF, including the complete model/artifact/render provenance. It uses
`pp-doclayout-v3-coreml-mixed-v1`, manifest
`3799c3091c7087111111a38847a35e7db882176d3466d3a54159bb517212abef`,
CPU + Neural Engine, and the existing 144 DPI / 2048-edge PDFium render profile.
The recorded analysis IDs, source path and elapsed time describe the capture;
fixture replay uses the owned regions and fresh native text from the synthetic
PDF. It requires no model inference. Production cache identity validation is
tested separately in `link_resolution_foundations_test.dart`.

```sh
python3 tool/test_macos.py --build-mode debug test/link_target_resolver_test.dart

TARGET_PREVIEW_RUN=m2 TARGET_PREVIEW_CORPUS_DIR=/path/to/pdfs \
PODOCO_M2_BUNDLE=/path/to/pp-doclayout-v3-m2-sandbox \
  python3 tool/test_macos.py --build-mode debug test/target_preview_evaluation_test.dart
```

The opt-in evaluation reruns actual layout inference on the seven unique target
pages, verifies PDF hashes, and writes region snapshots, paired contextual and
semantic PNGs, and per-link JSON to `build/target-preview-evaluation/m2/`.
Both tests count nonwhite native source pixels inside required and excluded
annotation rectangles. Required coverage must be at least 99.5%; excluded ink
must be zero. This measures crop geometry against original PDF pixels; it does
not score text readability after scaling. The 14 development cases currently
cover all required ink with zero annotated neighboring ink. They are not M5's
held-out corpus.

## Complex target raster fixtures (M4 foundation)

`complex_objects.pdf` has six pages and eleven real links. Nine cases annotate
complete objects with hanging references, column/page continuations, separated
panels, captions above figures, multiline equations, a section opening, and an
offset/rotated page. Two cases specify ambiguous or unfinished targets. Its
schema-2 manifest associates each required/excluded rectangle with its page.
The `pages[].regions` are hand annotations explicitly marked as such; they are
not Core ML detections or evidence of automatic resolver coverage.

Regenerate with ReportLab 5.1.0 and pypdf 6.21.4:

```sh
python tool/create_complex_preview_fixture.py
python3 tool/test_macos.py --build-mode debug -- --concurrency=1 \
  test/preview_compositor_test.dart test/preview_compositor_native_test.dart
```

The native test verifies source/destination geometry and renders the nine manual
targets at 1x, 2x and a narrow envelope with DPR capped from 4x to 2x. Every
composed pixel must match an independent native source crop. Paired context and
composed PNGs plus accounting results are written to
`build/target-preview-m4/compositor`.

`complex_target_resolver_test.dart` resolves the same nine targets from native
source text with the hand layout annotations, verifies included/excluded source
ink, and rejects missing or incompatible continuation evidence. It never presents
these annotations as detector results. The separate opt-in
`complex_preview_native_test.dart` uses actual bundled inference via the shared
coordinator, captures every fallback, and requires its seven qualified targets to
remain complete. Set `TARGET_PREVIEW_M4_RUN` to a fresh suffix; actual snapshots,
paired crops and metrics go to `build/target-preview-m4/native-<suffix>/`.
The detector currently omits the separated-panel and rotated-figure visual
regions. Those two cases stay contextual. See the
[M4 report](../../../../docs/target_aware_link_preview_m4.md).
