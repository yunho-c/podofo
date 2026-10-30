#!/usr/bin/env python3
"""Deterministic mixed PDF, using the committed NASA photo; no network access.
Requires Pillow. Writes a tiny, auditable PDF object graph (no PDF authoring SDK).
"""
from pathlib import Path
import hashlib
import json
import zlib
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1] / 'test/fixtures/photo_dark_mode'


def build():
    objects = []

    def obj(value):
        objects.append(value.encode('ascii') if isinstance(value, str) else value)
        return len(objects)

    def stream(data, entries=''):
        packed = zlib.compress(data, 9)
        return obj(f'<< {entries} /Length {len(packed)} /Filter /FlateDecode >>\nstream\n'.encode() + packed + b'\nendstream')

    def image(im, extra=''):
        return stream(im.convert('RGB').tobytes(), f'/Type /XObject /Subtype /Image /Width {im.width} /Height {im.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 {extra}')

    catalog, pages = obj(''), obj('')
    font = obj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    photo_im = Image.open(ROOT / 'astronaut.png').convert('RGB')
    photo = image(photo_im)
    plot_im = Image.new('RGB', (256, 256), 'white')
    d = ImageDraw.Draw(plot_im)
    d.line([(20, 12), (20, 230), (245, 230)], fill='black', width=3)
    for i in range(5):
        d.line([(20, 30 + i*40), (240, 30 + i*40)], fill='#dddddd', width=1)
    d.line([(20+i, int(210 - i*.7 + 12*((i//15)%2))) for i in range(215)], fill='#2255bb', width=3)
    d.text((70, 10), 'Measured result', fill='black')
    plot = image(plot_im)
    screen_im = Image.new('RGB', (256,256), '#eeeeee')
    d = ImageDraw.Draw(screen_im)
    d.rectangle((0,0,255,28), fill='#303030')
    for i in range(8):
        d.text((10, 36+25*i), f'Parameter {i}: 0.125', fill='#111111')
    screenshot = image(screen_im)
    gradient_im = Image.new('RGB', (256,256))
    gradient_im.putdata([(x,y,128) for y in range(256) for x in range(256)])
    gradient = image(gradient_im)
    gray = image(photo_im.convert('L').convert('RGB'))
    alpha = obj('<< /Type /ExtGState /ca 0.5 /CA 0.5 >>')
    form = stream(b'q 120 0 0 120 0 0 cm /Photo Do Q', f'/Type /XObject /Subtype /Form /BBox [0 0 120 120] /Resources << /XObject << /Photo {photo} 0 R >> >>')
    resources = f'<< /Font << /F1 {font} 0 R >> /XObject << /Photo {photo} 0 R /Plot {plot} 0 R /Screen {screenshot} 0 R /Gradient {gradient} 0 R /Gray {gray} 0 R /Form {form} 0 R >> /ExtGState << /Alpha {alpha} 0 R >> >>'
    kids = []
    specs = []

    def page(content, crop=(30,40,330,440), rotation=0, name='mixed', expect=1, annotations=''):
        content_id = stream(content.encode('ascii'))
        page_id = obj(f'<< /Type /Page /Parent {pages} 0 R /MediaBox [10 20 350 460] /CropBox [{" ".join(map(str,crop))}] /Rotate {rotation} /Resources {resources} /Contents {content_id} 0 R {annotations} >>')
        kids.append(f'{page_id} 0 R')
        specs.append({'page':len(kids),'name':name,'rotation':rotation,'crop':crop,'expectedPhotos':expect})

    text = 'BT /F1 12 Tf 50 420 Td (Photo, raster plot and vector diagram) Tj ET\n'
    photo_command = 'q 160 0 0 160 50 240 cm /Photo Do Q\n'
    mixed = text + photo_command + 'q 90 0 0 90 225 290 cm /Plot Do Q\n0 0 0 RG 50 100 120 70 re S 50 100 m 170 170 l S\nBT /F1 12 Tf 50 80 Td (Vector diagram - text remains inverted) Tj ET\n'
    for rotation in [0,90,180,270]:
        page(mixed, rotation=rotation)
    page(photo_command, crop=(100,260,280,430), name='partly-cropped-photo')
    page('q 300 0 0 400 30 40 cm /Photo Do Q', name='full-page-scan', expect=0)
    page(photo_command+'BT /F1 18 Tf 70 300 Td (Overlay label) Tj ET', name='text-over-photo',expect=0)
    page('q 140 0 0 140 40 240 cm 0 0 .5 .5 re W n /Photo Do Q\nq /Alpha gs 100 0 0 100 220 280 cm /Photo Do Q\nq 1 0 0 1 40 60 cm /Form Do Q\nq 70 25 -25 70 240 80 cm /Photo Do Q',name='clip-alpha-form-skew',expect=2)
    page('q 120 0 0 120 40 280 cm /Gradient Do Q\nq 120 0 0 120 190 280 cm /Screen Do Q\nq 120 0 0 120 40 100 cm /Plot Do Q',name='ambiguous-rasters',expect=0)
    page('q 160 0 0 160 50 240 cm /Gray Do Q',name='grayscale-photo-ambiguous',expect=0)
    annotation = obj('<< /Type /Annot /Subtype /Highlight /Rect [65 300 180 320] /QuadPoints [65 320 180 320 65 300 180 300] /C [1 1 0] /CA 0.5 /F 4 >>')
    page(mixed, name='highlight-on-photo', annotations=f'/Annots [{annotation} 0 R]')
    # Raster repeated over many top-level objects exercises admission budgets.
    page('\n'.join(f'q 5 0 0 5 {40+i*7} 200 cm /Photo Do Q' for i in range(25)), name='many-tiny-images',expect=0)
    objects[catalog-1] = f'<< /Type /Catalog /Pages {pages} 0 R >>'.encode()
    objects[pages-1] = f'<< /Type /Pages /Kids [{" ".join(kids)}] /Count {len(kids)} >>'.encode()
    data = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')
    offsets = []
    for i, value in enumerate(objects,1):
        offsets.append(len(data))
        data.extend(f'{i} 0 obj\n'.encode()+value+b'\nendobj\n')
    xref = len(data)
    data.extend(f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode())
    for offset in offsets:
        data.extend(f'{offset:010d} 00000 n \n'.encode())
    data.extend(f'trailer\n<< /Root 1 0 R /Size {len(objects)+1} >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    (ROOT/'mixed.pdf').write_bytes(data)
    (ROOT/'manifest.json').write_text(json.dumps({'sha256':hashlib.sha256(data).hexdigest(),'pages':specs}, indent=2)+'\n')
    for name, im in [('photo',photo_im),('plot',plot_im),('screenshot',screen_im),('gradient',gradient_im),('gray',photo_im.convert('L').convert('RGB'))]:
        # Match production center sampling exactly; these samples also allow a
        # classifier-only test without a PDF decoder or network dependency.
        sampled = bytes(v for y in range(64) for x in range(64) for v in im.getpixel((int((x+.5)*im.width/64),int((y+.5)*im.height/64))))
        (ROOT/f'{name}.rgb').write_bytes(sampled)
    print(hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    build()
