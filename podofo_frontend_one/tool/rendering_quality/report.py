"""Produce a local, dependency-free report even when the capture job fails."""
import json
from pathlib import Path


def write_report(output):
    output = Path(output)
    data = {}
    for name in ['receipt', 'results']:
        path = output / f'{name}.json'
        try:
            data[name] = json.loads(path.read_text()) if path.exists() else {}
        except (ValueError, OSError) as error:
            data[name] = {'passed': False, 'error': f'Cannot read {name}.json: {error}'}
    if data['results'].get('passed') is not True:
        data['receipt']['passed'] = False
    payload = json.dumps(data).replace('<', '\\u003c').replace('&', '\\u0026')
    template = Path(__file__).with_name('report.html').read_text()
    (output / 'report.html').write_text(template.replace('/*REPORT_DATA*/null', payload))
