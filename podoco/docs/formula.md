# Formula recognition

`podoco::formula` provides a blocking single-crop API for the experimental
PP-FormulaNet_plus-L Core ML profile. Use it off UI/executor threads. For
progressive document analysis, open `Analyzer::open_with_formula` with both
verified bundles; see [document jobs](jobs.md). The [Dart SDK](../bindings/dart/README.md)
exposes the same document pipeline through the C ABI. Opening a layout-only
analyzer still leaves formula recognition unavailable.

```rust,no_run
use podoco::{AnalyzerOptions, ResourceLimits, options::ComputePolicy};
use podoco::formula::{
    FormulaBundle, FormulaCancellation, FormulaInput, FormulaOptions,
    FormulaSession,
};

fn recognize(input: FormulaInput) -> podoco::Result<podoco::FormulaOutcome> {
    let bundle = FormulaBundle::verify("/models/pp-formulanet-plus-l")?;
    let mut session = FormulaSession::open(bundle, AnalyzerOptions {
        compute_policy: ComputePolicy::CpuOnly,
        limits: ResourceLimits::new(
            1, 64 * 1024 * 1024, 1, 2 * 1024 * 1024, 2 * 1024 * 1024,
            128 * 1024 * 1024, 48 * 1024 * 1024,
        )?,
    })?;
    let result = session.recognize(
        input, FormulaOptions::default(), FormulaCancellation::default(),
    );
    session.close()?;
    result
}
```

Reuse a session for many expressions. Its worker owns three model graphs, input
tensors, and tokenizer data. Every expression creates fresh decoder state.
Opening, recognition, and explicit close are blocking; drop also joins the
worker. No native model or tensor crosses threads. Cancel from another thread
using a clone of `FormulaCancellation`; an in-progress native call drains before
the next cancellation check. Cancellation returns `ErrorCode::Cancelled`, and a
subsequent call can reuse the models. A native failure ends the session.

`FormulaInput` identifies the page and region and retains the original page
raster. Its canonical page bounds map through the inverse raster transform to
a covering integer crop. Recognition reads that crop directly, without an
intermediate crop bitmap. The display kind comes from the caller/detector and
is preserved. The current crop policy adds no context margin or equation-number
merging. Preprocessing has its own necessary tensor allocations and copies.

The result distinguishes complete nonempty LaTeX, failed recognition, and
truncation. A generation cap reached without EOS is truncated, even if the
partial text looks usable. The default cap is 2,048 generated tokens; explicit
caps of 1–2,048 are supported and lower caps appear in provenance. No confidence
score is invented from greedy decoder logits. `FormulaOutcome::to_json` validates
and encodes a bounded result; the session also enforces its result byte limit.

## Pinned deployment

The [YAML contract](../model-manifests/pp-formulanet-plus-l-coreml-v1.yaml) pins
checkpoint revision `6cc004a8e91ea3f3819b05317f40b290cbe99c2b`, Apache-2.0 model
licensing, exact source/export hashes, processor versions, tensor interfaces,
special tokens, and decoding. The encoder and masked stateful decoders use
FP16 internal neural computation with the declared F32/F16 interfaces. There is
no vocabulary pruning, input downscaling, or quantization beyond that export.

The processor reproduces margin cropping, short-edge bilinear antialias resize,
bicubic antialias thumbnail resize, centered black padding to 768×768, and fused
normalization. Each uint8 resampling pass preserves the reference rounding and
clamping. Streaming row intermediates avoid a full upscaled bitmap, including
for wide formulas. Extreme aspect ratios can still exceed the explicit scratch
budget and return a truncated outcome with no partial text.

Greedy decoding starts with token 2 and stops on token 2. Token and position
embeddings are read as two small F32 file rows per step, summed in F32, then
rounded to F16. The worker does not load a second 103 MB host embedding copy.
At step 256 it promotes each of eight layers' key/value states into the
2,048-position decoder. Tokens are decoded using the checkpoint's ByteLevel
alphabet, skipping its 23 special IDs, followed by the pinned processor rules
and `plsfix` text repair. A targeted compatibility rule fixes `plsfix` 0.1.8's
ANSI escape handling to match the reference `ftfy` 6.1.1 behavior.

The minimum opening budgets are 64 MiB for tensors and **40,108,032 bytes** for
decoder state/promotion scratch. These are admission floors; wide inputs may
need a higher tensor limit. Sessions reserve 16 MiB for host input/logit/text
storage and 12 MiB for checked native tensor spans, then charge preprocessing
scratch separately. The decoder cache limit accounts for both old and new
states while promoting, plus one layer's read/write buffers. Generated text and
normalization scratch have additional 256 KiB bounds. These are SDK-visible
budgets, not a process RSS cap: Core ML weights/workspaces/device allocations,
allocator overhead, and text-library static tables are outside these counters.

The existing `coreml` feature and macOS 15 deployment floor apply. CPU, CPU+ANE,
and All are explicit permissions, not measured placement or speed guarantees.
The initial native qualification covers CPU and CPU+ANE on the current macOS
arm64 host. Other OS/device/policy combinations remain unqualified.

## Explicit local preparation and examples

Normal builds neither download weights nor require Python. With the verified
research export and matching local checkpoint already present:

```sh
python3.13 tools/pp_formulanet/prepare.py \
  --research /path/to/docling-layout-heron-coreml \
  --checkpoint /path/to/6cc004a8e91ea3f3819b05317f40b290cbe99c2b \
  --output model-assets/pp-formulanet-plus-l-m6
cargo run --locked --release -p podoco --features coreml --example formula -- \
  model-assets/pp-formulanet-plus-l-m6 cpu 2048 equation.png
```

Preparation requires a fresh output directory. It verifies the handoff source
and payload hashes before APFS-cloning local payloads, explicitly compiles all
three graphs, and inventories the prepared bundle with compiler provenance.
Original training weights are verified but not copied. `FormulaBundle::verify`
checks the pinned contract, complete file inventory and hashes without loading
Core ML. Keep the directory immutable while a session uses it. Hashes establish
integrity against a trusted manifest; they do not authenticate its publisher.

The example emits one JSON line per crop, containing its terminal outcome,
token IDs, raw decoded text, model reuse counters, and diagnostic timings. PNG
decoding belongs to the example's caller-side loader. See
[M6 single-crop qualification](internal/m6-single-crop-validation.md) for the
reproduction commands, corpus boundaries, and remaining integration work.
