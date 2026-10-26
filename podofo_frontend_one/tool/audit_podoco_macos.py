#!/usr/bin/env python3
"""Verify shipped Podoco assets, pinned identities, native linkage and signing."""
import argparse
import json
from pathlib import Path

from audit_mlsr_macos import command, digest
import plistlib
import subprocess


def audit(bundle, app):
    bundle = bundle.resolve(strict=True)
    prepared = app / '.podoco/model_assets'
    index = json.loads((prepared / 'package-index.json').read_text())
    if index['platform'] != 'macos-arm64' or index['available'] is not True:
        raise ValueError('Release needs a prepared macos-arm64 analysis pack')
    resources = bundle / ('Contents/Frameworks/App.framework/Resources/'
                          'flutter_assets/packages/' + index['package'])
    if resources.is_symlink() or not resources.resolve(strict=True).is_relative_to(bundle):
        raise ValueError('Model resources must be an internal application directory')
    # These are precisely the assets enumerated by the generator's pubspec.
    expected = {name: item for name, item in index['files'].items()
                if name.startswith('models/') or name in ('LICENSE', 'MODEL_NOTICES.md')}
    actual = {}
    for path in resources.rglob('*'):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError(f'Non-regular bundled asset: {path}')
        if path.is_file():
            actual[path.relative_to(resources).as_posix()] = path
    if set(actual) != set(expected):
        raise ValueError(f'Asset inventory differs: missing={set(expected) - set(actual)}, extra={set(actual) - set(expected)}')
    for name, item in expected.items():
        target = actual[name]
        if target.stat().st_size != item['size_bytes'] or digest(target) != item['sha256']:
            raise ValueError(f'Bundled asset differs: {name}')
        if digest(prepared / name) != item['sha256']:
            raise ValueError(f'Prepared asset changed: {name}')
    command('codesign', '--verify', '--deep', '--strict', str(bundle))
    entitlements = plistlib.loads(subprocess.check_output(
        ['codesign', '-d', '--entitlements', ':-', str(bundle)]))
    if not entitlements.get('com.apple.security.app-sandbox'):
        raise ValueError('Release must be sandboxed')
    library = bundle / 'Contents/Frameworks/podoco_ffi.framework/podoco_ffi'
    architecture = command('lipo', '-archs', str(library))
    if architecture != 'arm64':
        raise ValueError(f'Unexpected architecture: {architecture}')
    linkage = command('otool', '-L', str(library))
    for line in linkage.splitlines()[1:]:
        dependency = line.strip().split(' (', 1)[0]
        if not dependency.startswith(('@rpath/', '@loader_path/', '@executable_path/', '/System/', '/usr/lib/')):
            raise ValueError(f'Nonportable native dependency: {dependency}')
    return {'passed': True, 'bundle': str(bundle), 'pack': index['pack_id'],
            'catalog_sha256': expected['models/pack.json']['sha256'],
            'components': json.loads(actual['models/pack.json'].read_text()),
            'asset_files': len(expected),
            'asset_bytes': sum(item['size_bytes'] for item in expected.values()),
            'architecture': architecture, 'linkage': linkage,
            'native_sha256': digest(library), 'entitlements': entitlements,
            'provenance': json.loads((app / '.podoco/native/provenance.json').read_text())}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('bundle', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.bundle, Path(__file__).resolve().parents[1])
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(f"Verified {report['asset_files']} Podoco assets ({report['asset_bytes']} bytes), arm64 linkage and sandboxed signing")


if __name__ == '__main__':
    main()
