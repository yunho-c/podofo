# C ABI

Include the generated `include/podoco.h` and link against `podoco_ffi`.
The scaffold provides two functions:

| Function | Contract |
| --- | --- |
| `uint32_t podoco_abi_version(void)` | Returns `1`. Check this before calling other exports. |
| `const char *podoco_version(void)` | Returns the library version as a borrowed, non-null, NUL-terminated UTF-8 string. |

The version pointer remains valid while the library is loaded. Never free or
modify it. Both functions are thread-safe, allocate nothing, and cannot panic.
The generated header supports C and C++ callers.

The ABI version describes binary compatibility, separately from the package's
semantic version. The current Dart wrapper accepts ABI 1. Breaking changes must
change the ABI version and update consumers; additive API changes still need
an explicit compatibility review.

Analysis handles, buffers, errors, and cancellation are not defined yet. Their
implementation must use explicit ownership/release, fixed-width C layouts,
opaque handles where appropriate, and panic containment. Rust remains the
owner of analysis lifecycle and result semantics; bindings translate that
contract rather than implementing independent pipelines.
