#!/usr/bin/env python3
"""Build, relocate and exercise sandboxed MLSR; restore the ordinary Release app."""

import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import tempfile
import time

from audit_mlsr_macos import audit


APP = Path(__file__).resolve().parents[1]
BUNDLE = APP / 'build/macos/Build/Products/Release/PoDoFo.app'


def run_logged(log, command, **kwargs):
    print(f'{log.name}: {command[0]}', flush=True)
    with log.open('wb') as stream:
        return subprocess.run(command, cwd=APP, stdout=stream,
                              stderr=subprocess.STDOUT, **kwargs)


def write_report(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def qualify(output, model_manifest):
    forbidden = [APP / 'pubspec.yaml', model_manifest.resolve(strict=True),
                 APP / '.mlsr/native/mlsr_ffi']
    if not all(path.is_file() for path in forbidden):
        raise ValueError('Denial checks need existing developer inputs')
    report = {'passed': False, 'platform': platform.platform(),
              'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    # Preserve the relocated bundle and logs for diagnosis; no developer inputs
    # are renamed, hidden, deleted, or granted additional permissions.
    relocated_root = Path(tempfile.mkdtemp(prefix='podofo-mlsr-release-'))
    relocated = relocated_root / 'PoDoFo Probe.app'
    report['relocated_bundle'] = str(relocated)
    print(f'Evidence: {output}\nRelocated bundle: {relocated}', flush=True)
    try:
        run_logged(output / 'probe-build.log',
                   ['bash', 'tool/build_macos_local.sh', 'release', '--target',
                    'tool/mlsr_release_probe.dart'], check=True)
        subprocess.run(['cp', '-cR', str(BUNDLE), str(relocated)], check=True)
        write_report(output / 'probe-bundle.json', audit(relocated, APP))
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            env = dict(os.environ,
                       PODOFO_FORBIDDEN_FILES=json.dumps(list(map(str, forbidden))),
                       PODOFO_DENIED_NETWORK_PORT=str(listener.getsockname()[1]))
            started = time.monotonic()
            # The signed app's own Sandbox denies file/network access. Nesting
            # sandbox-exec around it traps in libsecinit before Flutter starts.
            with (output / 'runtime.log').open('wb') as log:
                result = subprocess.run(
                    [str(relocated / 'Contents/MacOS/PoDoFo')],
                    cwd=relocated_root, env=env, stdout=log,
                    stderr=subprocess.STDOUT, timeout=300)
            report['process_seconds'] = time.monotonic() - started
        log = (output / 'runtime.log').read_text(errors='replace')
        receipts = [line.split('PODOFO_MLSR_REPORT=', 1)[1]
                    for line in log.splitlines() if 'PODOFO_MLSR_REPORT=' in line]
        if not receipts:
            raise RuntimeError(f'No runtime report; process exit {result.returncode}')
        receipt = json.loads(receipts[-1])
        report['runtime'] = receipt
        write_report(output / 'runtime-report.json', receipt)
        if directory := receipt.get('evidence_directory'):
            for name in ['qualification-paper.pdf', 'listening-sample.wav']:
                source = Path(directory) / name
                if source.is_file():
                    shutil.copy2(source, output / name)
        if result.returncode != 0 or receipt.get('passed') is not True:
            raise RuntimeError(f"Runtime qualification failed: {receipt.get('error', result.returncode)}")
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        # A qualification run must never leave the probe as the shipping app.
        try:
            run_logged(output / 'normal-build.log',
                       ['bash', 'tool/build_macos_local.sh', 'release'], check=True)
            write_report(output / 'normal-bundle.json', audit(BUNDLE, APP))
        except Exception as error:
            report['passed'] = False
            report['restore_error'] = str(error)
            raise
        finally:
            write_report(output / 'qualification.json', report)
    print('Sandboxed runtime and both bundle audits passed. Playback was muted.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path,
                        help='New evidence directory; an existing directory is never overwritten')
    parser.add_argument('--developer-model-manifest', type=Path,
                        default=Path.home() / '.cache/mlsr/models/supertonic3-coreml-fp16-t384-voices-v1/mlsr-bundle.yaml',
                        help='Existing local model manifest used only to verify sandbox denial')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('Run this qualification on macOS Apple Silicon')
    output = args.output or APP / 'build/mlsr-qualification' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    qualify(output, args.developer_model_manifest)


if __name__ == '__main__':
    main()
