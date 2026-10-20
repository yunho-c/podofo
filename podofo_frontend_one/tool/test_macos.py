#!/usr/bin/env python3
"""Run Flutter regressions against the native database shipped in the macOS app."""
import argparse
import os
from pathlib import Path
import subprocess


def main():
    app = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path, default=app.parent / ".fvm/flutter_sdk")
    parser.add_argument("tests", nargs="*", default=["test"])
    args = parser.parse_args()
    sdk = args.flutter_sdk.resolve(strict=True)
    native = app / "build/macos/Build/Products/Release/PoDoFo.app/Contents/Frameworks/ObjectBox.framework/ObjectBox"
    native = native.resolve(strict=True)
    links = app / ".mlsr/test-libs"
    links.mkdir(parents=True, exist_ok=True)
    link = links / "libobjectbox.dylib"
    if link.is_symlink():
        link.unlink()
    elif link.exists():
        raise RuntimeError(f"Refusing to replace non-symlink {link}")
    link.symlink_to(native)
    env = os.environ.copy()
    env["PDFIUM_PATH"] = str((native.parents[3] / "PDFium.framework/pdfium").resolve(strict=True))
    env["DYLD_LIBRARY_PATH"] = str(links) + (":" + env["DYLD_LIBRARY_PATH"] if env.get("DYLD_LIBRARY_PATH") else "")
    # The shell launcher passes through protected macOS executables that strip
    # DYLD_* variables. Invoke the Flutter tool's Dart VM directly instead.
    result = subprocess.run([
        str(sdk / "bin/cache/dart-sdk/bin/dart"),
        str(sdk / "bin/cache/flutter_tools.snapshot"),
        "test", "--no-pub", "--reporter", "expanded", *args.tests,
    ], cwd=app, env=env)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
