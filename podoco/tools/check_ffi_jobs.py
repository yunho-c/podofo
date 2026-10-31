#!/usr/bin/env python3
"""Co-load actual Podoco/MLSR SDK artifacts and run a real C ABI layout job."""

import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
U = C.c_uint64
P = C.POINTER(U)


class Bytes(C.Structure):
    _fields_ = [("data", C.POINTER(C.c_uint8)), ("len", U)]


class Image(C.Structure):
    _fields_ = [
        (name, C.c_uint32)
        for name in (
            "struct_size",
            "width",
            "height",
            "pixel_format",
            "alpha_mode",
            "reserved",
        )
    ]
    _fields_.append(("row_bytes", U))


def data(value):
    raw = value if isinstance(value, bytes) else json.dumps(value).encode()
    owner = C.create_string_buffer(raw)
    view = Bytes(C.cast(owner, C.POINTER(C.c_uint8)), len(raw))
    view._owner = owner
    return view


def load(podoco, mlsr, bundle, reverse):
    paths = [mlsr, podoco] if reverse else [podoco, mlsr]
    libraries = [C.CDLL(str(p), mode=C.RTLD_LOCAL) for p in paths]
    lib = libraries[1 if reverse else 0]
    speech = libraries[0 if reverse else 1]
    speech.mlsr_version.restype = C.c_char_p
    assert speech.mlsr_version()
    signatures = {
        "podoco_analyzer_open": [Bytes, P, P],
        "podoco_analyzer_close": [U, P],
        "podoco_job_start": [U, Bytes, C.c_void_p, U, P, P],
        "podoco_source_next": [U, P, P],
        "podoco_image_copy": [C.POINTER(Image), Bytes, U, P, P],
        "podoco_source_reply": [U, U, U, Bytes, P],
        "podoco_result_next": [U, P, P],
        "podoco_result_ack": [U, U, Bytes, P],
        "podoco_job_outcome": [U, P, P],
        "podoco_buffer_view": [U, C.POINTER(Bytes), P],
        "podoco_release": [U],
    }
    for name, args in signatures.items():
        fn = getattr(lib, name)
        fn.argtypes, fn.restype = args, C.c_int32
    lib.podoco_abi_version.restype = C.c_uint32
    lib.podoco_live_handles.restype = U
    assert lib.podoco_abi_version() == 2
    assert lib.podoco_live_handles() == 0

    def buffer(handle):
        view = Bytes()
        try:
            assert lib.podoco_buffer_view(handle, C.byref(view), None) == 0
            assert view.len <= 4 * 1024 * 1024
            return json.loads(C.string_at(view.data, view.len))
        finally:
            assert lib.podoco_release(handle) == 0

    def call(name, *args, output=False):
        error, result = U(), U()
        outputs = [C.byref(result)] if output else []
        status = getattr(lib, name)(*args, *outputs, C.byref(error))
        if status < 0:
            raise RuntimeError(buffer(error.value) if error.value else name)
        return status, result.value

    document = {"id": "ffi-coexistence", "revision": "1"}
    page = {"key": {"document": document, "page_index": 0}, "space": [2, 2]}
    profile = "pp-doclayout-v3-transformers-5.8.1-score030-stable-v1"
    analyzer = job = 0
    try:
        _, analyzer = call(
            "podoco_analyzer_open",
            data(
                {
                    "schema_version": 0,
                    "bundle_directory": str(bundle),
                    "options": {
                        "compute_policy": "cpu_and_neural_engine",
                        "limits": {
                            "queued_jobs": 1,
                            "input_bytes": 16,
                            "pending_updates": 2,
                            "result_bytes": 40000,
                            "max_update_bytes": 20000,
                            "tensor_bytes": 96000000,
                            "decoder_cache_bytes": 1,
                        },
                    },
                }
            ),
            output=True,
        )
        _, job = call(
            "podoco_job_start",
            analyzer,
            data(
                {
                    "schema_version": 0,
                    "document": document,
                    "pages": [page],
                    "options": {"profile": profile, "formula_scope": "none"},
                }
            ),
            None,
            0,
            output=True,
        )
        received = []
        deadline = time.monotonic() + 20
        while True:
            if time.monotonic() > deadline:
                raise RuntimeError("C job did not drain within qualification deadline")
            status, value = call("podoco_source_next", job, output=True)
            if status == 0:
                request = buffer(value)
                image = Image(C.sizeof(Image), 2, 2, 1, 0, 0, 8)
                _, handle = call(
                    "podoco_image_copy",
                    C.byref(image),
                    data(bytes([255] * 16)),
                    16,
                    output=True,
                )
                try:
                    call(
                        "podoco_source_reply",
                        job,
                        request["token"],
                        handle,
                        data(
                            {
                                "schema_version": 0,
                                "page": request["page"],
                                "pixel_to_page": [1, 0, 0, 1, 0, 0],
                                "render_profile": "ffi-coexistence-v1",
                            }
                        ),
                    )
                finally:
                    assert lib.podoco_release(handle) == 0
            status, value = call("podoco_result_next", job, output=True)
            if status == 0:
                update = buffer(value)
                received.append(update)
                call("podoco_result_ack", job, update["sequence"], Bytes())
            status, value = call("podoco_job_outcome", job, output=True)
            if status == 0:
                outcome = buffer(value)["outcome"]
                break
            time.sleep(0.001)
        assert outcome["status"] == "completed" and len(received) == 3
        assert outcome["delivered"]["pages_finished"] == 1
    finally:
        if job:
            assert lib.podoco_release(job) == 0
        if analyzer:
            call("podoco_analyzer_close", analyzer)
            assert lib.podoco_release(analyzer) == 0
    assert lib.podoco_live_handles() == 0
    return {
        "load_order": [p.name for p in paths],
        "predictions": 1,
        "updates": len(received),
        "live_handles": 0,
        "status": outcome["status"],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("podoco", "mlsr", "bundle", "output"):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument(
        "--child", choices=("forward", "reverse"), help=argparse.SUPPRESS
    )
    args = parser.parse_args()
    if args.child:
        print(
            json.dumps(
                load(
                    args.podoco.resolve(),
                    args.mlsr.resolve(),
                    args.bundle.resolve(),
                    args.child == "reverse",
                )
            )
        )
        return
    args.output.mkdir(parents=True, exist_ok=True)
    records = []
    for order in ("forward", "reverse"):
        command = [sys.executable, str(Path(__file__).resolve()), "--child", order]
        for name in ("podoco", "mlsr", "bundle", "output"):
            command += [f"--{name}", str(getattr(args, name).resolve())]
        result = subprocess.run(
            command, text=True, capture_output=True, check=True, timeout=60
        )
        (args.output / f"{order}.log").write_text(result.stdout + result.stderr)
        if " is implemented in both " in result.stderr:
            raise RuntimeError("Duplicate Objective-C class registration")
        records.append(json.loads(result.stdout))
    summary = {
        "gate": "m4-actual-sdk-coexistence-v1",
        "cases": records,
        "sha256": {
            name: hashlib.sha256(getattr(args, name).read_bytes()).hexdigest()
            for name in ("podoco", "mlsr")
        },
    }
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(
        "Actual Podoco and MLSR SDKs co-loaded in both orders; real layout jobs passed."
    )


if __name__ == "__main__":
    main()
