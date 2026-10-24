#!/usr/bin/env python3
"""Build, relocate and exercise sandboxed MLSR; restore the ordinary Release app."""

import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import socket
import subprocess
import tempfile
import time

from audit_mlsr_macos import audit


APP = Path(__file__).resolve().parents[1]
BUNDLE = APP / 'build/macos/Build/Products/Release/PoDoFo.app'
ARTIFACTS = {'qualification-paper.pdf', 'listening-sample.wav',
             'highlight-normal.png', 'highlight-inverted.png',
             'timeline-paper.pdf', 'timeline-report.json'}


def run_logged(log, command, **kwargs):
    print(f'{log.name}: {command[0]}', flush=True)
    with log.open('wb') as stream:
        return subprocess.run(command, cwd=APP, stdout=stream,
                              stderr=subprocess.STDOUT, **kwargs)


def write_report(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def source_receipt():
    """Record the actual application/probe inputs, including uncommitted work."""
    roots = ['lib', 'macos', 'shaders', 'tool',
             'pubspec.yaml', 'pubspec.lock', 'mlsr-models.yaml',
             'test/fixtures/narration_pdf_fixture.dart']
    listed = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z',
         '--', *roots], cwd=APP).decode().split('\0')
    files = sorted({name for name in listed if name and (APP / name).is_file()})
    return {
        'commit': subprocess.check_output(
            ['git', 'rev-parse', 'HEAD'], cwd=APP, text=True).strip(),
        'status': subprocess.check_output(
            ['git', 'status', '--short', '--', *roots], cwd=APP, text=True),
        'sha256': {name: hashlib.sha256((APP / name).read_bytes()).hexdigest()
                   for name in files},
    }


def qualify(output, model_manifest, stress_seconds):
    forbidden = [APP / 'pubspec.yaml', model_manifest.resolve(strict=True),
                 APP / '.mlsr/native/mlsr_ffi']
    if not all(path.is_file() for path in forbidden):
        raise ValueError('Denial checks need existing developer inputs')
    report = {'passed': False, 'platform': platform.platform(),
              'source': source_receipt(),
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
            env = {
                'PODOFO_FORBIDDEN_FILES': json.dumps(list(map(str, forbidden))),
                'PODOFO_STRESS_SECONDS': str(stress_seconds),
                'PODOFO_DENIED_NETWORK_PORT': str(listener.getsockname()[1]),
            }
            started = time.monotonic()
            # Launch as a GUI application, matching ordinary user launches.
            # Direct executable launches can stall paused Core ML/reader work.
            # The signed app's own Sandbox supplies the denial boundary.
            report['launch'] = 'macOS Launch Services (open -n -W)'
            runtime_log = output / 'runtime.log'
            command = ['/usr/bin/open', '-n', '-W', str(relocated),
                       '--stdout', str(runtime_log), '--stderr', str(runtime_log)]
            for key, value in env.items():
                command += ['--env', f'{key}={value}']
            try:
                result = run_logged(output / 'launcher.log', command,
                                    timeout=300 + stress_seconds)
            except subprocess.TimeoutExpired:
                # open -W is only a launcher; do not leave its probe running.
                lines = runtime_log.read_text(errors='replace').splitlines()
                for line in lines:
                    if not line.startswith('PODOFO_MLSR_PID='):
                        continue
                    pid = int(line.split('=', 1)[1])
                    process = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='],
                                             capture_output=True, text=True)
                    if process.returncode == 0 and Path(process.stdout.strip()).resolve() == (relocated / 'Contents/MacOS/PoDoFo').resolve():
                        os.kill(pid, signal.SIGTERM)
                raise
            report['process_seconds'] = time.monotonic() - started
        log = (output / 'runtime.log').read_text(errors='replace')
        receipts = [line.split('PODOFO_MLSR_REPORT=', 1)[1]
                    for line in log.splitlines() if 'PODOFO_MLSR_REPORT=' in line]
        if not receipts:
            raise RuntimeError(f'No runtime report; process exit {result.returncode}')
        receipt = json.loads(receipts[-1])
        report['runtime'] = receipt
        write_report(output / 'runtime-report.json', receipt)
        # macOS may deny the host process access to another app's container.
        # The probe exports its own fixed evidence set over its stdout pipe.
        exported = set()
        for line in log.splitlines():
            if 'PODOFO_MLSR_ARTIFACT=' not in line:
                continue
            artifact = json.loads(line.split('PODOFO_MLSR_ARTIFACT=', 1)[1])
            name = artifact['name']
            if name not in ARTIFACTS:
                raise ValueError(f'Unexpected probe artifact: {name}')
            payload = base64.b64decode(artifact['base64'], validate=True)
            if hashlib.sha256(payload).hexdigest() != artifact['sha256']:
                raise ValueError(f'Probe artifact digest differs: {name}')
            (output / name).write_bytes(payload)
            exported.add(name)
        if receipt.get('passed') is True and exported != ARTIFACTS:
            raise RuntimeError(f'Missing probe artifacts: {ARTIFACTS - exported}')
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
    parser.add_argument('--stress-seconds', type=int, default=0,
                        help='Minimum warm reuse duration, mixing completed and cancelled playback')
    parser.add_argument('--developer-model-manifest', type=Path,
                        default=Path.home() / '.cache/mlsr/models/supertonic3-coreml-fp16-t384-voices-v1/mlsr-bundle.yaml',
                        help='Existing local model manifest used only to verify sandbox denial')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('Run this qualification on macOS Apple Silicon')
    if not 0 <= args.stress_seconds <= 3600:
        parser.error('--stress-seconds must be between 0 and 3600')
    output = args.output or APP / 'build/mlsr-qualification' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    qualify(output, args.developer_model_manifest, args.stress_seconds)


if __name__ == '__main__':
    main()
