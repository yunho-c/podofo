# Rust contracts and offline bundles (M1)

M1 implements portable Rust identities, page geometry, image copying, result
serialization, and local bundle verification. The C and Dart packages still
expose identity only. M2 adds [blocking layout inference](layout.md). `Analyzer`,
document jobs, recognition, and MathCAT execution remain later milestones.

Run the complete public-API example without model assets:

```sh
cargo run --locked -p podoco --example contracts
```

The example creates a copied page image and round-trips an illustrative source
failure. It does not fabricate a model prediction. Rust API documentation is
available through `cargo doc --locked -p podoco --open`.

## Inputs and ownership

`DocumentRef::new` preserves nonempty application document/revision identities.
`PageKey` uses zero-based source indices; `validate_pages` rejects duplicates and
mixed revisions without sorting the caller's subset. `PageSpace` uses positive
finite logical dimensions. PDFs use displayed page points, with a top-left
origin and downward Y axis.

`Point`, `Rect`, `Polygon`, and `Affine` validate construction and Serde decoding.
Rectangles use left/top/right/bottom edges. Affine coefficients are
`[a,b,c,d,tx,ty]`, with `x'=a*x+c*y+tx`, `y'=b*x+d*y+ty`.
`Affine::crop_pixels` transforms all four corners through the inverse map,
rounds outward, clamps to the raster, and rejects empty intersections.

`ImageDescriptor::new(width, height, row_stride, format, alpha)` accepts positive
BGRA8/RGBA8 raster layouts. Stride is in bytes and includes padding. Its minimum
initialized span is `(height-1)*stride + width*4`, checked for arithmetic and
host-addressability overflow. Alpha is explicitly opaque, straight, or
premultiplied; copying does not composite or reinterpret pixels.

`PageImage::copy(descriptor, bytes, byte_budget)` copies the complete supplied
slice, including padding/trailing bytes, before returning. The retained size
counts toward the input budget. Reads expose immutable pixel rows without
padding. Clones share the owned allocation. `PageInput::new` also validates the
page mapping; a rejected construction returns its image to the caller.

An internal unsafe lease boundary owns initialized, immutable foreign storage
and releases it after the final reader. Its callback must be non-panicking and
safe on the final owner's thread. Tests cover rejection, cross-thread final
release, and unwind cleanup. This is not yet a public native-import API or a
qualified renderer integration; C/Dart transport and renderer leases remain M4/M8.
The native image lease and Core ML tensor-access modules contain the reviewed
unsafe boundaries. The rest of the Rust core denies unsafe code.

## Results and schema

The public `results` module defines the five proposed semantic updates, page
snapshots, reading order, formula states/outcomes, provenance, and summaries.
Compact categories are text, heading, formula, formula-number, table, figure,
caption, header, footer, and other. Native class ID, label, and subtype remain
available. Formula display context is inline, displayed, or unknown.

Recognition states distinguish not-requested, pending, and a terminal outcome.
Terminal outcomes distinguish recognized, failed, and truncated. Recognized
LaTeX is preserved exactly, including Unicode. Truncated text is diagnostic
partial output, not a successful expression. Missing scores remain absent;
finite scores are not forced into probability semantics.

`AnalysisUpdate::new` validates the envelope and payload. A page snapshot has
unique region IDs, exactly one state for each formula, and optional reading
order as a permutation of its regions. Layout-ready updates contain no finished
recognition; final pages contain no pending recognition. Page/document revisions
must agree. Summary counts use checked arithmetic and agree with completion
status. Cross-update sequencing and consistency require the M3 job implementation;
M1 validates individual values, not an event stream.

Use `AnalysisUpdate::to_json(max_bytes)` and `from_json(bytes, max_bytes)` for
bounded transport. Schema version **0** is separate from the existing C ABI
version **1** and bundle manifest version **1**. Fields/variants use snake case;
point/page-size/rectangle/affine values use fixed arrays documented above.
Unknown optional fields are ignored. Unsupported versions and required variants
fail explicitly. Native handles, images, masks, and tensors never enter JSON.
The [schema fixtures](../tests/fixtures/domain/README.md) cover all variants.

Aggregate result records are constructible Rust data. Call `PageAnalysis::validate`
when inspecting an independently constructed snapshot; the update constructor
and bounded JSON decoder invoke validation automatically. Generic Serde encoding
is available, but does not impose the bounded transport API's byte budget.

## Options and bundle verification

`ResourceLimits::new` requires positive, finite queue/byte budgets, with an
individual update fitting the total result budget. M1 provides no production
resource defaults. `AnalysisOptions::new(profile)` requests all detected formulas;
set `formula_scope = FormulaScope::None` explicitly for layout-only work.

`ModelBundle::verify(directory)` reads `podoco-bundle.yaml`, validates the concrete
PP-DocLayoutV3 contract, and streams all payload hashes. It does not load Core ML,
download models, compile exports, or establish model quality. Use
`bundle.validate_options(&options)` to check the exact profile and capabilities;
the current bundle rejects formula recognition before any page rendering.

The manifest pins checkpoint/export provenance, preprocessing/decoding, all 25
class mappings, deployment requirements, and all four output tensors. The mask
output alone is 48,000,000 Float32 bytes. Native classes 5 and 15 preserve
displayed/inline context despite the shared Transformers label `formula`.
The reference uses Torchvision bicubic resize with antialiasing disabled, not a
generic interchangeable Pillow resize implementation.

The mixed-precision artifact remains **experimental**. Existing extra detections
and reading-order differences are retained as promotion gates. Declared bundle
capabilities describe the planned adapter contract, not a loaded or qualified
inference runtime. Integrity is checked against a trusted manifest; hashes do
not authenticate a publisher. Do not modify verified payloads or link targets
while a runtime uses them.

See [model preparation](../tools/pp_doclayout_v3/README.md) for exact commands,
local asset requirements, source attribution, and reference replay.
