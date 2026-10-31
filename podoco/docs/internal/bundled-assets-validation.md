# Bundled asset qualification — 2026-10-26

The app-bundled layout, formula and math pack passed an offline macOS arm64
release check. This qualifies packaging and application plumbing for the existing
mixed layout v1 profile. It does not promote the pending FP32 export, recognition
quality, or human listening acceptance.

## Preserved evidence

All paths below are relative to `podofo_frontend_one/`:

- `build/podoco-qualification/bundled-assets-v2/qualification.json`: overall pass,
  source status and per-file hashes, runtime receipt and ordinary app location.
- `runtime-report.json` under that directory: actual plugin resource resolution,
  sandbox denials, analyzed page, Copy text, speech text, audio progress and handles.
- `probe-assets-audit.json` and `normal-assets-audit.json`: complete inventory,
  identity, architecture, linkage and sandbox/signature checks.
- `probe-build.log`, `runtime.log`, `normal-build.log`: build and runtime evidence.
- `build/podoco-packaging-full-tests-v2.log`: 296 reader regressions passed,
  14 existing opt-in/platform tests skipped.
- `build/podoco-packaging-resource-tests.log`: seven loader tests and the updated
  lazy Listen widget test passed. The full run also covers seven bundled-controller
  lifecycle tests and collapsed override controls.
- `build/podoco-packaging-analysis-v4.log`: application analysis clean.

The Rust packager passed four tests on the minimum Rust 1.88 toolchain, including
corrupt source/output preservation, explicit replacement, file-link materialization,
directory-link refusal, relocation, nested assets and model-free target output.
Warnings-denied Clippy passed. Logs are under
`podoco/evaluation-output/bundled-packaging-msrv-v2.log` and
`bundled-packaging-clippy-v3.log`. Flutter SDK analysis also passed. Two portable
preparation-wrapper tests passed. These checks do not require downloaded models
in CI; the native release check uses local pinned assets.

## Result

The shipped package contains **289 asset files, 1,103,133,547 bytes** (about
1.027 GiB), including notices and all nested compiled-model files. Its catalog
SHA-256 is `afd5bf91a95a2c2c9da6c9b61bf1586e177faae24c81026b83aef422cc3a1b39`.
The ordinary app's signed Podoco native library SHA-256 is
`65ad53be3ad5c04f9489fb542a6751ae557e961626e57150755a180b7333433f`.

| Component | Manifest SHA-256 |
| --- | --- |
| Layout mixed v1 | `3799c3091c7087111111a38847a35e7db882176d3466d3a54159bb517212abef` |
| PP-FormulaNet_plus-L M6 | `f122877f62b7e03e4a80c9e85fdca274f1d49e97ae84c37119119b793c3e1140` |
| MathCAT 0.7.7 M7 | `24c9305db2b81986b9d79227f871b30967fbb1f5e04ec17f28fecbf677540f7e` |

The probe was relocated and signed with a unique application identifier for a
fresh sandbox, without network entitlements. It proved permission denial when
opening the existing developer manifests/native library and connecting to a
listening loopback socket. Resource discovery resolved inside the relocated
`App.framework`; no model path was supplied. The rendered M8 PDF produced eight
recognized formulas. Analyze and Listen each initialized their engine once,
including duplicate request coalescing. Copy did not initialize math rules.

The first Copy payload was `A_{m-1}`. MathCAT returned
`cap a sub m minus 1 end sub`. The shared MLSR player presented **105,574 frames**
at volume zero and completed. Podoco and MLSR native handle counts both returned
to **zero** after cleanup. Copy was captured through the controller's clipboard
callback to preserve the user's clipboard. This is not human UI or pronunciation
acceptance. Timing marks are one active-host correctness run, not a benchmark.

The source receipt starts at `cbb3cfa` with the exact then-dirty file hashes.
That working tree also contained the paused FP32 support edits and a separate
Debug-pane UI edit; the native build therefore records those actual inputs.
The selected and executed model profile remained mixed v1, as the runtime
provenance confirms. The packaging commits leave those separate edits uncommitted.

## Build isolation correction

The first qualification attempt changed Xcode's products directory while sharing
its build database. Xcode removed the old generated app as a stale output, and
Flutter then failed to inspect its expected path. That attempt is preserved under
`bundled-assets-v1`; it is not passing evidence. The normal app was rebuilt,
signed and audited at its original path (`build/podoco-packaging-normal-restore.log`).
The build helper now uses independent Xcode intermediates and products for
qualification. The successful v2 run preserved that restored normal bundle and
left a second ordinary app at `bundled-assets-v2/products/Release/PoDoFo.app`.
