#!/usr/bin/env python3
"""Check the release bundle against prepared MLSR assets, architecture and signing."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def audit(bundle, app):
    bundle = bundle.resolve(strict=True)
    prepared = app / '.mlsr/model_assets'
    resources = bundle / 'Contents/Frameworks/App.framework/Resources/flutter_assets/packages/mlsr_app_models'
    expected = {p.relative_to(prepared).as_posix(): p
                for directory in ['models', 'notices'] for p in (prepared / directory).rglob('*') if p.is_file()}
    expected.update({name: prepared / name for name in ['LICENSE', 'catalog.yaml', 'package-index.yaml']})
    actual = {p.relative_to(resources).as_posix(): p for p in resources.rglob('*') if p.is_file()}
    if set(actual) != set(expected):
        raise ValueError(f'Asset inventory differs: missing={set(expected) - set(actual)}, extra={set(actual) - set(expected)}')
    files = []
    for name, source in sorted(expected.items()):
        target = actual[name]
        if source.is_symlink() or target.is_symlink() or digest(source) != digest(target):
            raise ValueError(f'Asset differs or is a symlink: {name}')
        files.append({'path': name, 'bytes': target.stat().st_size, 'sha256': digest(target)})
    command('codesign', '--verify', '--deep', '--strict', str(bundle))
    entitlements = plistlib.loads(subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(bundle)]))
    if not entitlements.get('com.apple.security.app-sandbox'):
        raise ValueError('Release app must be sandboxed')
    library = bundle / 'Contents/Frameworks/mlsr_ffi.framework/mlsr_ffi'
    architecture = command('lipo', '-archs', str(library))
    if architecture != 'arm64':
        raise ValueError(f'Unexpected MLSR architecture: {architecture}')
    linkage = command('otool', '-L', str(library))
    for line in linkage.splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        if not dependency.startswith(('@rpath/', '@loader_path/', '@executable_path/', '/System/', '/usr/lib/')):
            raise ValueError(f'Nonportable native linkage: {dependency}')
    return {'passed': True, 'bundle': str(bundle), 'asset_files': len(files),
            'asset_bytes': sum(f['bytes'] for f in files), 'files': files,
            'architecture': architecture, 'linkage': linkage, 'native_sha256': digest(library),
            'entitlements': entitlements,
            'provenance': json.loads((app / '.mlsr/native/provenance.json').read_text())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.bundle, Path(__file__).resolve().parents[1])
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(f"Verified {report['asset_files']} assets ({report['asset_bytes']} bytes), arm64 native linkage and sandboxed signing")


if __name__ == '__main__':
    main()
