#!/usr/bin/env python3
"""Podoco development checks using Python 3.11+ and the existing environment."""

import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib

from verify_cidre import verify as verify_cidre
from verify_mathcat import verify as verify_mathcat

ROOT = Path(__file__).resolve().parents[1]
DART = ROOT / "bindings/dart"
TARGET = ROOT / "target"
NATIVE = TARGET / "debug"
VERSION = tomllib.loads((ROOT / "Cargo.toml").read_text())["workspace"]["package"][
    "version"
]


def run(*args, cwd=ROOT, env=None):
    command = [str(arg) for arg in args]
    print("+ " + shlex.join(command), flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True)


def library_name():
    if sys.platform == "darwin":
        return "libpodoco_ffi.dylib"
    if sys.platform == "win32":
        return "podoco_ffi.dll"
    if sys.platform.startswith("linux"):
        return "libpodoco_ffi.so"
    raise RuntimeError(f"Native checks are not configured for {sys.platform}.")


def build():
    run("cargo", "build", "--locked", "-p", "podoco-ffi", "--target-dir", TARGET)


def test_c():
    compiler = os.environ.get("CC") or shutil.which("gcc" if os.name == "nt" else "cc")
    if not compiler:
        raise RuntimeError("A C compiler is required (GCC/MinGW on Windows).")
    executable = NATIVE / ("ffi-smoke.exe" if os.name == "nt" else "ffi-smoke")
    flags = [] if os.name == "nt" else ["-Wl,-rpath," + str(NATIVE)]
    run(
        compiler,
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        ROOT / "tests/integration/ffi_smoke.c",
        "-I",
        ROOT / "include",
        "-L",
        NATIVE,
        "-l:podoco_ffi.dll.lib" if os.name == "nt" else "-lpodoco_ffi",
        *flags,
        "-o",
        executable,
    )
    run(executable, VERSION)


def dart_get(cwd=DART):
    run("dart", "pub", "get", "--enforce-lockfile", cwd=cwd)


def test_dart():
    dart_get()
    run(
        "dart",
        "format",
        "--output=none",
        "--set-exit-if-changed",
        "lib",
        "hook",
        "tool",
        "test",
        "example",
        cwd=DART,
    )
    run("dart", "analyze", "--fatal-infos", cwd=DART)
    environment = dict(os.environ, PODOCO_EXPECTED_VERSION=VERSION)
    run("dart", "test", cwd=DART, env=environment)
    run("dart", "run", "example/version.dart", cwd=DART)


def generate(check=False):
    run(
        "cargo",
        "run",
        "--locked",
        "-p",
        "podoco-codegen",
        *(["--", "--check"] if check else []),
    )
    dart_get()
    run(
        "dart",
        "run",
        "tool/generate_bindings.dart",
        *(["--check"] if check else []),
        cwd=DART,
    )


def test_standalone():
    """Exercise the public Dart package without access to checkout Rust sources."""
    with tempfile.TemporaryDirectory(prefix="podoco-standalone-") as temporary:
        root = Path(temporary)
        package = root / "package"
        shutil.copytree(
            DART,
            package,
            ignore=shutil.ignore_patterns(".dart_tool", "build", ".DS_Store"),
        )
        native = root / library_name()
        shutil.copyfile(NATIVE / library_name(), native)
        manifest = package / "pubspec.yaml"
        original = manifest.read_text()

        def select_library(path):
            # A JSON string is a valid YAML scalar, including Windows paths.
            manifest.write_text(
                original + "\nhooks:\n  user_defines:\n    podoco:\n"
                f"      native-library: {json.dumps(str(path))}\n"
            )

        select_library(native)
        dart_get(package)
        environment = dict(os.environ, PODOCO_EXPECTED_VERSION=VERSION)
        run("dart", "test", cwd=package, env=environment)
        run("dart", "run", "example/version.dart", cwd=package)

        incompatible = root / "incompatible" / library_name()
        incompatible.parent.mkdir()
        run(
            "rustc",
            "--edition",
            "2024",
            "--crate-type",
            "cdylib",
            "-C",
            "strip=none",
            ROOT / "tests/integration/incompatible_abi.rs",
            "-o",
            incompatible,
        )
        select_library(incompatible)
        result = subprocess.run(
            ["dart", "run", "example/version.dart"],
            cwd=package,
            capture_output=True,
            text=True,
        )
        message = "Podoco ABI 1 is incompatible with ABI 2."
        if result.returncode == 0 or message not in result.stderr:
            raise RuntimeError(
                f"Incompatible ABI was not rejected:\n{result.stdout}\n{result.stderr}"
            )
        print("Dart correctly rejected the incompatible native ABI.", flush=True)

        layout_only = root / "layout-only" / library_name()
        layout_only.parent.mkdir()
        run(
            "rustc",
            "--edition",
            "2024",
            "--crate-type",
            "cdylib",
            "-C",
            "strip=none",
            ROOT / "tests/integration/layout_only_abi.rs",
            "-o",
            layout_only,
        )
        select_library(layout_only)
        guard = package / "example/formula_extension_guard.dart"
        guard.write_text(
            "import 'package:podoco/podoco.dart';\n"
            "Future<void> main() async {\n"
            "  for (final call in [() => FormulaBundle.verify('unused'),\n"
            "                       () => MathRules.verify('unused')]) {\n"
            "    var rejected = false;\n"
            "    try { await call(); } on PodocoException catch (e) {\n"
            "      if (e.code != 'unsupported_capability') rethrow;\n"
            "      rejected = true;\n"
            "    }\n"
            "    if (!rejected) throw StateError('Missing extension accepted');\n"
            "  }\n"
            "}\n"
        )
        run("dart", "run", guard, cwd=package)
        print(
            "Dart rejected missing formula/math support before resolving symbols.",
            flush=True,
        )


def check():
    verify_cidre()
    verify_mathcat()
    run(sys.executable, ROOT / "tools/pp_doclayout_v3/reference.py", "check-fixtures")
    # Keep upstream formatting and source pins intact in path dependencies.
    run("cargo", "fmt", "-p", "podoco", "-p", "podoco-ffi", "-p", "podoco-codegen", "--check")
    run(
        "cargo",
        "clippy",
        "--locked",
        "--workspace",
        "--all-targets",
        "--",
        "-D",
        "warnings",
    )
    run("cargo", "test", "--locked", "--workspace")
    run("cargo", "run", "--locked", "-p", "podoco", "--example", "contracts")
    run(
        "cargo",
        "doc",
        "--locked",
        "--no-deps",
        "-p",
        "podoco",
        "-p",
        "podoco-ffi",
        env=dict(os.environ, RUSTDOCFLAGS="-D warnings"),
    )
    run("cargo", "run", "--locked", "-p", "podoco-codegen", "--", "--check")
    build()
    test_c()
    test_dart()
    test_standalone()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=[
            "build",
            "check",
            "generate",
            "check-generated",
            "test-c",
            "test-dart",
            "test-standalone",
        ],
    )
    command = parser.parse_args().command
    if command in {"test-c", "test-standalone"}:
        build()
    commands = {
        "build": build,
        "check": check,
        "generate": generate,
        "check-generated": lambda: generate(check=True),
        "test-c": test_c,
        "test-dart": test_dart,
        "test-standalone": test_standalone,
    }
    try:
        commands[command]()
    except (subprocess.CalledProcessError, OSError, RuntimeError) as error:
        parser.exit(1, f"Podoco check failed: {error}\n")


if __name__ == "__main__":
    main()
