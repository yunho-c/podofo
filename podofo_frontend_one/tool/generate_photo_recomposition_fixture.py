#!/usr/bin/env python3
"""White-backdrop proofs and curved alpha for dark-mode recomposition."""
import json
import math
import zlib
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1] / 'test/fixtures/photo_dark_mode'

def build():
    objects = []
    def obj(value):
        objects.append(value.encode('ascii') if isinstance(value, str) else value)
        return len(objects)
    def stream(data, entries=''):
        data = zlib.compress(data, 9)
        return obj(f'<< {entries} /Length {len(data)} /Filter /FlateDecode >>\nstream\n'.encode() + data + b'\nendstream')
    catalog, pages = obj(''), obj('')
    font = obj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    alpha = bytes(round(255 * max(0, min(1, (102 - math.hypot(x + .5 - 128, y + .5 - 128)) / 8)))
                  for y in range(256) for x in range(256))
    mask = stream(alpha, '/Type /XObject /Subtype /Image /Width 256 /Height 256 /ColorSpace /DeviceGray /BitsPerComponent 8')
    image_attrs = f'/Type /XObject /Subtype /Image /Width 256 /Height 256 /ColorSpace /DeviceRGB /BitsPerComponent 8 /SMask {mask} 0 R'
    photo = stream(Image.open(ROOT / 'astronaut.png').convert('RGB').tobytes(), image_attrs)
    red = stream(bytes([255, 0, 0]) * (256 * 256), image_attrs)
    res = f'<< /XObject << /Photo {photo} 0 R /Red {red} 0 R >> /Font << /F1 {font} 0 R >> >>'
    form = stream(b'q 256 0 0 256 0 0 cm /Photo Do Q', f'/Type /XObject /Subtype /Form /BBox [0 0 256 256] /Resources {res}')
    appearance = stream(b'0 0 1 rg 0 0 60 60 re f', '/Type /XObject /Subtype /Form /BBox [0 0 60 60]')
    kids, manifest = [], []
    def page(name, before='', image='Photo', after='', expected=None, annotation=None, rotation=0, content=None):
        if content is None:
            content = before + f' q 256 0 0 256 72 72 cm /{image} Do Q ' + after
        contents = stream(content.encode())
        resources = res if '/Form' not in content else f'<< /XObject << /Form {form} 0 R >> >>'
        annots = ''
        if annotation:
            annot = obj(f'<< /Type /Annot /Subtype /Square /Rect [{annotation}] /AP << /N {appearance} 0 R >> >>')
            annots = f'/Annots [{annot} 0 R]'
        p = obj(f'<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 400 400] /Rotate {rotation} /Resources {resources} /Contents {contents} 0 R {annots} >>')
        kids.append(f'{p} 0 R')
        manifest.append(dict(page=len(kids), name=name, blocker=expected))
    page('plain-white-page')
    page('opaque-white-fill', '1 1 1 rg 40 40 320 320 re f', expected='background-not-proven-white')
    page('gray-background', '.8 .8 .8 rg 0 0 400 400 re f', expected='background-not-proven-white')
    page('earlier-graphic', '0 0 1 rg 150 150 60 60 re f', expected='background-not-proven-white')
    page('white-fill-covers-earlier-graphic', '0 0 1 rg 150 150 60 60 re f 1 1 1 rg 40 40 320 320 re f', expected='background-not-proven-white')
    page('partial-white-does-not-clear-graphic', '0 0 1 rg 150 150 60 60 re f 1 1 1 rg 72 72 100 100 re f', expected='background-not-proven-white')
    page('annotation-overlap', annotation='170 170 230 230', expected='annotation-overlap')
    page('annotation-away', annotation='5 5 40 40')
    page('red-silhouette-manual-target', image='Red')
    page('nested-reflected-crop', content='q -1 0 0 1 328 72 cm 32 0 224 256 re W n /Form Do Q')
    for rotation in [90, 180, 270]:
        page(f'page-rotation-{rotation}', rotation=rotation)
    page('later-label', after='BT /F1 18 Tf 150 150 Td (Label) Tj ET')
    objects[catalog-1] = f'<< /Type /Catalog /Pages {pages} 0 R >>'.encode()
    objects[pages-1] = f'<< /Type /Pages /Kids [{" ".join(kids)}] /Count {len(kids)} >>'.encode()
    out = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n'); offsets = [0]
    for i, value in enumerate(objects, 1):
        offsets.append(len(out)); out.extend(f'{i} 0 obj\n'.encode()+value+b'\nendobj\n')
    xref = len(out); out.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]: out.extend(f'{offset:010d} 00000 n \n'.encode())
    out.extend(f'trailer\n<< /Size {len(offsets)} /Root {catalog} 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    (ROOT/'recomposition.pdf').write_bytes(out)
    (ROOT/'recomposition_manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')

if __name__ == '__main__': build()
