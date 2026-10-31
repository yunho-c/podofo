#!/usr/bin/env python3
"""Qualify optional math Rust/C/Dart output using saved native M6 recognition."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def sha(p):
    with p.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def rows(path):
    return [json.loads(line[line.index('{'):]) for line in path.read_text().splitlines() if '{' in line]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for key in ['rules', 'documents', 'crops', 'output']:
        p.add_argument('--' + key, type=lambda v: Path(v).resolve(), required=True)
    p.add_argument('--dart', default='dart')
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    paths = [*sorted((ROOT / 'crates').rglob('*.rs')),
             *sorted((ROOT / 'bindings/dart/lib').rglob('*.dart')),
             ROOT / 'bindings/dart/example/math.dart', ROOT / 'bindings/dart/test/math_test.dart',
             ROOT / 'Cargo.lock', ROOT / 'model-manifests/mathcat-rules-v1.yaml',
             ROOT / 'third_party/mathcat-source.json', Path(__file__)]
    sources = {str(p.relative_to(ROOT)): sha(p) for p in paths}
    def run(name, command, cwd=ROOT, env=None):
        with (a.output / (name + '.log')).open('w') as log:
            subprocess.run([str(v) for v in command], cwd=cwd, env=env,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    run('build', ['cargo', 'build', '--locked', '--release', '-p', 'podoco', '-p', 'podoco-ffi', '--example', 'math', '--lib', '--features', 'math'])
    native = ROOT / 'target/release/libpodoco_ffi.dylib'
    binary = ROOT / 'target/release/examples/math'
    binaries = {str(p.relative_to(ROOT)): sha(p) for p in [native, binary]}
    options = dict(language='en', speech_style='ClearSpeak', verbosity='Medium', decimal_separators='.', block_separators=', \u00a0\u202f')
    cases = []
    for row in rows(a.documents):
        payload = row['payload']
        if payload['type'] == 'formula_finished' and payload['outcome']['status'] == 'recognized':
            formula = payload['outcome']['formula']
            cases.append(dict(id=f"detected-{payload['page_key']['page_index']}-{payload['region_id']}",
                              input=dict(format='latex', text=formula['latex'], display_kind=formula['display_kind']), options=options))
    for row in rows(a.crops):
        if row['outcome']['status'] == 'recognized':
            formula = row['outcome']['formula']
            cases.append(dict(id='crop-' + Path(row['input']).stem,
                              input=dict(format='latex', text=formula['latex'], display_kind=formula['display_kind']), options=options))
    cases.extend(json.loads((ROOT / 'tests/fixtures/math/cases.json').read_text()))
    inputs = a.output / 'inputs.jsonl'
    inputs.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in cases))
    with (a.output / 'rust.jsonl').open('w') as out, (a.output / 'rust.log').open('w') as log:
        subprocess.run([str(binary), str(a.rules), 'en', 'ClearSpeak', '--jsonl', str(inputs)], stdout=out, stderr=log, check=True)
    env = dict(os.environ, PODOCO_M7_RULES=str(a.rules))
    run('host', ['cargo', 'test', '--locked', '-p', 'podoco', '--features', 'math', '--test', 'math_host', '--', '--ignored', '--nocapture'], env=env)
    with tempfile.TemporaryDirectory(prefix='podoco-math-') as temp:
        package = Path(temp) / 'package'
        shutil.copytree(ROOT / 'bindings/dart', package, ignore=shutil.ignore_patterns('.dart_tool', 'build', '.DS_Store'))
        manifest = package / 'pubspec.yaml'
        manifest.write_text(manifest.read_text() + '\nhooks:\n  user_defines:\n    podoco:\n' + f'      native-library: {json.dumps(str(native))}\n')
        run('pub', [a.dart, 'pub', 'get', '--enforce-lockfile'], cwd=package)
        run('tests', [a.dart, 'test', 'test/math_test.dart', '--concurrency=1', '--reporter=expanded'], cwd=package, env=env)
        with (a.output / 'dart.jsonl').open('w') as out, (a.output / 'dart.log').open('w') as log:
            subprocess.run([a.dart, 'run', 'example/math.dart', str(a.rules), str(inputs)], cwd=package, stdout=out, stderr=log, check=True)
    rust, dart = rows(a.output / 'rust.jsonl'), rows(a.output / 'dart.jsonl')
    failures = []
    if len(rust) != len(cases) or len(dart) != len(cases):
        failures.append('conversion count differs')
    for left, right in zip(rust, dart):
        if left != right:
            failures.append('Dart/Rust output differs: ' + left['id'])
    tests = (a.output / 'tests.log').read_text()
    passed = re.findall(r'\+(\d+): All tests passed!', tests)
    if not passed or int(passed[-1]) != 5 or 'Skip:' in tests:
        failures.append('Dart native tests incomplete')
    for name, digest in {**sources, **binaries}.items():
        if sha(ROOT / name) != digest:
            failures.append('source/binary drift: ' + name)
    groups = {}
    for prefix in ['detected-', 'crop-', 'fixture-']:
        selected = [r for r in rust if r['id'].startswith(prefix)]
        groups[prefix[:-1]] = dict(count=len(selected), successful=sum('value' in r for r in selected),
                                  errors=dict(Counter(r['error']['code'] for r in selected if 'error' in r)))
    summary = dict(groups=groups, compared=len(rust), dart_tests=int(passed[-1]) if passed else 0,
                   rules_manifest_sha256=sha(a.rules / 'podoco-rules.yaml'),
                   inputs_sha256=sha(inputs), rust_sha256=sha(a.output / 'rust.jsonl'), dart_sha256=sha(a.output / 'dart.jsonl'),
                   source_inputs={str(p): sha(p) for p in [a.documents, a.crops]},
                   sources=sources, binaries=binaries, failures=failures,
                   dart_version=subprocess.check_output([a.dart, '--version'], text=True).strip())
    (a.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps({k: v for k, v in summary.items() if k not in ['sources', 'source_inputs']}, indent=2))
    if failures:
        raise RuntimeError(failures)


if __name__ == '__main__':
    main()
