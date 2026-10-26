#!/usr/bin/env python3
"""Exercise bundled analysis in a relocated, fresh, offline sandbox (muted audio)."""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import socket
import subprocess
import time

from audit_podoco_macos import audit

APP = Path(__file__).resolve().parents[1]
PDF_SHA256 = 'e3bda3bdd501a74c26aad5fbf99595c419f5688843d716df8dd420115be8cab2'


def write(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def run(log, command, **kwargs):
    print(f'{log.name}: {command[0]}', flush=True)
    with log.open('wb') as stream:
        return subprocess.run(command, cwd=APP, stdout=stream, stderr=subprocess.STDOUT, **kwargs)


def source_receipt():
    root = APP.parent
    scopes = ['podoco/crates', 'podoco/bindings', 'podoco/Cargo.lock',
              'podofo_frontend_one/lib', 'podofo_frontend_one/tool',
              'podofo_frontend_one/macos', 'podofo_frontend_one/pubspec.yaml',
              'podofo_frontend_one/pubspec.lock', 'podofo_frontend_one/podoco-models.yaml']
    names = subprocess.check_output(['git', 'ls-files', '--cached', '--others',
                                     '--exclude-standard', '-z', '--', *scopes], cwd=root).decode().split('\0')
    return {'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
            'status': subprocess.check_output(['git', 'status', '--short'], cwd=root, text=True),
            'sha256': {name: hashlib.sha256((root / name).read_bytes()).hexdigest()
                       for name in sorted(set(names)) if name and (root / name).is_file()}}


def qualify(output, pdf):
    payload = pdf.read_bytes()
    if hashlib.sha256(payload).hexdigest() != PDF_SHA256:
        raise ValueError('Use the pinned M8 recognized-page.pdf fixture')
    output.mkdir(parents=True, exist_ok=False)
    products = output / 'products'
    normal = products / 'Release/PoDoFo.app'
    relocated = output / 'Relocated/PoDoFo Probe.app'
    relocated.parent.mkdir()
    entry = output / 'entry.dart'
    entry.write_text("import 'dart:convert';\n"
                     f"import '{(APP / 'tool/podoco_release_probe.dart').as_uri()}';\n"
                     f"Future<void> main() => runProbe(base64Decode('{base64.b64encode(payload).decode()}'));\n")
    report = {'passed': False, 'source': source_receipt(),
              'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
              'pdf_sha256': PDF_SHA256, 'relocated_bundle': str(relocated)}
    env = dict(os.environ, PODOFO_BUILD_PRODUCTS=str(products))
    try:
        run(output / 'probe-build.log', ['bash', 'tool/build_macos_local.sh', 'release',
                                         '--target', str(entry)], env=env, check=True)
        subprocess.run(['cp', '-cR', str(normal), str(relocated)], check=True)
        # A unique identifier gets a fresh container, without touching user data
        # or the running ordinary PoDoFo application. Remove both network rights.
        info = relocated / 'Contents/Info.plist'
        metadata = plistlib.loads(info.read_bytes())
        metadata['CFBundleIdentifier'] += '.podocoqualification.' + str(time.time_ns())
        info.write_bytes(plistlib.dumps(metadata))
        entitlements = plistlib.loads((APP / 'macos/Runner/Release.entitlements').read_bytes())
        for name in ['com.apple.security.network.client', 'com.apple.security.network.server']:
            entitlements.pop(name, None)
        entitlement_file = output / 'offline.entitlements'
        entitlement_file.write_bytes(plistlib.dumps(entitlements))
        subprocess.run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlement_file), str(relocated)], check=True)
        write(output / 'probe-assets-audit.json', audit(relocated, APP))
        sources = APP.parent / 'podoco/model-assets'
        forbidden = [sources / 'pp-doclayout-v3-m2-sandbox/podoco-bundle.yaml',
                     sources / 'pp-formulanet-plus-l-m6/podoco-bundle.yaml',
                     sources / 'mathcat-0.7.7-m7/podoco-rules.yaml',
                     APP / '.podoco/native/podoco_ffi']
        if not all(path.is_file() for path in forbidden):
            raise ValueError('Denial probes require existing developer inputs')
        runtime_log = output / 'runtime.log'
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            command = ['/usr/bin/open', '-n', '-W', str(relocated),
                       '--stdout', str(runtime_log), '--stderr', str(runtime_log),
                       '--env', f'PODOCO_FORBIDDEN_FILES={json.dumps(list(map(str, forbidden)))}',
                       '--env', f'PODOCO_DENIED_NETWORK_PORT={listener.getsockname()[1]}']
            try:
                run(output / 'launcher.log', command, check=True, timeout=600)
            except subprocess.TimeoutExpired:
                for line in runtime_log.read_text(errors='replace').splitlines():
                    if not line.startswith('PODOCO_PROBE_PID='):
                        continue
                    pid = int(line.split('=', 1)[1])
                    process = subprocess.run(['ps', '-p', str(pid), '-o', 'comm='], capture_output=True, text=True)
                    if process.returncode == 0 and Path(process.stdout.strip()).resolve() == (relocated / 'Contents/MacOS/PoDoFo').resolve():
                        os.kill(pid, signal.SIGTERM)
                raise
        receipts = [line.split('PODOCO_PROBE_REPORT=', 1)[1]
                    for line in runtime_log.read_text(errors='replace').splitlines()
                    if 'PODOCO_PROBE_REPORT=' in line]
        if not receipts:
            raise RuntimeError('Probe returned no runtime receipt')
        report['runtime'] = json.loads(receipts[-1])
        write(output / 'runtime-report.json', report['runtime'])
        if report['runtime'].get('passed') is not True:
            raise RuntimeError(f"Probe failed: {report['runtime'].get('error')}")
        report['passed'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        # Leave a normal reader build next to the evidence, never a probe at a
        # user-facing app path. The original running app remains untouched.
        try:
            run(output / 'normal-build.log', ['bash', 'tool/build_macos_local.sh', 'release'], env=env, check=True)
            write(output / 'normal-assets-audit.json', audit(normal, APP))
            report['normal_bundle'] = str(normal)
        except Exception as error:
            report['passed'] = False
            report['normal_build_error'] = str(error)
            raise
        finally:
            write(output / 'qualification.json', report)
    print(f'Bundled analysis qualification passed. Playback was muted.\nApp: {normal}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--pdf', required=True, type=Path)
    args = parser.parse_args()
    qualify(args.output.resolve(), args.pdf.resolve(strict=True))


if __name__ == '__main__':
    main()
