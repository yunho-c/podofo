# Core ML runtime fixture

`affine.mlmodel` is a tiny, MLSR-authored model (Apache-2.0) with Float32 input
`x` and outputs `y` and `z`, all shape `[1, 2, 3]`. Its operations are
`y = 2*x + 1` and `z = 3*x - 1`.
Copied from MLSR commit `14ff251eb7e9011801945233cf91ef8b444cd734` with its
generator and license unchanged; it is a dependency check, not a document model.
It contains no downloaded or trained weights. `generate.py` records its complete
construction using coremltools 9.0; regeneration is an explicit development step.

`tools/check_coreml.py` compiles the checked-in model with the installed Xcode
`coremlcompiler` and executes it using CPU-only Core ML. Compiled directories
remain with the ignored check output. No Python/Core ML Tools installation is
needed to run the check. The simple arithmetic has independently known outputs.
