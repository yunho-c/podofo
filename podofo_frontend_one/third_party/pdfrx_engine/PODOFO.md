# PoDoFo exclusive image lease extension

This is the runtime source of published **pdfrx_engine 0.6.1**, retaining its MIT
license. The source archive SHA-256 is
`f74ca9ea4ec722545f054a1d6ee1bf01222409ecd9458e5945c0cc5feaa3d2c6`.
The package remains paired with the locked PDFium 0.3.1 dependencies. Upstream
examples/tests/tools are omitted; the app carries focused native regression tests.
`../pdfrx_engine-source.json` pins original and patched file bytes, and
`../pdfrx_engine-podoco.patch` records the runtime/manifest changes. Modified text
files normalize upstream CRLF to LF; untouched files retain exact published bytes.

The app's local pdfrx dependency selects this relative engine path. The pub cache
and sibling repositories are not modified. `publish_to: none` replaces upstream
workspace resolution. The native source keeps upstream formatting and suppresses
an existing initializing-formal lint when analyzed inside the host application.

`PdfImage.tryTakeNativeLease()` is an additive extension backed by the optional
`PdfNativeImageOwner` capability. Native PDFium images transfer their malloc-owned
BGRA buffer only if `pixels` has never been read. Exposed writable views cause a
null result so callers can copy. Managed/web image implementations also return
null without new interface requirements. After transfer, original pixel access
and another transfer throw; disposing the original wrapper is harmless.

`PdfNativeImageLease` exposes dimensions, row/initialized/allocation bytes, a
native address, release state and idempotent release. It has no pixel-list API.
The native allocation is independent of the PDFium page/bitmap/document, which
were closed after rendering. A native finalizer is attached only after exclusive
transfer. Legacy PdfImage objects with escaped views do not gain a finalizer
that could invalidate a still-live typed-data view. Explicit lease release
frees through the same allocator used by rendering and detaches the finalizer.

This is an advanced ownership contract, not memory safety for arbitrary foreign
code: retain the lease until all readers stop, never mutate its storage or export
writable aliases, and do not transfer it between Dart isolates. PoDoFo imports
only fresh dedicated analysis images. Podoco's release callback retains the
lease until Rust drops its final reader; rejection releases it immediately.

Tests in `test/analysis_leases_test.dart` cover document/image closure, allocation
pressure, refused view-exposed transfers, copy fallback, rejected/accepted native
imports, delayed rendering after cancellation, failed sinks, real layout/formula
parity and formula-prefix cancellation. The qualification tool records handoff
copy counts and timing separately from rendering and inference. Updating the
engine requires reapplying/reviewing the patch, regenerating the source pin and
rerunning these native tests plus the viewer regressions.

M1 target-preview foundations also preserve XYZ destination coordinate presence
using PDFium's existing `FPDFDest_GetLocationInPage` API. Missing axes stay null;
actual coordinate zero stays zero. PDFium reports zero zoom as no zoom change.
Failure to read XYZ location leaves all three values unknown. Other destination
commands retain their upstream parsing. No native ABI or dependency version changes.
Native null/zero, rotated crop, navigation, and preview regressions cover this patch.
