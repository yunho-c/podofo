# M1 validation — 2026-10-25

M1 implements Rust domain/image contracts, bounded result serialization, a tested
internal native lease owner, and offline PP-DocLayoutV3 bundle verification and
preparation. It does not implement Rust inference, job execution, new C/Dart
analysis APIs, or a renderer lease adapter.

## Portable contracts and compatibility

Validated locally on macOS arm64, Rust 1.95.0 and 1.88.0, Dart 3.13.5:

- `python3 tools/dev.py check` passed formatting, Clippy, 18 M1 tests, the existing
  FFI identity test, Rust documentation/doctest checks, the public `contracts`
  example, C header freshness, compiled C calling, Dart analysis/loading, and
  relocated-library loading with incompatible-ABI rejection.
- `python3 tools/dev.py check-generated` passed C and Dart binding freshness.
  No C symbol, header, ABI version, or generated Dart binding changed.
- `cargo +1.88.0 test --locked -p podoco -p podoco-ffi --target-dir target/msrv`
  passed on the declared minimum Rust version.
- The same Rust tests passed with `--features coreml`. Core ML feature Clippy
  also passed with warnings denied. These are feature-compatibility checks;
  the existing coexistence probe's earlier native qualification remains scoped
  to its separately documented affine model.
- Ruff checks/formatting passed for the reference tools. Ordinary checks verify
  committed PNG hashes using Python's standard library, without ML packages.

The 18 M1 tests cover affine rotation/crop round trips and invalid geometry,
checked raster spans, padding/alpha/channel metadata, independent copying,
returned ownership on rejection, final-reader release across threads and unwind,
revision/page identity checks, finite budgets, capability/profile rejection,
all update/outcome schema fixtures, bounded JSON, and local bundle integrity.
Eighteen test functions do not exhaust every possible runtime failure path;
queueing, native predictions, cancellation, and renderer integration remain the
later milestone gates in the implementation plan.

The Unix file-link tests passed on macOS. The existing CI matrix covers portable
checks on Linux/Windows, but no remote CI result or Windows symlink support is
claimed by this local run.

## Real local model bytes

Prepared `model-assets/pp-doclayout-v3-m1` with file links using the Rust example.
The verifier checked all 12 package/compiled/metadata payloads against the
concrete YAML. No model weights were duplicated or downloaded.

Manifest SHA-256:
`fba7f3968515dfb4337f03b67b02e08cee82427a32eebce210d1df4851a2639b`.

The profile advertises layout/order and explicitly lacks recognition/polygons.
It remains experimental. This establishes integrity against the supplied trusted
manifest and profile contract, not publisher authenticity, executable-model
parsing, native inference, placement, accuracy, or performance.

## Reference capture and replay

[The compact summary](../../tests/fixtures/pp_doclayout_v3/reference-summary.json)
records a fresh three-page capture using the original eager FP32 model, pinned
local checkpoint, source hashes, and existing Python 3.13 packages. Captures are
in `evaluation-output/m1-reference-v2/`; compressed tensor archives total
3,402,694 bytes and remain ignored. Earlier development captures are not the
acceptance baseline.

| Original synthetic input | Reference detections | Checks |
| --- | ---: | --- |
| `columns.png` | 32 | Exact preprocessing replay; boxes, classes, scores, and order match upstream |
| `equations.png` | 12 | Same, including retained source query identities |
| `raster.png` | 1 | Same, with white compositing of straight alpha and odd dimensions |

A fresh-process replay checked exact saved input tensors, decoded JSON, and
selected-mask thresholds. Up to eight unique queries per page retain mask
logits, both logit-zero diagnostic masks and the processor's sigmoid `>0.30`
masks. Polygon output is not qualified. These counts are observed detections,
not ground-truth accuracy; synthetic pages are intentionally a small integration
reference set.

The pinned processor uses Torchvision bicubic resizing with `antialias=False`.
The manifest and captured tensors preserve that detail instead of substituting
a generic Pillow resize. Decoded reference boxes use source pixel-edge
coordinates; the fixture manifest provides the canonical page mapping.

[The external corpus index](../../tests/fixtures/pp_doclayout_v3/ibem50.json)
verified hashes for all 50 existing IBEM images and saved small-output archives.
It retains earlier reference detections, conversion agreement, and both known
extra-detection pages. No 50-page inference rerun was performed, no original
IBEM page was copied into Git, and the research checkout was not modified.

## Next boundary

M2 must implement native Rust preprocessing/inference/decoding and compare those
boundaries with this evidence. The mixed export's duplicate-heading exception
and reading-order differences remain production-promotion gates. M3 owns
cross-update sequencing, bounded admission, source/sink execution, cancellation,
and shutdown; M4/M8 qualify the foreign transport and actual renderer leases.
