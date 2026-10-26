# Podoco for Dart

A typed Dart SDK for Rust-owned document layout analysis. `Analyzer` provides
lazy rendering, eager jobs, serial async update sinks, cancellation, and owned
results. PP-DocLayoutV3 runs through Core ML on macOS; request
`FormulaScope.none` until the selected PP-FormulaNet_plus-L recognizer is added.
The layout export remains experimental with the known M2 conversion differences.

## Native build

The desktop host build hook defaults to portable Rust/image/transport support.
For macOS Core ML, configure the **consuming application's** `pubspec.yaml`:

```yaml
dependencies:
  podoco:
    path: ../podoco/bindings/dart
hooks:
  user_defines:
    podoco:
      coreml: true
```

It needs the Rust workspace, Rust on `PATH`, and Xcode. The Core ML build uses
at least macOS 15; application deployment must honor that floor. The hook tracks
Rust sources, embedded manifests, and vendored cidre inputs. Mobile, web,
cross-compilation, and static linking through this hook remain unsupported.
No model weights are downloaded during builds. Linux portable targets use glibc.

A relocated package can instead select a matching prebuilt artifact:

```yaml
hooks:
  user_defines:
    podoco:
      native-library: /absolute/path/to/libpodoco_ffi.dylib
```

Use `.so` on Linux or `podoco_ffi.dll` on Windows. ABI 2 is checked before analysis
symbols are used; an old identity-only library fails cleanly. `coreMlAvailable`
reports the compiled backend flag. `Analyzer.capabilities` reports loaded-model
operations. Prebuilt files must themselves satisfy the platform/deployment floor.

## Analyze

Implement `PageSource` with cheap immutable document/revision metadata, an ordered
unique page list, and `Future<PageInput> loadPage(PageRequest)`. Construct each
image only after that request supplies its byte budget. Return the exact page,
image, pixel-edge-to-page affine map, and a versioned render profile.

```dart
final bundle = await ModelBundle.verify(bundleDirectory);
final analyzer = await Analyzer.open(bundle, options: analyzerOptions);
try {
  final job = analyzer.analyzeDocument(
    pages: source,
    options: AnalysisOptions(
      profile: bundle.profile,
      formulaScope: FormulaScope.none,
    ),
    onUpdate: (update) async {
      await persist(update.toJson());
    },
  );
  final outcome = await job.done;
  await job.dispose();
} finally {
  await analyzer.dispose();
}
```

`done` works with no progress subscription. `progress` is optional/coalesced;
`latestProgress` is a snapshot. Awaiting `onUpdate` applies backpressure while
source/control pumps continue. Updates and their nested collections are immutable.
The sealed update types are `PageLayoutReady`, `FormulaFinished`, `PageFinished`,
`PageFailed`, and `DocumentFinished`; unknown required variants/schema versions
fail explicitly. Persist the deeply immutable `update.toJson()` envelope.

The [runnable example](example/document_layout.dart) analyzes raw RGBA/BGRA files
listed by a small JSON manifest. Arguments are bundle, compute policy, input
bytes, tensor bytes, total result bytes, maximum update bytes, pending update
count, and manifest path. Each manifest page has `pixels` (path or file URI),
`page` (key/space), `image` (descriptor), `pixel_to_page`, and `render_profile`;
the root also has `document`. This example keeps decoding/rendering outside the
SDK. For PDFs, PoDoFo supplies its own renderer/coordinate adapter in M5.

## Lifetime and results

`PageImage.copy` stages managed Dart bytes into native memory and Rust-owned
immutable storage. Its constructor completes the copy before returning.
`PageImage.importNative` is an advanced renderer boundary: exclude every writable
alias and keep the allocation alive until `onRelease` runs. A rejected import
keeps caller ownership. `dispose` waits for the release notification. This
handoff does not promise zero-copy preprocessing or Core ML device execution.

Returning `PageInput` transfers its image to the job pump, which disposes it on
success, rejection, cancellation, and late render completion. `CancellationToken`
lets renderers respond to user cancellation or native failure. `job.cancel()`
returns promptly; `done`/`dispose` wait for native drain, outstanding Dart source
and sink callbacks, image release notifications, and queued native wakeups.
Callbacks that never return can delay disposal. Native inference cannot be
interrupted mid-prediction.

Do not await `job.done`, job disposal, or analyzer disposal from that analyzer's
source/sink callback. A zone guard rejects those waits; cancellation is safe.
Normal flows explicitly dispose analyzers/images. Jobs release their native
handles after completion; finalizers are only a leak backstop. The wrapper
retains one active source and sink, not every page's results; storage retained
by the application after acknowledgement remains its responsibility.

`AnalysisOutcome.status` is authoritative. Its processing summary and acknowledged
delivery counts are separate: failure to persist the terminal notice can produce
a failed overall outcome with completed processing. Already accepted results
remain usable after cancellation. Formula states are explicitly not-requested
for layout-only work; no fake LaTeX result is produced.

From this package: `dart pub get --enforce-lockfile`, `dart analyze`, and
`dart test`. Native document tests are opt-in through
[`tools/check_dart_jobs.py`](../../tools/check_dart_jobs.py). The package is private
and is not yet added to PoDoFo's application dependencies.
