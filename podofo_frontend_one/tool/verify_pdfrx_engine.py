#!/usr/bin/env python3
"""Verify the reviewed native renderer extension without network access."""
import hashlib
import json
from pathlib import Path

APP = Path(__file__).resolve().parents[1]


def verify():
    pin = json.loads((APP / 'third_party/pdfrx_engine-source.json').read_text())
    root = APP / 'third_party/pdfrx_engine'
    actual = {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in sorted(root.rglob('*')) if p.is_file()}
    if actual != pin['files']:
        raise RuntimeError('pdfrx_engine source differs from its exact reviewed pin')
    patch = APP / 'third_party' / pin['patch']
    if hashlib.sha256(patch.read_bytes()).hexdigest() != pin['patch_sha256']:
        raise RuntimeError('pdfrx_engine patch differs from its pin')
    print(f'Verified {len(actual)} renderer source/documentation files and the lease patch.')


if __name__ == '__main__':
    verify()
