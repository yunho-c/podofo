# M9 experimental Copy/Listen integration

Date: 2026-10-26. Host: M4 Pro, macOS 27.0.1, Flutter 3.47.5 / Dart 3.13.4.
This report covers implemented application behavior and automated plumbing.
Production model promotion, sandbox-folder-picker acceptance, and human listening
acceptance are **not** claimed. This report exercises document jobs; the later
[explicit-crop qualification](explicit-crop-validation.md) records the completed
Rust/C/Dart convenience API, app regression and sandbox asset correction.

## Implemented boundary

PoDoFo loads the layout and optional PP-FormulaNet_plus-L bundles into one analyzer.
It merges `FormulaFinished` into app-owned immutable page snapshots, preserving
the SDK rule that `PageLayoutReady` contains initial pending states. Final pages
reconcile the authoritative result. Cache v2 includes both ordered model hashes,
compute policy, pipeline profile, document revision, and render profile; each
write rechecks the current generation before publication. The app retains one
visible page, bounds disk snapshots to 4 MiB/page and 64 MiB total, and rejects
mismatched recognition provenance.

The Developer pane exposes explicit region selection, pending/failed/truncated
states, exact Copy LaTeX, rule selection, speech style, converted text, and Listen.
Selection paints the whole equation and preserves the reader/PDF controller's
identity. The shared narrator owns audio; a caller token prevents retired equation
intent from dismissing a newer prose request. Stop, pause/resume, voice and speed
reuse existing narration behavior. Language/style/rule changes invalidate math
speech. No fallback language or subexpression timing is inferred.

Plain speech has a separate 256-entry / 4 MiB LRU. Its identity includes original
LaTeX, display kind, all math options, SDK/profile and rule-manifest identity.
The original LaTeX remains copyable after conversion failure. The app's prepared
native artifact now enables `coreml,math`; the math feature remains optional for
independent SDK consumers.

## Reproduction and provenance

From `podofo_frontend_one`, with the prepared local assets:

```sh
CARGO_INCREMENTAL=0 python3.13 tool/qualify_podoco_equations.py \
  --layout ../podoco/model-assets/pp-doclayout-v3-m2 \
  --formula ../podoco/model-assets/pp-formulanet-plus-l-m6 \
  --rules ../podoco/model-assets/mathcat-0.7.7-m7 \
  --pdf build/podoco-qualification/m8-native-v3/recognized-page.pdf \
  --output build/podoco-qualification/m9-integration-v1 \
  --flutter-sdk /Users/yunhocho/fvm/versions/3.47.5
```

Choose a fresh output path for a repeat. The script prepares the native library,
builds/signs the Release app, analyzes Dart, then runs the concurrent native test
separately from the UI/controller checks. `--skip-build` explicitly reuses prepared
artifacts. It does not fetch models, install Python packages, or alter pub caches.
The input is the M8 lossless image-XObject PDF rendered by actual PDFium, not a
synthetic layout result. Its SHA-256 is
`e3bda3bdd501a74c26aad5fbf99595c419f5688843d716df8dd420115be8cab2`.

The [compact receipt](../../tests/fixtures/m9-integration-summary.json) records
all source/native/model/rule hashes, selected and other recognized expressions,
marks, resource counts, and screenshot hashes. Full raw logs, process samples,
page JSON and screenshots remain in the ignored output directory above. It
records the M8 parent commit plus exact dirty-source hashes for this implementation.
The signed Podoco library hash is
`a795084659122d5c2ae2b62389c8b0aae1a1e06d38b840b6b90d9278a662e0bb`.
Model/rules hashes match the M2/M6/M7 qualification pins.

## Automated results

- One real native concurrency test and 33 UI/controller/cache tests passed, with
  no skips in the explicit qualification invocation.
- The rendered page produced eight recognized equations and no failed/truncated
  outcomes. The first result was usable before the final page. Selecting `A_{m-1}`
  copied exactly that string and produced `cap a sub m minus 1 end sub` through
  MathCAT before submission to MLSR.
- The narrator was explicitly warmed with a separate short request. Both analysis
  and equation playback remained active at the observed first audio progression.
  Pause/resume preserved the playback; the equation finished with 105,574 frames
  at 44,100 Hz. All audio was at volume zero. Replay used the cached text; switching
  away dismissed it. Both libraries' handle registries returned from zero to zero.
- Logical job peaks were 16,777,216 input bytes, 2,162,688 retained result bytes,
  and two pending updates. The test process's highest 500 ms RSS sample was
  802,193,408 bytes, including Flutter, PDFium, Core ML, MathCAT and MLSR. This is
  sampled process memory, not a proven peak or an allocator/RSS limit.
- In this single active-host correctness run, analysis open took 3.775 s including
  verification, math open 0.143 s, and narrator admission/open 0.908 s. Warm page
  analysis took 3.438 s; the first usable formula arrived after 0.561 s. Listen
  admission to observed audio progression took 0.584 s; cancellation/drain took
  5.114 ms. These are wall-clock diagnostics with overlapping work, not isolated
  throughput, cold-filesystem, ANE-placement, thermal, or power measurements.
- The real reader test verified eight actionable equation rows, byte-exact
  clipboard handoff through a test platform-channel receiver, unchanged PDF/viewer
  identity, and selected-region repainting with other outlines hidden. Both saved
  screenshots were inspected. Font-isolated test capture maps the monospace alias
  to the repository font; it does not qualify system font fallback.
- Deterministic tests cover partial results, duplicate Listen, stopped conversion
  followed by a new request, late results, tab/page/revision/document invalidation,
  newer prose ownership, unsupported language, style/voice/speed changes, conversion
  failure with working Copy, cache eviction, and close during rule opening.

The script's Release build and strict deep signature verification passed.
The full Flutter regression run also passed 294 tests with nine explicit opt-in
skips: four existing MLSR suites, two M8 real-corpus cases, the M9 native and
reader cases separately qualified above, and the combined-model app test separately
qualified in `build/m9-progressive-native.log` (eight tests, no skips).
The full regression log is `podofo_frontend_one/build/m9-full-tests.log`.
Native renderer handoff copy counts and lifetime pressure are covered by the unchanged
[M8 tests](m8-renderer-validation.md); SDK math syntax/parity is covered by
[M7's 1,356-case check](m7-math-validation.md).

## Investigation notes and remaining gates

The initial concurrency test failed its overlap assertion because cold MLSR
opening outlasted this short document. It still drained both handle registries.
The final test warms MLSR explicitly, then asserts overlap instead of assuming it.
Earlier interrupted UI harness runs waited on fake-clock cache/clipboard work;
the final test pumps reader updates and uses the same explicit platform-channel
clipboard receiver as existing reader tests. Retained failed logs are not passing
evidence.

This implementation does not remove the M2 mixed-export score/order/duplicate
issues or M6 detector/recognition accuracy limits. For example, the 50-page M6
corpus had 238 exact matched recognized formulas out of 811 ground-truth formulas
end to end. Success here establishes usable plumbing, not general equation accuracy.
Keep Developer mode and the experimental label until the promotion decision is
supported. Human review must still exercise folder selection in the sandboxed
Release app, audible equation speech, and the complete Copy/Listen interaction.
