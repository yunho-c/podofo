# cidre observer exclusion and namespacing

Recommendation: use an explicit observer feature gate for Podoco's initial
Core ML dependency, leaving it disabled. Keep per-library namespacing available
if a library later needs cidre's KVO convenience observer. Splitting the native
object alone is insufficient when consumers pass `-ObjC`.

This investigation produced reviewable patches and a runnable experiment.
Podoco now adopts the observer feature patch in its pinned, optional cidre
dependency. No upstream change has been submitted. Podoco's document inference
backend remains unimplemented; see [Core ML setup and checks](../coreml.md).

## Why the class is present

In cidre 0.29.0, enabling `ml` enables `ns`. `build.rs` compiles `pomace/ns/ns.m`,
which contains `CidreObserver` and includes `ns.h` with the Foundation class
initializers and exception helpers. Using those Foundation helpers brings in
the object file that also defines the observer, even without calling
`ns::Observer`.

MLSR's Core ML adapter does not call `ns::Observer` or `cidre_create_observer`.
Its audio configuration observer uses `objc2_foundation::NSNotificationCenter`,
and its SDK state observers are Rust logic; neither requires `CidreObserver`.
Podoco's optional cidre dependency does not enable the convenience observer.

The relevant upstream source is
[cidre's Foundation bridge](https://github.com/yury/cidre/blob/6f3b3626c98460301c979b4a76f60e23eb3f99f0/cidre/pomace/ns/ns.m).
The same helper was still present in upstream `main` when inspected on
2026-10-25; the candidate patches are qualified only against 0.29.0.

## Results

Measured on macOS 27.0.1 arm64 with Rust 1.95.0 and cidre 0.29.0. Release builds
use `strip = "none"`; explicit debug cases are included. The inference path is
MLSR's actual CPU-only Core ML runtime at commit
`14ff251eb7e9011801945233cf91ef8b444cd734` with its affine model fixture.

| Configuration | Duplicate-class warning | Functional checks |
| --- | --- | --- |
| Stock + stock | Yes, expected control | Core ML passed |
| Observer disabled in both | No | Core ML passed in release and debug |
| Observer disabled in one + existing MLSR dylib | No | Patched runtime inference and existing library identity passed |
| Observer feature enabled in both | Yes, expected control | KVO callbacks/drop and Core ML passed |
| Separate native object, KVO unused | No | Core ML passed |
| Separate native object with `-ObjC` | Yes, expected control | Core ML passed |
| Observer disabled with `-ObjC` | No | Core ML passed |
| Distinct per-library prefixes, KVO enabled | No | KVO callbacks/drop and Core ML passed |
| Same prefix in both libraries | Yes, expected control | KVO and Core ML passed |

All pairs ran in both loading orders. There were 22 pair cases, 168 successful
inference-probe calls (504 predictions), and 16 KVO lifecycle checks. Invalid
namespace spelling and use of the feature-disabled observer API were correctly
rejected at build time. All 11 selected MLSR runtime tests passed with the
observer disabled, including exception translation, stride handling, resource
release, shutdown, and concurrent caller behavior.

The intentionally colliding controls still completed their functional calls;
that does not make duplicate-class registration an acceptable production state.
Conversely, these checks do not qualify full speech/document pipelines, ANE
execution, iOS, other architectures, minimum OS versions, or native unload.

The observer-disabled release probe was 674,384 bytes, versus 675,840 bytes
unmodified: a 1,456-byte reduction. Namespacing added 144–160 bytes to the
KVO-enabled probes. These are helper-level changes, separate from the roughly
415 KiB duplication previously measured for a minimal second Rust/cidre dylib.

## Design implications

The feature patch adds `ns-observer = ["ns"]` and includes it in `full`, preserving
the default feature set's observer API. Applications using `default-features =
false` and the convenience observer would need to opt in explicitly. This is
an API migration for those consumers and needs upstream review. Core ML alone
continues to use `ml` without the helper. Cargo feature unification can enable
the observer if another dependency requests it in the same build graph.

The namespacing patch keeps the Rust API and C helper function name unchanged,
while changing the actual Objective-C class name. Separately built libraries
use different prefixes, for example `Mlsr` and `Podoco`. The build script tracks
the environment variable so changing a prefix rebuilds cidre's native bridge.
Reusing a prefix, or merely using the same version-derived name in both
libraries, recreates the collision. This patch specifically addresses
`CidreObserver`, not every custom Objective-C class in arbitrary cidre features.

For the current integration, only Podoco needs to omit the helper for it to
coexist with the existing MLSR dylib. This was tested directly, so changing the
MLSR checkout is not a prerequisite. The adopted copy is pinned under
`third_party/cidre`, with archive and per-file checksums. `tools/check_coreml.py`
checks the actual dependency in release, debug, and `-ObjC` builds and both
loading orders; the macOS CI job runs it. The full investigation below remains
separate evidence for all three candidate designs.

See the [reproducer and candidate patches](../../tools/cidre_coexistence/README.md)
and [recorded results](../../tools/cidre_coexistence/qualification.json). Raw
artifacts and logs are retained in
`podoco/evaluation-output/cidre-observer-reproduction-20261025/`.
