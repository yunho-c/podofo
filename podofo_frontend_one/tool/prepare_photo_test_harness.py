#!/usr/bin/env python3
"""Prepare focused tests when the unrelated pinned MLSR SDK cannot be fetched.

Requires PyYAML. Copies sources to a NEW directory outside the checkout and
removes only the three MLSR packages and their native hook from that copy.
This is not an application build or a substitute for full reader qualification.
"""
import argparse
from pathlib import Path
import shutil
import yaml


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    app = Path(__file__).resolve().parents[1]
    destination = args.destination.resolve()
    if destination.exists() or app in destination.parents:
        parser.error('Use a new directory outside the checkout')
    destination.mkdir(parents=True)
    for name in ['lib', 'test', 'tool', 'shaders', 'assets', 'analysis_options.yaml']:
        source = app / name
        if source.is_dir():
            shutil.copytree(source, destination / name, ignore=shutil.ignore_patterns('__pycache__'))
        else:
            shutil.copy2(source, destination / name)
    spec = yaml.safe_load((app / 'pubspec.yaml').read_text())
    lock = yaml.safe_load((app / 'pubspec.lock').read_text())
    for name in ['mlsr', 'mlsr_flutter', 'mlsr_app_models']:
        spec['dependencies'].pop(name)
        lock['packages'].pop(name)
    spec.pop('hooks')
    (destination / 'pubspec.yaml').write_text(yaml.safe_dump(spec, sort_keys=False))
    (destination / 'pubspec.lock').write_text(yaml.safe_dump(lock, sort_keys=False))
    print(destination)
    print('Run flutter pub get --enforce-lockfile here, then the focused commands in docs/photo-dark-mode.md.')


if __name__ == '__main__':
    main()
