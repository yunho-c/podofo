# MLSR listening qualification — 2026-10-20

The macOS Apple Silicon implementation passes automated reader, native playback,
and relocated sandboxed Release checks. The author also confirmed successful
listening and native window interaction after completing the manual acceptance
checklist on 2026-10-20. Implementation is on `feat/mlsr-tts`, with MLSR pinned to
`14ff251eb7e9011801945233cf91ef8b444cd734` and the ten-voice
`supertonic3-coreml-fp16-t384-voices-v1` bundle.

## Tested boundary

Host: Apple M4 Pro / 48 GiB, macOS 27.0.1 (26A434), AC power. Flutter 3.47.5,
Dart 3.13.4, Rust 1.95.0. Builds are arm64 and locally ad-hoc signed with the
ordinary Release App Sandbox entitlements. macOS 15 is the declared minimum;
this run does not establish behavior on a macOS 15 machine or a notarized app.

| Check | Result |
| --- | --- |
| Flutter regression suite | 63 passed; one opt-in native speech test skipped |
| Additional minimum-window check | Reading preview and active reader pass at 760×520 |
| Flutter analysis | No issues |
| Preparation unit tests | Two passed; real preparation also succeeds twice |
| ObjectBox | Legacy UID migration passes; repeated generation is byte-identical |
| Real Core ML/native output | Earlier opt-in test passed with muted audio, pause/resume, replacement and cleanup |
| Packaged runtime | Four relocated sandboxed runs passed with real plugins, including two three-minute warm stress runs; no resource-path mocks |
| Dark inversion | Real Release Impeller offscreen pixels pass for normal and inverted source-region highlights |
| Release packaging | Exact inventory/hash match for 50 model/notice assets, 459,351,926 bytes; arm64 MLSR, portable linkage, nested signing |
| Native window interaction | Passed in the author's manual acceptance review on 2026-10-20 |
| Human listening | Author approved the exported sample and confirmed actual app playback on 2026-10-20 |
| Windows | x64 Release build and 63 regressions passed in [CI](https://github.com/yunho-c/podofo/actions/runs/39524485170); one opt-in native speech test skipped; model-free artifact inspected |

The regression suite uses real local PDF fixtures and a fake speech adapter for
deterministic UI/lifecycle behavior. It covers Unicode offsets, source geometry
on cropped/rotated pages, temporary highlights, tab switching, cancelled dirty
close, save/Save As, stale asynchronous work, source-hash resume validation,
two-column order, textless-page handling, and traversal of 24 pages with a
two-page plan cache. Additional regressions cover repeated/alternating margins,
pagination versus numeric chart labels, wrapped PDFium words, reversed source
emission, bookmark context and replacement versus speculative page preparation.
Test captures are not native-window screenshots. The ordinary widget engine
does not support Impeller image filters; inversion is exercised in the Release
probe using the production painter and shader.

## Real-paper reading order

The local diagnostic `tool/inspect_paper_test.dart` renders source pages with
PDFium and exports the complete prepared text, exclusions and source geometry.
These artifacts were compared visually for a representative single-column body
page and a two-column body page. This covers selected pages, not every page in
either paper or a general reading-order guarantee.

| Input | Reviewed result |
| --- | --- |
| [ViT, arXiv 2010.11929v2](https://arxiv.org/pdf/2010.11929v2), page 2 | Nine passages follow the single-column paragraphs; repeated publication header and page number are excluded |
| [ResNet, arXiv 1512.03385v1](https://arxiv.org/pdf/1512.03385v1), page 3 | Twenty-four passages read down the left column, then the right; the page number is excluded |
| ViT pages 1/3; ResNet pages 1/2/4 | Automatic order requires review for vertical margin text or complex figure/layout regions; explicit PDF-order output is available for inspection |

The review caught a real ordering bug: PDFium can return a joined word whose
character rectangles span two visual lines. Its page-wide word rectangle had
scrambled row grouping. The planner now separates visual runs and rejoins their
spoken slices without losing either source location. PDFium's
[hyphen marker implementation](https://pdfium.googlesource.com/pdfium/+/03baf4f3d7e756ac5ce4bc106a862908530df105/core/fpdftext/cpdf_textpage.cpp)
uses U+0002. PoDoFo preserves an uncertain compound hyphen unless the intact word
also occurs on that page; explicit soft hyphens can be removed. This is
conservative normalization, not dictionary-based pronunciation correction.

Equations remain literal extracted text; footnotes stay at their geometric
location, including before a continuation in the next column. Diagram labels,
tables and mixed layouts can require selected text or an explicit order. The
preview is therefore part of the reading workflow.

Corpus SHA-256 values:

- ViT: `8ce7b83971a14508ca711a27c875c9b6914c4f6767cf3150fb1ca6c07aa056d6`
- ResNet: `1e0651b6810ecba34a3dbc5b5b0209226f889004607c1f203540a48d64e5a93a`

The downloaded PDFs, page images and full extracted text remain local ignored
artifacts under `build/mlsr-qualification/corpus/`; they are not copied into Git.
Final reviews are in `vit-review-final/` and `resnet-review-final/`.

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
sentences, and completes an F1/1.4× request. Both extended runs perform
184 further cycles over 181.7/180.4 seconds, completing every eighth request and
cancelling the others after audio starts. All reuse one engine. After every
stop, retained PCM bytes and stores return to zero; one
engine handle remains until shutdown. Shutdown returns the handle count to its
baseline of zero. Peak retained audio during this fixture is 923,668 bytes in
two stores, below MLSR's 128 MiB / 128-store quota. Peak observed native handles
are four. These are repeated short-fixture bounds, not an hours-long paper result.

An initial attempt to wrap the signed app in `sandbox-exec` trapped in
`_libsecinit_appsandbox` before Flutter ran. The supported launch uses the app's
own signed sandbox and verifies its denials from inside the process. The
sandbox entitlement remains enabled throughout.

## Diagnostic measurements

Each run measures request admission to the first observed **presented**
source frame, polling every 20 ms. This is not an acoustic timestamp or pure
inference latency. Loading is included only in the cold-request figure. The
process is newly launched, but OS/Core ML caches were not cleared. No power or
background-process isolation was enforced beyond AC power and avoiding our own
build/test workload during the playback measurements.

| Measurement | First extended run (`plan-v2/`) | Final source (`plan-v2-final/`) |
| --- | --- | --- |
| Engine open | 22.055 s | 22.138 s |
| First presented audio with engine load | 22.490 s | 22.599 s |
| 184 warm first-audio observations | 223–1,291 ms; median 276 ms | 227–543 ms; median 294 ms |
| Two passage transitions | 275 ms and 325 ms | 273 ms and 319 ms |
| Stop and retention-snapshot observation | 0.3–45 ms; median 13 ms | 0.2–59 ms; median 13 ms |
| Peak RSS sampled every 50 ms | 322.1 MiB | 329.1 MiB |
| RSS after warm stops | Initially 291.2 MiB, finally 257.0 MiB; range 256.8–292.5 MiB | Initially 294.7 MiB, finally 260.7 MiB; range 260.4–296.1 MiB |
| Cache logical bytes before/after engine load | 113,539,996 → 170,309,994 | 170,309,994 → 227,079,992 |
| Cache file count before/after engine load | 52 → 78 | 78 → 104 |
| Cache growth during the warm loop | Zero bytes/files | Zero bytes/files |

The final run includes the fixes found by the real-paper review. It returns
native handles to zero and restores/audits the ordinary Release app.

Earlier twelve-cycle runs measured cold first audio at 22.602/22.655 s, warm
medians of 275/227 ms (ranges 220–722 / 207–296 ms), and transitions of
223/815 ms and 221/279 ms. Keep the outliers: these are active-host diagnostics,
not a throughput claim or latency guarantee. Passage transitions start the next
speech request after native playback completion. Text for the next page is
prepared ahead, but there is no audio prefetch queue. The UI shows loading
progress on first use.

Model/notice bytes are logical file sizes, not APFS private allocation or total
installed size. RSS includes Flutter, PDFium and the native runtime; Core ML
specialization caches and filesystem storage are separate. The measured cache
contains Apple's `com.apple.e5rt.e5bundlecache` model artifacts. The temporary
directory is nested within the cache directory on this host: do not add the two
reported byte counts together. Each new relocated bundle can cause new cache
artifacts; warm-loop stability does not establish a bound across upgrades or
relocations. Handle counts and PCM quotas do not measure all native allocations.

## Evidence and reproduction

### Windows compatibility

[Run 39524485170](https://github.com/yunho-c/podofo/actions/runs/39524485170)
passed on source commit `359546ece9b305df5b73d0971b434cd336775de7` after the
authorized branch push. The job ran for 7 minutes 46 seconds on Windows Server
2025 (10.0.26100), runner image `windows-2025-vs2026` version
`20261007.264.1`, using the repository's pinned Flutter SDK.

The job prepared MLSR `14ff251` for `x86_64-pc-windows-msvc` with listening
disabled, resolved the locked dependencies, checked formatting and regenerated
ObjectBox files, passed analysis, built `PoDoFo.exe` in Release mode, and passed
all 63 regressions. The real macOS speech test was explicitly skipped. Generated
files were compared after formatting and newline normalization, as specified in
`tool/verify.ps1`.

The uploaded `podofo-windows` artifact was downloaded and its SHA-256 verified
against GitHub's artifact digest:
`d23fde38c2d902124a52a47a3523ac6aea08254bfc83fb8a1cae1029356d1094`.
The archive is 22,103,240 bytes and contains 339 files totaling 50,282,836 logical
bytes. All 11 executable/library files have AMD64 PE headers, including
`PoDoFo.exe`, `mlsr_ffi.dll`, `objectbox.dll`, and `pdfium.dll`. No MLSR model
payload is included. The MLSR DLL SHA-256 is
`5561a8809936fd5188bd5359fc6b88666af34e1de703a090677a753683d02beb`.

This verifies the Windows reader's build, regression, and packaging path.
Listening remains supported only on macOS Apple Silicon; this run does not
qualify Windows speech or an interactive Windows app launch. The run metadata,
full CI log, downloaded archive, and per-file inspection receipt are retained
under `build/mlsr-qualification/windows-39524485170/`. GitHub's artifact expires
on 2026-10-28; the local evidence is retained independently.

### macOS and paper inspection

From `podofo_frontend_one`, after [preparation](tts-implementation.md#build-preparation):

```sh
python3 tool/test_macos.py
PODOFO_TEST_MLSR=1 python3 tool/test_macos.py test/narration_native_test.dart
python3 tool/qualify_mlsr_macos.py --stress-seconds 180
```

The qualification command creates a new evidence directory and refuses to
overwrite one. `qualification.json` contains the runtime receipt and relocation
path; new runs also record the commit, working-tree status and SHA-256 of the
application/probe source inputs. Bundle audits retain asset hashes, entitlements, linkage and pinned
native provenance. `runtime.log`, both build logs, the generated PDF and
`listening-sample.wav` are retained alongside it, as are the normal/inverted
offscreen paint images. The final run is under
`build/mlsr-qualification/plan-v2-final/`, and the first extended run under
`plan-v2/`; earlier short runs are under `final/` and the qualification root.
These ignored artifacts are not shipped in Git.

For a local paper already on disk, use a new output directory:

```sh
PODOFO_PDF=/absolute/path/paper.pdf \
PODOFO_PAPER_OUTPUT=/absolute/path/new-review-directory \
PODOFO_PAGES=2,3 PODOFO_ORDERS=automatic,pdfOrder \
python3 tool/test_macos.py tool/inspect_paper_test.dart
```

## Manual acceptance — passed 2026-10-20

The author reported that the listening sample sounds great, confirmed actual
playback, and completed the following checklist with satisfactory results. This
closes the remaining manual acceptance gates for the macOS Apple Silicon
implementation. These results come from the author's review; automated native
window inspection remained unavailable because Computer Use could not connect.

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
