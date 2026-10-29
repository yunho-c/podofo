#!/usr/bin/env python3
"""Capture PoDoFo and direct PDFium at matched physical resolution (macOS v1)."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys

from report import write_report

APP = Path(__file__).resolve().parents[2]
ROOT = APP.parent


def capture_process(command, cwd, env, log, timeout):
    # Flutter launches a tester child. Terminate our entire process group on
    # timeout/interruption so a failed run cannot leave native workers behind.
    with subprocess.Popen(command, cwd=cwd, env=env, stdout=log,
                          stderr=subprocess.STDOUT, start_new_session=True) as process:
        try:
            return process.wait(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise argparse.ArgumentTypeError('Must be finite and positive')
    return number


def build_cases(pdf=None, page=1, dpis=None, dprs=None, offsets=None):
    cases = []
    for dpi in dpis or [144, 199, 200, 201, 209, 288]:
        for dpr in dprs or [1, 2]:
            phases = offsets if offsets is not None else ([0, .25, .5, .75] if dpi == 209 else [0])
            for offset in phases:
                cases.append({'pdf': str(pdf) if pdf else None, 'page': page,
                              'dpi': dpi, 'dpr': dpr, 'offset': offset})
    if not pdf and page == 1 and dpis is None and dprs is None and offsets is None:
        cases += [{'pdf': None, 'page': p, 'dpi': 209, 'dpr': 2, 'offset': 0} for p in [2, 3, 4]]
    for i, case in enumerate(cases):
        case['id'] = f"{i:03d}-p{case['page']}-{case['dpi']:g}dpi-{case['dpr']:g}x-offset{case['offset']:g}"
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pdf', type=Path, help='Local PDF; otherwise generate the embedded-font fixture')
    parser.add_argument('--page', type=int, default=1, help='One-based page number')
    parser.add_argument('--dpi', type=positive, action='append', help='Repeat for multiple target DPIs')
    parser.add_argument('--dpr', type=positive, action='append', help='Repeat for multiple device pixel ratios')
    parser.add_argument('--offset', type=float, action='append', help='Subpixel translation in both axes, physical pixels [0,1)')
    parser.add_argument('--output', type=Path, help='Must not exist; default build/rendering-quality/<UTC timestamp>')
    parser.add_argument('--flutter-sdk', type=Path, default=ROOT / '.fvm/flutter_sdk')
    parser.add_argument('--native-frameworks', type=Path, help='Existing app Contents/Frameworks directory; never modified')
    parser.add_argument('--pdfium', type=Path, help='Explicit PDFium binary; also accepts PDFIUM_PATH')
    parser.add_argument('--timeout', type=positive, default=600, help='Whole capture-job timeout in seconds')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('This first runner is qualified on macOS only')
    if args.page < 1:
        parser.error('--page must be positive')
    if args.dpr and any(x > 4 for x in args.dpr):
        parser.error('--dpr must be <= 4 (bounded capture allocation)')
    if args.offset and any(not math.isfinite(x) or not 0 <= x < 1 for x in args.offset):
        parser.error('--offset must be finite and in [0,1)')
    if args.pdf and not args.pdf.is_file():
        parser.error('--pdf must name an existing file')
    output = (args.output or APP / 'build/rendering-quality' /
              datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')).resolve()
    if output.exists():
        parser.error(f'Output already exists; refusing to overwrite: {output}')
    frameworks = args.native_frameworks or APP / 'build/macos/Build/Products/Release/PoDoFo.app/Contents/Frameworks'
    pdfium = args.pdfium or (Path(os.environ['PDFIUM_PATH']) if os.environ.get('PDFIUM_PATH')
                            else frameworks / 'PDFium.framework/pdfium')
    dart = args.flutter_sdk / 'bin/cache/dart-sdk/bin/dart'
    snapshot = args.flutter_sdk / 'bin/cache/flutter_tools.snapshot'
    for path in [pdfium, dart, snapshot, APP / '.dart_tool/package_config.json']:
        if not path.is_file():
            parser.error(f'Missing prerequisite: {path}. See docs/rendering-quality.md.')
    output.mkdir(parents=True, exist_ok=False)
    receipt = {'schema_version': 1, 'passed': False, 'platform': platform.platform(),
               'started_utc': datetime.now(timezone.utc).isoformat(),
               'boundary': 'Headless Flutter test capture; not native GPU/compositor or release performance',
               'pdfium': {'path': str(pdfium.resolve()), 'sha256': digest(pdfium)}}
    try:
        receipt['git_head'] = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        receipt['git_status'] = subprocess.check_output(['git', 'status', '--short'], cwd=ROOT, text=True)
        receipt['flutter_revision'] = subprocess.check_output(
            ['git', '-C', str(args.flutter_sdk.resolve()), 'rev-parse', 'HEAD'], text=True).strip()
        sources = sorted(set(APP.glob('lib/**/*.dart')) | set(APP.glob('third_party/pdfrx/lib/**/*.dart')) |
                         set((APP / 'tool/rendering_quality').glob('*.dart')) |
                         set((APP / 'tool/rendering_quality').glob('*.py')) |
                         set((APP / 'tool/rendering_quality').glob('*.html')) |
                         {APP / 'pubspec.yaml', APP / 'pubspec.lock', ROOT / '.fvmrc',
                          APP / 'assets/fonts/Urbanist/static/Urbanist-Regular.ttf'})
        receipt['source_sha256'] = {str(p.relative_to(ROOT)): digest(p) for p in sources}
        config = {'output': str(output), 'pdfium': str(pdfium.resolve()),
                  'cases': build_cases(args.pdf.resolve() if args.pdf else None, args.page,
                                       args.dpi, args.dpr, args.offset)}
        config_file = output / 'config.json'
        config_file.write_text(json.dumps(config, indent=2) + '\n')
        env = dict(os.environ, PDFIUM_PATH=str(pdfium.resolve()), RENDER_QUALITY_CONFIG=str(config_file))
        objectbox = frameworks / 'ObjectBox.framework/ObjectBox'
        if objectbox.is_file():
            links = output / 'native-links'
            links.mkdir()
            (links / 'libobjectbox.dylib').symlink_to(objectbox.resolve())
            env['DYLD_LIBRARY_PATH'] = str(links) + (':' + env['DYLD_LIBRARY_PATH'] if env.get('DYLD_LIBRARY_PATH') else '')
            receipt['objectbox'] = {'path': str(objectbox.resolve()), 'sha256': digest(objectbox)}
        command = [str(dart.resolve()), str(snapshot.resolve()), 'test', '--no-pub',
                   '--reporter', 'expanded', 'tool/rendering_quality/capture_test.dart']
        receipt['command'] = command
        receipt['cwd'] = str(APP)
        print(f'Capturing {len(config["cases"])} cases into {output}', flush=True)
        with (output / 'capture.log').open('w') as log:
            exit_code = capture_process(command, APP, env, log, args.timeout)
        receipt['exit_code'] = exit_code
        results = json.loads((output / 'results.json').read_text()) if (output / 'results.json').exists() else {}
        receipt['passed'] = exit_code == 0 and results.get('passed') is True
        if not receipt['passed']:
            receipt['error'] = 'Capture did not complete successfully; inspect capture.log and results.json'
    except Exception as error:
        receipt['error'] = f'{type(error).__name__}: {error}'
    finally:
        receipt['finished_utc'] = datetime.now(timezone.utc).isoformat()
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        write_report(output)
    print(f'{"Complete" if receipt["passed"] else "FAILED"}: {output / "report.html"}', flush=True)
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    sys.exit(main())
