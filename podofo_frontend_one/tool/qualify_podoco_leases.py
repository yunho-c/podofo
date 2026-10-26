#!/usr/bin/env python3
"""Qualify native renderer ownership with a PDF made from one pinned M6 raster."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlparse
import zlib

APP = Path(__file__).resolve().parents[1]
REPO = APP.parent


def sha(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def raster_pdf(pages, output):
    """Lossless image XObject; native PDFium must render this before Podoco use."""
    row = json.loads(pages.read_text())['pages'][0]
    image = row['image']
    w, h = image['width'], image['height']
    assert image['format'] == 'rgba8' and image['row_stride'] == w * 4
    ref = row['pixels']
    pixels = Path(unquote(urlparse(ref).path)) if ref.startswith('file:') else pages.parent / ref
    raw = pixels.read_bytes()
    assert len(raw) == w * h * 4 and all(v == 255 for v in raw[3::4])
    rgb = bytearray(w * h * 3)
    for c in range(3):
        rgb[c::3] = raw[c::4]
    compressed = zlib.compress(rgb)
    content = f'q {w/2} 0 0 {h/2} 0 0 cm /Im0 Do Q\n'.encode()
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w/2} {h/2}] /Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>'.encode(),
               f'<< /Length {len(content)} >>\nstream\n'.encode() + content + b'endstream',
               f'<< /Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Interpolate false /Filter /FlateDecode /Length {len(compressed)} >>\nstream\n'.encode() + compressed + b'\nendstream']
    data = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for i, obj in enumerate(objects, 1):
        offsets.append(len(data))
        data += f'{i} 0 obj\n'.encode() + obj + b'\nendobj\n'
    start = len(data)
    data += f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
    for offset in offsets[1:]:
        data += f'{offset:010d} 00000 n \n'.encode()
    data += f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n'.encode()
    output.write_bytes(data)
    return {'source_pixels_sha256': sha(pixels), 'pdf_sha256': sha(output), 'width': w, 'height': h}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['layout', 'formula', 'pages', 'output', 'flutter-sdk']:
        p.add_argument('--' + name, type=lambda v: Path(v).resolve(), required=True)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    fixture = a.output / 'recognized-page.pdf'
    fixture_info = raster_pdf(a.pages, fixture)
    env = dict(os.environ, PODOCO_M2_BUNDLE=str(a.layout), PODOCO_M6_BUNDLE=str(a.formula),
               PODOCO_M8_PDF=str(fixture), PODOCO_M8_EVIDENCE=str(a.output / 'handoff.json'), CARGO_INCREMENTAL='0')
    def run(name, cmd):
        with (a.output / (name + '.log')).open('w') as log:
            subprocess.run([str(v) for v in cmd], cwd=APP, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    run('prepare', ['python3.13', 'tool/prepare_podoco.py'])
    run('analyze', [a.flutter_sdk / 'bin/flutter', 'analyze', '--no-pub'])
    files = [*sorted((APP / 'lib/src/analysis').glob('*.dart')),
             *sorted((APP / 'third_party/pdfrx_engine').rglob('*.dart')),
             APP / 'test/analysis_leases_test.dart', APP / 'pubspec.lock', Path(__file__)]
    hashes = {str(p.relative_to(REPO)): sha(p) for p in files}
    native = APP / '.podoco/native/podoco_ffi'
    native_hash = sha(native)
    run('tests', ['python3.13', 'tool/test_macos.py', '--flutter-sdk', a.flutter_sdk, 'test/analysis_leases_test.dart'])
    log = (a.output / 'tests.log').read_text()
    passed = re.findall(r'\+(\d+): All tests passed!', log)
    failures = []
    if not passed or int(passed[-1]) != 8 or 'Skip:' in log:
        failures.append('lease qualification skipped or incomplete')
    for path, digest in hashes.items():
        if sha(REPO / path) != digest:
            failures.append('source drift: ' + path)
    if sha(native) != native_hash:
        failures.append('native binary drift')
    report = dict(fixture=fixture_info, tests=int(passed[-1]) if passed else 0,
                  handoff=json.loads((a.output / 'handoff.json').read_text()),
                  benchmark=json.loads((a.output / 'handoff.json.benchmark.json').read_text()),
                  manifests={str(p):sha(p / 'podoco-bundle.yaml') for p in [a.layout, a.formula]},
                  sources=hashes, native_sha256=native_hash, failures=failures,
                  flutter=json.loads(subprocess.check_output([str(a.flutter_sdk / 'bin/flutter'), '--version', '--machine'], text=True)))
    (a.output / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['sources','handoff']},indent=2))
    if failures:
        raise RuntimeError(failures)


if __name__ == '__main__':
    main()
