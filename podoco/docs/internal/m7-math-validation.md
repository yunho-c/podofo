# M7 optional math conversion qualification

Qualified on 2026-10-26, M4 Pro/macOS 27.0.1, Rust stable 1.95 and minimum
1.88, Dart 3.13.4 for native corpus/lifecycle checks. M7 adds optional Rust/C/Dart
MathML/plain-text conversion without requiring Core ML, model weights or MLSR.
It does not qualify audible speech or promote the experimental detector/formula
profiles. The [public contract](../math.md) documents syntax and resource limits.

## Pinned components and host isolation

- Strict `pulldown-latex` 0.8.0 (MIT), `roxmltree` 0.21.1 (MIT/Apache-2.0),
  MathCAT 0.7.7 (MIT), all Rust-1.88 compatible. The MathCAT source, patch and
  exact source-file inventory are recorded in `third_party/mathcat-source.json`.
- 238 rule/license payloads totaling 9,783,133 bytes. Raw manifest SHA-256:
  `24c9305db2b81986b9d79227f871b30967fbb1f5e04ec17f28fecbf677540f7e`.
- Profile: `pulldown-latex-0.8.0-mathcat-0.7.7-strict-v1`. No command repair or
  permissive converter fallback; one enclosing math fence may be removed with
  an owned diagnostic. Original input is preserved.
- A narrow `podoco-host` patch removes MathCAT panic-hook installation and user
  preference discovery from this build and enables upstream `no-unsafe`.
  Source verification and a process-isolated test establish that the host hook
  still receives a deliberate panic after two MathCAT workers initialize.
  Host preference exclusion is also audited in the compiled feature branch.
- Every request applies a complete public preference snapshot plus plain-text
  settings. Alternating English ClearSpeak and Spanish SimpleSpeak on two
  independent workers, including concurrent Dart calls, retains each output.
  Closing one leaves the other usable. No unsupported locale/style fallback.

A preliminary comparison of `math-core` 0.5.0 and `pulldown-latex` 0.8.0 used
1,341 recognized expressions. `math-core` panicked on three cases, including a
simple parenthesized superscript expression, and accepted some mixed math/text
fences as literal dollar signs. The selected strict converter offers streaming
complexity bounds and explicit errors. Selection does not imply comprehensive
LaTeX or mathematical-semantic correctness.

## Actual recognized expression coverage

Inputs are the saved native M6 CPU+NeuralEngine outputs, with original display
context. The document run contributes 531 detected crops; the standalone crop
run contributes 810 completed reference crops (one truncated crop is excluded).
The two sets overlap in document content and are not 1,341 independent formulas.
Unknown crop context uses inline conversion with a diagnostic. Fifteen additional
fixtures cover known math, display/fences, Spanish, malformed/unsupported syntax,
macro rejection, direct MathML, external resources and unsupported language.

| Input set | Cases | MathML and plain speech succeed | Owned conversion errors |
|---|---:|---:|---:|
| Detected crops | 531 | 517 | 14 |
| Completed reference crops | 810 | 797 | 13 |
| Explicit fixtures | 15 | 8 | 6 conversion + 1 unsupported language |

All **1,356/1,356** Rust and Dart/C result objects match exactly, including
MathML, speech, options, provenance, diagnostics and error messages. No worker
failures occurred. Unsupported real cases include array column-spec whitespace,
`atop`/`boxed`/`displaylimits`, mixed fences, malformed generated XML, and invalid
fixed-arity MathML emitted for some operator/spacing combinations. These fail
explicitly instead of being submitted to TTS. The compact
[summary](../../tests/fixtures/math/m7-summary.json) records all 27 real failures,
source artifact hashes and binary hashes. It is not an accuracy score for the
underlying equation recognition or for human speech comprehension.

Reviewable [fixture MathML and speech](../../tests/fixtures/math/review-output.json)
include `x+2` → “x plus 2”, `\frac{a}{b}` → “a over b”, and
`\sqrt{x^2+y^2}` → “the square root of x squared plus y squared”. A sum, displayed
context, whole fences, direct MathML and Spanish are included. No audio was played
or listened to during M7.

## Lifecycle, bounds and compatibility

Rust tests cover strict parsing, fixed child counts, source/output/parser bounds,
missing/changed/incomplete rules, full queues, close cancelling queued requests
while waiting for active work, and panic propagation to all waiters. C tests
cover feature-off behavior, malformed metadata and stale handle kinds. Five
native Dart tests pass, including two-worker interleaving, bounded bridge
admission, pending disposal, idempotent close, unsupported syntax/language and
healthy reuse. Each native test and the full corpus end with zero registry
handles. The tests caught and fixed an isolate closure-context capture of pending
futures; bridge closures now live in independent top-level scopes.

Portable checks also exercise an older ABI-2 library with no formula/math
extension symbols: Dart rejects missing support through feature bits before
symbol resolution. Generated C/Dart checks, default Rust/C/Dart/relocated-package
checks, Rust 1.88 math tests/combined-feature checks, math rustdoc and combined
CoreML+math Clippy/tests passed. A combined test build first exhausted storage;
after clearing only worktree incremental compiler intermediates, its complete
rerun passed with incremental output disabled. CI adds optional math builds/tests on all desktop hosts; the
local native rule/corpus qualification reported here is macOS arm64 only.

The resource limits bound logical input, output, queue and parser complexity;
they do not bound every dependency allocation, loaded rule table, worker stack,
process RSS or conversion wall time. Close drains active MathCAT work without
interrupting it. No model performance/ANE-utilization claim is made.

## Reproduction and retained evidence

From `podoco/`, using the existing prepared M6 outputs and verified rule bundle:

```sh
python3.13 tools/math/qualify.py \
  --rules model-assets/mathcat-0.7.7-m7 \
  --documents evaluation-output/m6-documents-v1/rust.jsonl \
  --crops evaluation-output/m6-native-full-v2/cpu-ne.jsonl \
  --output evaluation-output/m7-native-new \
  --dart /Users/yunhocho/fvm/versions/3.47.5/bin/cache/dart-sdk/bin/dart
```

Final raw evidence is `evaluation-output/m7-native-v2/`: exact inputs, Rust and
Dart JSONL, host/lifecycle logs, source/binary hashes and the summary. Source and
binary drift checks reported no failures. The earlier `m7-native-v1` records the
isolate-capture failure and is retained, not passing evidence. The initial
converter comparison is retained under `evaluation-output/m7-probe`.
