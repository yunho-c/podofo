# MLSR listening qualification — 2026-10-20

The macOS Apple Silicon implementation passes automated reader, native playback,
and relocated sandboxed Release checks. Human listening and native window
interaction remain separate acceptance checks; neither is implied by these
results. Implementation is on `feat/mlsr-tts`, with MLSR pinned to
`14ff251eb7e9011801945233cf91ef8b444cd734` and the ten-voice
`supertonic3-coreml-fp16-t384-voices-v1` bundle.

## Tested boundary

Host: Apple M4 Pro / 48 GiB, macOS 27.0.1 (26A434), AC power. Flutter 3.47.5,
Dart 3.13.4, Rust 1.95.0. Builds are arm64 and locally ad-hoc signed with the
ordinary Release App Sandbox entitlements. macOS 15 is the declared minimum;
this run does not establish behavior on a macOS 15 machine or a notarized app.

| Check | Result |
| --- | --- |
| Flutter regression suite | 55 passed; one opt-in native speech test skipped |
| Additional minimum-window check | Reading preview and active reader pass at 760×520 |
| Flutter analysis | No issues |
| Preparation unit tests | Two passed; real preparation also succeeds twice |
| ObjectBox | Legacy UID migration passes; repeated generation is byte-identical |
| Real Core ML/native output | Earlier opt-in test passed with muted audio, pause/resume, replacement and cleanup |
| Packaged runtime | Two relocated sandboxed runs passed with real plugins, no resource-path mocks |
| Release packaging | Exact inventory/hash match for 50 model/notice assets, 459,351,926 bytes; arm64 MLSR, portable linkage, nested signing |
| Native window interaction | Not verified; Computer Use denied PoDoFo access, including the requested retry |
| Human listening | Sample exported; review pending |
| Windows | Portable preparation and CI wiring implemented; this branch has not run a Windows build or remote CI |

The regression suite uses real local PDF fixtures and a fake speech adapter for
deterministic UI/lifecycle behavior. It covers Unicode offsets, source geometry
on cropped/rotated pages, temporary highlights, tab switching, cancelled dirty
close, save/Save As, stale asynchronous work, source-hash resume validation,
two-column order, textless-page handling, and traversal of 24 pages with a
two-page plan cache. Test captures are not native-window screenshots.

## Packaged playback

`tool/qualify_mlsr_macos.py` builds `tool/mlsr_release_probe.dart`, relocates the
app outside the checkout, audits it, runs the probe, then rebuilds and audits the
ordinary app. The probe uses the production `MlsrNarrator`, `NarrationController`,
`PaperSequence`, PDF session and bookmark service. Only its entrypoint/window and
volume are test-specific. It creates a unique fixture/database directory without
opening the user's reader database. It uses the existing application sandbox
container; this is not a fresh-container test.

The final run explicitly receives permission errors for the checkout's
`pubspec.yaml`, the developer model manifest, and the prepared native library.
It also receives `EPERM` when connecting to an actually listening loopback TCP
socket. Model assets remain in the signed relocated bundle. No files or caches
were renamed or removed to simulate independence.

The native player completes three passages on two PDF pages, saves the source
bookmark on page 2, freezes its presented cursor while paused, resumes, navigates
sentences, and completes an F1/1.4× request. Twelve further start/stop cycles reuse
one engine. After every stop, retained PCM bytes and stores return to zero; one
engine handle remains until shutdown. Shutdown returns the handle count to its
baseline of zero. Peak retained audio during this fixture is 923,668 bytes in
two stores, below MLSR's 128 MiB / 128-store quota. Peak observed native handles
are four. These are short-fixture bounds, not an hours-long stress result.

An initial attempt to wrap the signed app in `sandbox-exec` trapped in
`_libsecinit_appsandbox` before Flutter ran. The supported launch uses the app's
own signed sandbox and verifies its denials from inside the process. The
sandbox entitlement remains enabled throughout.

## Diagnostic measurements

The final run measures request admission to the first observed **presented**
source frame, polling every 20 ms. This is not an acoustic timestamp or pure
inference latency. Loading is included only in the cold-request figure. The
process is newly launched, but OS/Core ML caches were not cleared. No power or
background-process isolation was enforced beyond AC power and avoiding our own
build/test workload during the playback measurements.

| Final run | Observed |
| --- | --- |
| Engine open | 22.185 s |
| First presented audio with engine load | 22.655 s |
| Twelve warm first-audio observations | 207–296 ms; median 227 ms |
| Two passage transitions | 221 ms and 279 ms |
| Stop and retention-snapshot observation | 4–14 ms |
| Peak RSS sampled every 50 ms | 334.6 MiB |
| RSS after twelve stops | About 288.9 MiB; approximately 0.25 MiB above the first stopped sample |

An earlier run measured 22.602 s for first audio, a 275 ms warm median
(220–722 ms), and transitions of 223/815 ms. Keep both results: these are
active-host diagnostics, not a throughput claim or latency guarantee. Passage
transitions currently start the next request after native playback completion;
there is no app-owned prefetch queue. The UI shows loading progress on first use.

Model/notice bytes are logical file sizes, not APFS private allocation or total
installed size. RSS includes Flutter, PDFium and the native runtime; Core ML
specialization caches and filesystem storage are separate. Handle counts and
PCM quotas do not measure all native allocations.

## Evidence and reproduction

From `podofo_frontend_one`, after [preparation](tts-implementation.md#build-preparation):

```sh
python3 tool/test_macos.py
PODOFO_TEST_MLSR=1 python3 tool/test_macos.py test/narration_native_test.dart
python3 tool/qualify_mlsr_macos.py
```

The qualification command creates a new evidence directory and refuses to
overwrite one. `qualification.json` contains the runtime receipt and relocation
path; bundle audits retain all asset hashes, entitlements, linkage and pinned
native provenance. `runtime.log`, both build logs, the generated PDF and
`listening-sample.wav` are retained alongside it. The final local run is under
`build/mlsr-qualification/final/`; the earlier run is under
`build/mlsr-qualification/`. These ignored artifacts are not shipped in Git.

## Manual acceptance still open

1. Open the generated qualification PDF through the native file picker. Review
   the detected order, start reading, pause/resume, navigate sentences, and check
   that the temporary highlight follows the spoken sentence.
2. Change voice/speed while paused, switch tabs, return to the source, then close
   it. Confirm that audio stops after the close decision, and that native window
   quit behaves correctly with unsaved annotations.
3. Listen to the exported sample and actual app playback for clipping, missing
   words, pronunciation, sentence joins and transition gaps. The exported WAV
   tests synthesis; it is not a recording of the native output device.

The other desktop targets and notarized distribution need their own build and
runtime qualification before widening the listening support statement.
