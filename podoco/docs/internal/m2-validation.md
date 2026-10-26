# M2 validation: Rust PP-DocLayoutV3 integration

Completed on 2026-10-26 in `feat/podoco`, building on M1 commit `2aa6117`.
The public result is a reusable blocking `LayoutSession` and PNG CLI. C/Dart
analysis, document jobs, formula recognition, and application integration remain
subsequent milestones. PP-FormulaNet_plus-L is now the selected recognizer.

The [machine-readable summary](../../tests/fixtures/pp_doclayout_v3/m2-summary.json)
records source/artifact hashes, per-case portable comparisons, native policy
counts, tie classification, coexistence evidence, and timing boundaries. Larger
captures/logs remain ignored under `evaluation-output/m2-portable-v1`,
`m2-coexistence`, and `m2-cli-*`. The M1 manifest, runner, and captures are unchanged.

## Exact integration boundaries

- The v1 manifest SHA-256 is
  `3799c3091c7087111111a38847a35e7db882176d3466d3a54159bb517212abef`.
  It retains all 12 original payload entries/hashes and introduces explicit
  stable candidate/order ties. v0 is still verifiable, but reference-only.
- Preprocessing matches every Float32 input element on all 60 cases: three M1
  synthetic pages, seven deterministic raster cases, and the 50 original IBEM
  pages. The latter use shared Pillow-decoded RGBA, not separate JPEG decoders.
  Raster cases include 1x1, one-pixel axes, 799x801, wide/tall downsampling,
  800x800 identity size, and straight alpha. Portable tests additionally cover
  BGRA/RGBA, padding, opaque/premultiplied alpha and invalid premultiplication.
- Saved-output decoding matches all selected query/class pairs and v1 order
  on the three eager synthetic captures and 50 saved Core ML captures. Scores
  and normalized coordinates pass separate absolute `1e-6` gates. Portable
  tests cover empty output, multiple classes per query, equal votes, formula
  context, invalid/non-finite output, rotated/scaled/translated box mapping,
  preserved out-of-page bounds, and bounded serialization.
- Against the original processor, v1 changes seven relative pairs across seven
  pages. Every inversion is an exact vote tie; all selected pairs and untied
  ordering remain unchanged. Tie changes are separate from export drift.
- Fresh Rust/cidre and Python/Core ML controls produce **bit-identical logits,
  boxes, and order tensors** on 53 pages under CPU+ANE. CPU-only and All each
  pass on the three synthetic pages and two known exception pages. Each side
  predicts twice per page through one retained model per policy: 126 predictions
  per implementation. Both implementations' repeat controls are also exact.
- Fresh Rust CPU+ANE small outputs are bit-identical to all 50 retained legacy
  Core ML captures. No new integration discrepancy is hidden by a widened
  conversion tolerance. Qualification additionally scans every mask value for
  finiteness without retaining a full host mask copy. Normal inference never
  maps the masks, so qualification timing is not normal runtime timing.

The reference remains Transformers 5.8.1 / Torch 2.12.0 / Torchvision 0.27.0 /
Pillow 10.4.0; source/package/checkpoint hashes are checked by the offline runner.
Python uses the existing 3.13 environment and existing Core ML tools 9.0 package
directory. Core ML tools emits its existing Torch/scikit-learn compatibility
notices; this qualification performs compiled-model inference, not conversion.

## Ownership, lifecycle, and packaging

Native model/input/provider objects remain on one worker thread and are not
`Send` or `Sync`. Retained host buffer addresses remain unchanged across the
native corpus replay. Public-session tests confirm a single model load across
repeated calls, capability/budget rejection, recovery from rejected requests,
repeated close, and post-close rejection. Deterministic worker tests cover
recoverable errors, fatal native-state errors, and panic/disconnected replies.
Closing and Drop join the owner thread before returning.

Native tests exercise noncontiguous output access, padding, broadcast reads,
overlapping-write rejection, checked accessible spans, and an actual caught
Objective-C exception whose copied diagnostic survives pool release. M1's
native image ownership/release tests remain passing. No Miri run is claimed.

