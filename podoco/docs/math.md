# Optional math conversion

Enable Cargo feature `math` on `podoco` or `podoco-ffi`. It is independent of
`coreml`, model assets and MLSR. For a source-built Dart consumer, set
`hooks.user_defines.podoco.math: true`; this can coexist with `coreml: true`.
Prebuilt libraries must themselves contain the feature. `mathAvailable` probes
the compiled feature before resolving additive ABI-2 exports.

`MathProcessor` converts a single explicit LaTeX expression or presentation
MathML to owned MathML and plain speech text. It never changes recognized LaTeX,
plays audio, infers a TTS voice, or passes failed conversion through as speech.
Keep Copy LaTeX usable when conversion fails. The strict converter is
`pulldown-latex` 0.8.0; speech uses MathCAT 0.7.7 with the reviewed host-isolation
patch and exact offline rule set. Both are compatible with Rust 1.88.

## Offline rules

Provision the rules from an existing checksum-verified published MathCAT 0.7.7
crate directory. The preparation tool copies only the pinned payloads, using
APFS clones on macOS, then publishes a new directory without overwriting one:

```sh
python3 tools/math/prepare.py --source /path/to/mathcat-0.7.7 \
  --output model-assets/mathcat-0.7.7
cargo run --locked --release -p podoco --features math --example math -- \
  model-assets/mathcat-0.7.7 en ClearSpeak 'x+2' '\frac{a}{b}'
```

This optional preparation script uses the existing Python/PyYAML environment;
it does not install packages or fetch rules. The rule bundle is 238 payloads
(9,783,133 bytes), including the MIT license, plus `podoco-rules.yaml`.
`MathRules::verify`/`MathRules.verify` require the exact manifest and inventory,
then hash every file. Opening verifies again. Keep files and link targets
immutable while processors use them. Missing, changed and extra assets fail.

## API and lifetime

```dart
final rules = await MathRules.verify(rulesDirectory);
final math = await MathProcessor.open(rules, limits: MathLimits());
try {
  final speech = await math.toSpeech(
    MathInput.latex(latex, displayKind: FormulaDisplayKind.displayed),
    const MathSpeechOptions(language: 'en', speechStyle: 'ClearSpeak'),
  );
  // The application may submit speech.text to its selected TTS voice.
  // Cache against the source, display context, options and speech.provenance.
} finally {
  await math.dispose();
}
```

Rust uses the same types with blocking `open`, `to_mathml`, `to_speech`, and
`close`; call them off UI threads. Dart performs verification/conversion/close
off the calling isolate. Each processor owns a separate worker and MathCAT
thread-local state. The bounded native FIFO excludes one active request. Dart
also bounds bridge admission before creating isolates. Concurrent Dart calls
are ordered by native admission, not guaranteed by Dart invocation order.

Close cancels queued conversions, drains the active conversion and joins the
worker. It is idempotent and leaves other processors, analyzers and MLSR alone.
Dart waits for all outstanding bridge calls before releasing the handle; a
bridge arriving after close returns an owned closed-processor error. Await
disposal explicitly. There is no per-expression interruption of MathCAT.
Unexpected worker panics fail active/queued requests and close the processor;
ordinary conversion errors leave it reusable.

Default limits are four queued requests, 64 KiB input, 256 KiB output, 8192
parser events/XML nodes and 64 nesting levels. Valid configurable maxima are
32 queued requests, 64 KiB input, 1 MiB output, 8192 nodes and 64 levels.
The strict profile additionally permits at most 256 control sequences and
rejects macro definitions/expansion directives. Input, rendered MathML and
serialized results have byte bounds. These are logical limits: dependency
internals, loaded rule tables, allocator overhead and the 8 MiB worker stack
are outside them. They are not a process RSS cap or an execution sandbox.

## Syntax, context and speech preferences

The converter fails on unsupported/malformed syntax. It strips one complete
enclosing `$...$`, `$$...$$`, `\(...\)` or `\[...\]` for parsing, recording a
diagnostic; mixed math/text fences fail. It does not repair commands or rewrite
the original recognized string. MathML is checked for XML validity, bounded
nodes/depth, allowed presentation elements and fixed child counts. Document
types, external resources, processing instructions, foreign elements and
interactive attributes are rejected. Direct MathML must agree with the explicit
display context (`display="block"` for displayed math). Unknown context uses
inline semantics with a diagnostic; it does not change recognition metadata.

Use the processor's `languages` to select an installed base language and exact
speech style. Regional language fallback is not exposed by this v1 profile.
Unsupported language/style returns `unsupported_capability`. Each speech request
applies all public preferences and fixed plain-text behavior before installing
the expression. No operating-system locale, host MathCAT preferences, automatic
style fallback or process-global panic-hook replacement is used.

`MathSpeechOptions` includes language, style, `Terse`/`Medium`/`Verbose`, decimal
separators and digit-group separators. Default numeric semantics are dot decimal
and comma/space/NBSP/narrow-NBSP grouping, independent of the speech language.
Callers must explicitly choose other numeric conventions; separator sets must
be disjoint. Results carry effective options plus SDK, converter, MathCAT,
integration-profile and rule-manifest identities. Available rules do not imply
human listening qualification for every language.

The [M7 report](internal/m7-math-validation.md) records real recognizer coverage,
reviewable MathML/text, exact Rust/C/Dart parity, worker and host-effect tests.
Successful conversion is not proof that a recognized equation or its spoken
interpretation matches the document. Audible MLSR/UI acceptance remains separate.
