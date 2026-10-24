"""Run a warm duration diagnostic using existing local models and native libraries."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys

APP = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pdf', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True, help='New evidence directory')
    parser.add_argument('--sdk-source', type=Path, default=APP / '.mlsr/sdk/bindings/dart',
                        help='Dart SDK package for the isolated CLI comparison')
    parser.add_argument('--processes', type=int, default=2)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--modes', default='idle,playing,paused')
    args = parser.parse_args()
    if args.processes < 1 or args.repetitions < 1:
        parser.error('processes and repetitions must be positive')
    pdf, output = args.pdf.resolve(strict=True), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    dart = APP.parent / '.fvm/flutter_sdk/bin/dart'
    flutter = dart.with_name('flutter')
    receipt = {'passed': False, 'platform': platform.platform(), 'commands': [],
               'sources': {}, 'native_sha256': hashlib.sha256((APP / '.mlsr/native/mlsr_ffi').read_bytes()).hexdigest()}
    sources = list((APP / 'tool/duration_profile').glob('*')) + [
        APP / 'lib/src/narration' / name for name in
        ['duration_profile.dart', 'paper_sequence.dart', 'mlsr_narrator.dart']]
    for path in sources:
        if path.is_file(): receipt['sources'][str(path.relative_to(APP))] = hashlib.sha256(path.read_bytes()).hexdigest()

    def run(command, cwd, log, env=None):
        print(f'Running {log}', flush=True)
        receipt['commands'].append({'argv': list(map(str, command)), 'cwd': str(cwd), 'log': log})
        with (output / log).open('w') as stream:
            subprocess.run(list(map(str, command)), cwd=cwd, env=env,
                           stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=600)

    def capture(name):
        for command, suffix in [(['pmset', '-g', 'batt'], 'power'),
                                (['ps', '-axo', 'pid,pcpu,comm'], 'processes')]:
            (output / f'{name}-{suffix}.txt').write_text(subprocess.check_output(command, text=True))

    try:
        capture('before')
        env = dict(os.environ, PROFILE_PDF=str(pdf), PROFILE_OUTPUT=str(output / 'app'))
        run([flutter, 'test', '--no-pub', 'tool/duration_profile/app_probe_test.dart', '--reporter', 'expanded'],
            APP, 'app.log', env)
        sdk = output / 'sdk'
        run([sys.executable, APP / 'tool/duration_profile/prepare_sdk.py', sdk, '--sdk-source', args.sdk_source.resolve()], APP, 'prepare.log')
        run([dart, 'pub', 'get', '--offline'], sdk, 'pub.log')
        run([dart, 'build', 'cli', '-t', 'probe.dart', '-o', 'aot'], sdk, 'build.log')
        for i in range(args.processes):
            capture(f'process-{i}')
            env = dict(os.environ, PROFILE_REPETITIONS=str(args.repetitions), PROFILE_MODES=args.modes)
            run([sdk / 'aot/bundle/bin/probe',
                 APP / '.mlsr/sdk/model-manifests/supertonic3-coreml-fp16-voices.yaml',
                 APP / '.mlsr/model_assets/models/supertonic3-coreml-fp16-t384-voices-v1',
                 output / 'app/corpus.json', output / f'process-{i}.json'], sdk, f'process-{i}.log', env)
        capture('after')
        receipt['passed'] = True
    finally:
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')


if __name__ == '__main__':
    main()