The initial native broadcast test used a Core ML allocation with zero leading
stride, which exposes no writable elements on this host. It was corrected to
use an explicitly owned, initialized backing with a trailing broadcast stride;
this preserves the intended read-alias check without relying on invalid storage.

`check_coreml.py` now accepts `--layout-bundle` and `--mlsr-probe`. Ten fresh-process
loading cases pass: both orders of release/debug/`-ObjC` observer-disabled builds
beside an enabled control, the existing MLSR library, and the MLSR native runtime
probe. They include 32 actual layout predictions, 192 affine Podoco predictions,
and two MLSR runtime probe calls. Disabled builds omit `CidreObserver` while
retaining the Core ML bridge. No production C symbols or generated bindings
changed. The MLSR checks do not establish speech-model or audible playback parity.

The narrow runtime patterns are adapted from MLSR
`14ff251eb7e9011801945233cf91ef8b444cd734`. Interpolation and Float32 reduction
follow pinned PyTorch sources; [attribution and license](../../third_party/README.md)
are included. There is no TTS or PyTorch dependency in Podoco's runtime.

## Diagnostic timing and memory

One release CLI process analyzed columns, equations, and raster six times each
on an Apple M4 Pro with 48 GiB RAM, macOS 27.0.1, AC power. The host was an active
development machine. Model loading occurred once for all 18 calls. Verification
was 230 ms and open was 3.33 s; this is an ordinary cached-host opening, not a
controlled cold-cache or compilation measurement. First prediction was 72.9 ms;
first blocking call was 81.0 ms.

Warm medians use the five later repetitions per page:

| Page | Preprocess | Native prediction boundary | Decode | Complete blocking call |
| --- | ---: | ---: | ---: | ---: |
| columns | 7.32 ms | 46.44 ms | 0.35 ms | 54.11 ms |
| equations | 8.75 ms | 46.44 ms | 0.37 ms | 55.59 ms |
| raster | 2.97 ms | 46.55 ms | 0.36 ms | 49.92 ms |

The native boundary includes input write, Core ML prediction, metadata checks,
and small-output readback. Complete calls include result validation and bounded
serialization checks, but exclude PNG decoding, bundle verification, model open,
and stdout writing. These observations are neither an application-throughput
benchmark nor proof of ANE placement.

Persistent host buffers account for 8,135,600 bytes. Peak accounted tensor spans
plus the 128 KiB scratch allowance are 66,274,596 bytes; returned native strides
increase storage beyond logical tensor sizes. `/usr/bin/time -l` separately
reports peak RSS 380,796,928 bytes and peak footprint 386,401,288 bytes for the
whole CLI process. Core ML weights/workspace/caches and image/PNG allocations
are outside the tensor-span accounting. A tensor budget cannot cap all of them.

## Checks and completion boundary

Passed locally:

- Full `python3 tools/dev.py check`: 26 portable core tests, existing FFI identity
  and doctest, formatting/Clippy/docs, C caller, Dart analysis/tests/version,
  relocated package, and incompatible ABI rejection.
- `check-generated`: C and Dart generation remains unchanged.
- Core ML tests: 28 core tests plus FFI/doctest; three real-asset exchange/session
  tests are ignored by ordinary runs and were invoked explicitly here.
- Rust 1.88 tests with Core ML; Core ML workspace Clippy with warnings denied.
- Ruff checks/formatting, local documentation links, and `git diff --check`.

Reproduction commands and explicit local artifact requirements are in the
[tooling guide](../../tools/pp_doclayout_v3/README.md). Configured remote CI,
Windows/Linux execution, iOS, minimum-OS deployment, and Miri were not run here.

**The mixed export remains experimental.** Its original eager comparison still
has 1,103 matched detections, no missing detections, two extras (including the
high-confidence duplicate heading), and 25 differing matched order pairs.
Those are model/export differences, not Rust integration errors, and require
investigation before production promotion. Conversion agreement is separate
from ground-truth detection quality. M2's useful Rust layout slice is complete;
these restrictions continue into the later product qualification gate.
