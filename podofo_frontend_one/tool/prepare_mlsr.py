#!/usr/bin/env python3
"""Prepare the pinned MLSR SDK, native library and offline Flutter model package."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys


SDK_REVISION = "76ae48b684b4e9d42f3f581035e1cf8ff942837b"
SDK_URL = "https://github.com/yunho-c/MLSR.git"
APP = Path(__file__).resolve().parents[1]
ROOT = APP / ".mlsr"


def run(*args, cwd=None, env=None):
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)


def output(*args, cwd=None):
    return subprocess.check_output([str(arg) for arg in args], cwd=cwd, text=True).strip()


def target_for(system, machine):
    architecture = {"arm64": "aarch64", "aarch64": "aarch64", "amd64": "x86_64", "x86_64": "x86_64"}.get(machine.lower())
    suffix = {"Darwin": "apple-darwin", "Windows": "pc-windows-msvc", "Linux": "unknown-linux-gnu"}.get(system)
    if not architecture or not suffix:
        raise ValueError(f"Unsupported native desktop host: {system}/{machine}")
    return f"{architecture}-{suffix}"


def prepare_sdk(source):
    sdk = ROOT / "sdk"
    if not sdk.exists():
        # Refuse to reuse a partial clone. The original SDK is never modified.
        stage = ROOT / "sdk-install"
        if stage.exists():
            raise ValueError(f"Incomplete SDK preparation at {stage}; inspect it before retrying")
        run("git", "clone", "--no-checkout", "--no-hardlinks", source, stage)
        run("git", "checkout", "--detach", SDK_REVISION, cwd=stage)
        stage.rename(sdk)
    if output("git", "rev-parse", "HEAD", cwd=sdk) != SDK_REVISION:
        raise ValueError(f"SDK at {sdk} is not the pinned revision; refusing to overwrite it")
    if output("git", "status", "--porcelain", "--untracked-files=no", cwd=sdk):
        raise ValueError(f"SDK at {sdk} has modified tracked sources; refusing an unpinned build")
    return sdk


def prepare_model_free_package(sdk):
    package = ROOT / "model_assets"
    marker = package / ".model-free"
    if package.exists() and not marker.exists():
        raise ValueError("An existing model package is present; do not replace it with a model-free package")
    (package / "lib").mkdir(parents=True, exist_ok=True)
    marker.write_text("No model payload on this unsupported listening target.\n")
    (package / "pubspec.yaml").write_text(
        "name: mlsr_app_models\nversion: 0.1.0\npublish_to: none\n"
        "environment:\n  sdk: '>=3.11.0 <4.0.0'\n"
        "dependencies:\n  flutter:\n    sdk: flutter\n  mlsr:\n    path: ../sdk/bindings/dart\n"
    )
    (package / "lib/app_models.dart").write_text(
        "import 'package:mlsr/mlsr.dart';\n\n"
        "abstract final class AppModels {\n"
        "  static BundledModel get supertonic3 => throw const SynthesisException(\n"
        "    'model_platform_unsupported',\n"
        "    'Paper listening is available on macOS Apple Silicon.',\n"
        "  );\n}\n"
    )


def prepare(args):
    system = platform.system()
    target = target_for(system, platform.machine())
    listening = target == "aarch64-apple-darwin"
    ROOT.mkdir(exist_ok=True)
    sdk = prepare_sdk(args.sdk_source)
    build = ROOT / "native-build"
    features = ["mlsr-ffi/coreml", "mlsr-ffi/apple-output"] if listening else []
    env = os.environ.copy()
    if system == "Darwin":
        env.pop("IPHONEOS_DEPLOYMENT_TARGET", None)
        env["MACOSX_DEPLOYMENT_TARGET"] = "15.0"
        env["SDKROOT"] = output("xcrun", "--sdk", "macosx", "--show-sdk-path")
        env[f"CC_{target.replace('-', '_')}"] = output("xcrun", "--sdk", "macosx", "--find", "clang")
    command = ["cargo", "build", "--locked", "--release", "--target", target,
               "--target-dir", build, "-p", "mlsr-ffi"]
    if listening:
        command += ["-p", "mlsr-cli", "--features", ",".join(features)]
    run(*command, cwd=sdk, env=env)
    native_name = {"Darwin": "libmlsr_ffi.dylib", "Windows": "mlsr_ffi.dll", "Linux": "libmlsr_ffi.so"}[system]
    native_dir = ROOT / "native"
    native_dir.mkdir(exist_ok=True)
    destination = native_dir / "mlsr_ffi"
    temporary = native_dir / "mlsr_ffi.new"
    shutil.copy2(build / target / "release" / native_name, temporary)
    if system == "Darwin":
        run("codesign", "--force", "--sign", "-", temporary)
    temporary.replace(destination)
    (native_dir / "provenance.json").write_text(json.dumps({
        "sdk_revision": SDK_REVISION, "target": target, "features": features,
        "rustc": output("rustc", "--version", cwd=sdk),
        "sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
    }, indent=2) + "\n")
    if listening:
        run(build / target / "release/mlsr", "models", "prepare-flutter",
            "--config", APP / "mlsr-models.yaml", cwd=APP)
    else:
        prepare_model_free_package(sdk)
    print(f"Prepared MLSR {SDK_REVISION[:7]} for {target}; listening={listening}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-source", default=SDK_URL,
                        help="Git URL or local checkout containing the pinned revision")
    args = parser.parse_args()
    lock = ROOT / "prepare.lock"
    acquired = False
    try:
        ROOT.mkdir(exist_ok=True)
        lock.mkdir()
        acquired = True
        prepare(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"MLSR preparation failed: {error}", file=sys.stderr)
        return 1
    finally:
        if acquired:
            lock.rmdir()
    return 0


if __name__ == "__main__":
    sys.exit(main())
