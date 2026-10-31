"""Child-process loading, actual Core ML inference, and KVO lifecycle check."""

import concurrent.futures
import ctypes
import json
import sys
from pathlib import Path

spec = json.loads(Path(sys.argv[1]).read_text())
libs = [ctypes.CDLL(path) for path in spec["libraries"]]
for lib in libs:
    if hasattr(lib, "mlsr_coreml_probe"):
        lib.mlsr_coreml_probe.argtypes = [
            ctypes.c_char_p,
            ctypes.c_void_p,
            ctypes.c_size_t,
        ]
        lib.mlsr_coreml_probe.restype = ctypes.c_int
    if hasattr(lib, "probe_kvo"):
        lib.probe_kvo.restype = ctypes.c_int
        assert lib.probe_kvo() == 0
    if hasattr(lib, "mlsr_version"):
        lib.mlsr_version.restype = ctypes.c_char_p
        assert lib.mlsr_version() == b"0.1.0"


def inference(lib):
    if not hasattr(lib, "mlsr_coreml_probe"):
        return 0
    for _ in range(2):
        diagnostic = ctypes.create_string_buffer(4096)
        code = lib.mlsr_coreml_probe(
            spec["model"].encode(), diagnostic, len(diagnostic)
        )
        if code != 0:
            raise RuntimeError(diagnostic.value.decode())
    return 2


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    counts = list(pool.map(inference, libs * 2))
print(
    json.dumps(
        {
            "inference_calls": sum(counts),
            "kvo_libraries": sum(hasattr(lib, "probe_kvo") for lib in libs),
        }
    )
)
