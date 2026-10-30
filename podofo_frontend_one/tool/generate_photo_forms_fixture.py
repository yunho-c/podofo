#!/usr/bin/env python3
"""Nested Form/clip/opacity regressions; requires Pillow, uses local NASA image."""
import hashlib
import json
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
        packed = zlib.compress(data, 9)
        return obj(f'<< {entries} /Length {len(packed)} /Filter /FlateDecode >>\nstream\n'.encode() + packed + b'\nendstream')

    catalog, pages = obj(''), obj('')
    font = obj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    im = Image.open(ROOT / 'astronaut.png').convert('RGB')
    image_entries = '/Type /XObject /Subtype /Image /Width 256 /Height 256 /ColorSpace /DeviceRGB /BitsPerComponent 8'
    photo = stream(im.tobytes(), image_entries)
    mask = stream(bytes(255 if x >= 128 else 0 for y in range(256) for x in range(256)), '/Type /XObject /Subtype /Image /Width 256 /Height 256 /ColorSpace /DeviceGray /BitsPerComponent 8')
    masked = stream(im.tobytes(), f'{image_entries} /SMask {mask} 0 R')
    hard_mask = stream(bytes([255]*16+[0]*16)*256, '/Type /XObject /Subtype /Image /Width 256 /Height 256 /ImageMask true /BitsPerComponent 1')
    hard_masked = stream(im.tobytes(), f'{image_entries} /Mask {hard_mask} 0 R')
    color_key = stream(im.tobytes(), f'{image_entries} /Mask [0 30 0 30 0 30]')
    alpha = obj('<< /Type /ExtGState /ca 0.5 /CA 0.5 >>')

    def resources(extra=''):
        return f'<< /Font << /F1 {font} 0 R >> /XObject << /Photo {photo} 0 R /Soft {masked} 0 R /Hard {hard_masked} 0 R /Key {color_key} 0 R {extra} >> /ExtGState << /Alpha {alpha} 0 R >> >>'

    def form(content, bbox='0 0 200 200', extra='', matrix='1 0 0 1 0 0', group=''):
        return stream(content.encode(), f'/Type /XObject /Subtype /Form /BBox [{bbox}] /Matrix [{matrix}] /Resources {resources(extra)} {group}')

    kids, specs = [], []

    def page(name, content, extra='', expect=1, reason=None, regions=None, paths=None):
        content_id = stream(content.encode())
        page_id = obj(f'<< /Type /Page /Parent {pages} 0 R /MediaBox [10 20 450 520] /CropBox [30 40 430 500] /Resources {resources(extra)} /Contents {content_id} 0 R >>')
        kids.append(f'{page_id} 0 R')
        specs.append(dict(page=len(kids), name=name, expectedPhotos=expect, reason=reason, regions=regions, paths=paths))

    photo_command = 'q 160 0 0 160 20 20 cm /Photo Do Q'
    inner = form(photo_command)
    middle = form('/Inner Do', extra=f'/Inner {inner} 0 R', matrix='0 1 -1 0 200 0')
    outer = form('/Middle Do', extra=f'/Middle {middle} 0 R', matrix='-1 0 0 1 200 0')
    page('nested-reflection-quarter-turn', 'q 1 0 0 1 50 100 cm /Outer Do Q', f'/Outer {outer} 0 R', regions=[[40,80,200,240]], paths=['0/0/0/0'])
    page('reused-form-placements', 'q 1 0 0 1 40 60 cm /Inner Do Q q 1 0 0 1 230 280 cm /Inner Do Q', f'/Inner {inner} 0 R', expect=2, regions=[[30,40,190,200],[220,260,380,420]], paths=['0/0','1/0'])
    page('image-rectangular-crop', 'q 160 0 0 160 60 120 cm 0 0 .5 1 re W n /Photo Do Q', regions=[[30,80,110,240]])
    page('ancestor-rectangular-crop', 'q 1 0 0 1 50 100 cm 20 20 80 160 re W n /Inner Do Q', f'/Inner {inner} 0 R', regions=[[40,80,120,240]])
    bbox = form(photo_command, bbox='20 20 100 180')
    page('form-bbox-crop', 'q 1 0 0 1 50 100 cm /Box Do Q', f'/Box {bbox} 0 R', regions=[[40,80,120,240]])
    page('opaque-photo-covers-underlay', '0 0 0 rg 30 40 400 460 re f q 1 0 0 1 50 100 cm /Inner Do Q', f'/Inner {inner} 0 R')
    page('later-text-blocks-photo', 'q 1 0 0 1 50 100 cm /Inner Do Q BT /F1 18 Tf 100 180 Td (Overlay) Tj ET', f'/Inner {inner} 0 R', expect=0, reason='overlapping-page-content')
    page('triangle-clip', 'q 60 120 m 220 120 l 60 280 l h W n 160 0 0 160 60 120 cm /Photo Do Q', expect=0, reason='complex-clip')
    page('compound-rectangular-clip', 'q 60 120 160 160 re 100 160 80 80 re W* n 160 0 0 160 60 120 cm /Photo Do Q', expect=0, reason='complex-clip')
    page('text-and-rectangular-clip', 'q BT /F1 130 Tf 7 Tr 60 140 Td (A) Tj ET 60 120 160 160 re W n 160 0 0 160 60 120 cm /Photo Do Q', expect=0, reason='text-clip')
    for name in ['Soft', 'Hard', 'Key']:
        leaf = form(f'q 160 0 0 160 20 20 cm /{name} Do Q')
        page(f'{name.lower()}-image-mask', 'q 1 0 0 1 50 100 cm /Leaf Do Q', f'/Leaf {leaf} 0 R', expect=0, reason='mask-or-transparency')
    page('form-alpha', 'q /Alpha gs 1 0 0 1 50 100 cm /Inner Do Q', f'/Inner {inner} 0 R', expect=0, reason='form-transparency')
    group = form(photo_command, group='/Group << /S /Transparency /I true >>')
    page('form-transparency-group', 'q 1 0 0 1 50 100 cm /Group Do Q', f'/Group {group} 0 R', expect=0, reason='form-transparency')
    page('skewed-parent', 'q 1 .2 0 1 50 100 cm /Inner Do Q', f'/Inner {inner} 0 R', expect=0, reason='non-rectangular-transform')
    deep = inner
    for i in range(18):
        deep = form('/Child Do', extra=f'/Child {deep} 0 R')
    page('depth-budget', 'q 1 0 0 1 50 100 cm /Deep Do Q', f'/Deep {deep} 0 R', expect=0, reason='form-depth-budget')
    dense = form('\n'.join(f'q 5 0 0 5 {i*7} 100 cm /Photo Do Q' for i in range(25)))
    page('nested-tiny-images', 'q 1 0 0 1 50 100 cm /Dense Do Q', f'/Dense {dense} 0 R', expect=0, reason='small-or-outside-page')
    huge = form('q 3000 0 0 3000 0 0 cm /Photo Do Q', bbox='0 0 3000 3000')
    page('local-render-allocation-budget', 'q .05 0 0 .05 60 120 cm /Huge Do Q', f'/Huge {huge} 0 R', expect=0, reason='rendered-image-budget')
    page('fractional-placement', 'q 161.24 0 0 160.42 60.31 120.63 cm /Photo Do Q')
    page('clip-excludes-later-label', 'q 160 0 0 160 60 120 cm 0 0 .5 1 re W n /Photo Do Q BT /F1 14 Tf 150 180 Td (Outside crop) Tj ET')
    # Filled borders exported by illustration tools use holes in a polygon.
    framed = 'q 160 0 0 160 60 120 cm /Photo Do Q 1 0 0 rg '
    page('even-odd-frame', framed+'58 118 164 164 re 60 120 160 160 re f*', regions=[[31,81,189,239]])
    page('winding-frame', framed+'58 118 164 164 re 60 120 m 60 280 l 220 280 l 220 120 l h f', regions=[[31,81,189,239]])
    page('solid-winding-is-not-a-frame', framed+'58 118 164 164 re 60 120 160 160 re f', expect=0, reason='overlapping-page-content')
    page('path-enters-photo', framed+'58 118 164 164 re 80 140 120 120 re f*', expect=0, reason='overlapping-page-content')
    page('stroke-stays-conservative', framed+'2 w 58 118 164 164 re S', expect=0, reason='overlapping-page-content')
    objects[catalog-1] = f'<< /Type /Catalog /Pages {pages} 0 R >>'.encode()
    objects[pages-1] = f'<< /Type /Pages /Kids [{" ".join(kids)}] /Count {len(kids)} >>'.encode()
    data = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')
    offsets = []
    for i, value in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(f'{i} 0 obj\n'.encode()+value+b'\nendobj\n')
    xref = len(data)
    data.extend(f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode())
    for offset in offsets:
        data.extend(f'{offset:010d} 00000 n \n'.encode())
    data.extend(f'trailer\n<< /Root 1 0 R /Size {len(objects)+1} >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    (ROOT/'forms.pdf').write_bytes(data)
    (ROOT/'forms_manifest.json').write_text(json.dumps({'sha256':hashlib.sha256(data).hexdigest(),'pages':specs}, indent=2)+'\n')
    print(hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    build()
