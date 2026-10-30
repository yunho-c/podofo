#!/usr/bin/env python3
"""Dense, nested photo grids for scheduling and shader qualification (Pillow)."""
import hashlib
import json
import zlib
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1] / 'test/fixtures/photo_dark_mode'


def build():
    objects = []

    def obj(value):
        objects.append(value.encode() if isinstance(value, str) else value)
        return len(objects)

    def stream(data, entries=''):
        packed = zlib.compress(data, 9)
        return obj(f'<< {entries} /Length {len(packed)} /Filter /FlateDecode >>\nstream\n'.encode()+packed+b'\nendstream')

    catalog, pages = obj(''), obj('')
    font = obj('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>')
    im = Image.open(ROOT/'astronaut.png').convert('RGB').resize((512,512))
    photo = stream(im.tobytes(), '/Type /XObject /Subtype /Image /Width 512 /Height 512 /ColorSpace /DeviceRGB /BitsPerComponent 8')
    kids, specs = [], []
    for count, rotation in [(25,0), (92,0), (92,90)]:
        content = '\n'.join(f'q 32 0 0 32 {50+(i%8)*46} {80+(i//8)*34} cm /Photo Do Q' for i in range(count))
        form = stream(content.encode(), f'/Type /XObject /Subtype /Form /BBox [30 40 430 500] /Resources << /XObject << /Photo {photo} 0 R >> >>')
        commands = stream(f'BT /F1 12 Tf 50 60 Td ({count} panels - caption stays inverted) Tj ET /Grid Do'.encode())
        page = obj(f'<< /Type /Page /Parent {pages} 0 R /MediaBox [10 20 450 520] /CropBox [30 40 430 500] /Rotate {rotation} /Resources << /Font << /F1 {font} 0 R >> /XObject << /Grid {form} 0 R >> >> /Contents {commands} 0 R >>')
        kids.append(f'{page} 0 R')
        specs.append({'page':len(kids),'expectedPhotos':count,'rotation':rotation})
    objects[catalog-1] = f'<< /Type /Catalog /Pages {pages} 0 R >>'.encode()
    objects[pages-1] = f'<< /Type /Pages /Kids [{" ".join(kids)}] /Count {len(kids)} >>'.encode()
    data = bytearray(b'%PDF-1.7\n%\xe2\xe3\xcf\xd3\n')
    offsets = []
    for i,value in enumerate(objects,1):
        offsets.append(len(data));data.extend(f'{i} 0 obj\n'.encode()+value+b'\nendobj\n')
    xref = len(data)
    data.extend(f'xref\n0 {len(objects)+1}\n0000000000 65535 f \n'.encode())
    for offset in offsets: data.extend(f'{offset:010d} 00000 n \n'.encode())
    data.extend(f'trailer\n<< /Root 1 0 R /Size {len(objects)+1} >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    (ROOT/'dense.pdf').write_bytes(data)
    (ROOT/'dense_manifest.json').write_text(json.dumps({'sha256':hashlib.sha256(data).hexdigest(),'pages':specs},indent=2)+'\n')
    print(hashlib.sha256(data).hexdigest())


if __name__ == '__main__':
    build()
