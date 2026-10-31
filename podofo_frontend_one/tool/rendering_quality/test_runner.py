"""Fast orchestration checks; no Flutter build or native libraries required."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

from report import write_report
from run import build_cases, capture_process, positive, rendering_defines


class RunnerTest(unittest.TestCase):
    def test_rendering_overrides_preserve_defaults_and_explicit_opt_out(self):
        self.assertEqual(rendering_defines(), [])
        self.assertEqual(rendering_defines(False, False), [
            '--dart-define=PODOFO_FRACTIONAL_RENDERING=false',
            '--dart-define=PODOFO_DISPLAY_SCALE_RENDERING=false',
        ])
        self.assertEqual(rendering_defines(True, False), [
            '--dart-define=PODOFO_FRACTIONAL_RENDERING=true',
            '--dart-define=PODOFO_DISPLAY_SCALE_RENDERING=false',
        ])
        self.assertEqual(rendering_defines(display_scale=True), [
            '--dart-define=PODOFO_DISPLAY_SCALE_RENDERING=true',
        ])

    def test_default_matrix_covers_threshold_and_fractional_placement(self):
        cases = build_cases()
        self.assertEqual(len(cases), 21)
        self.assertEqual(len({c['id'] for c in cases}), 21)
        for dpi in [144, 199, 200, 201, 209, 288]:
            self.assertEqual({c['dpr'] for c in cases if c['dpi'] == dpi}, {1, 2})
        for dpr in [1, 2]:
            self.assertEqual({c['offset'] for c in cases if c['dpi'] == 209 and c['dpr'] == dpr},
                             {0, .25, .5, .75})
        self.assertEqual({c['page'] for c in cases}, {1, 2, 3, 4})

    def test_local_pdf_does_not_add_fixture_rotation_cases(self):
        cases = build_cases(Path('/tmp/example.pdf'), page=7, dpis=[209], dprs=[2], offsets=[.25])
        self.assertEqual(len(cases), 1)
        self.assertEqual((cases[0]['pdf'], cases[0]['page'], cases[0]['offset']),
                         ('/tmp/example.pdf', 7, .25))

    def test_low_zoom_matrix_includes_clamp_safe_phases_and_rotations(self):
        cases = build_cases(suite='low-zoom')
        self.assertEqual(len(cases), 24)
        self.assertEqual(len({c['id'] for c in cases}), 24)
        self.assertEqual({c['dpi'] for c in cases}, {72, 96, 120, 144, 175, 199, 200})
        self.assertFalse(any(c['dpi'] < 120 and c['dpr'] == 2 for c in cases))
        for dpi, dpr in [(144, 1), (199, 1), (199, 2)]:
            self.assertEqual({c['offset'] for c in cases if c['dpi'] == dpi and c['dpr'] == dpr}, {0, .25, .5, .75})
        self.assertEqual({c['page'] for c in cases}, {1, 2, 3, 4})
        custom = build_cases(Path('/tmp/example.pdf'), page=7, suite='low-zoom')
        self.assertEqual(len(custom), 21)
        self.assertEqual({c['page'] for c in custom}, {7})

    def test_invalid_numeric_arguments(self):
        for value in ['0', '-1', 'nan', 'inf', '-inf']:
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                positive(value)

    def test_existing_output_is_never_modified(self):
        with tempfile.TemporaryDirectory() as directory:
            sentinel = Path(directory) / 'keep.txt'
            sentinel.write_text('original')
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('run.py')),
                                     '--output', directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), 'original')
            self.assertEqual(list(Path(directory).iterdir()), [sentinel])

    def test_failure_report_and_untrusted_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'receipt.json').write_text(json.dumps({'passed': False, 'error': '</script><script>alert(1)</script>'}))
            write_report(root)
            html = (root / 'report.html').read_text()
            self.assertNotIn('</script><script>alert(1)', html)
            self.assertIn(r'\u003c/script>', html)
            self.assertIn('INCOMPLETE / FAILED', html)
            (root / 'results.json').write_text('{truncated')
            write_report(root)
            self.assertIn('Cannot read results.json', (root / 'report.html').read_text())

    @unittest.skipUnless(os.name == 'posix', 'Process-group cleanup uses POSIX')
    def test_timeout_stops_child_as_well_as_parent(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'child-finished'
            child = f'import time; from pathlib import Path; time.sleep(0.6); Path({str(marker)!r}).touch()'
            parent = f'import subprocess,sys,time; subprocess.Popen([sys.executable,"-c",{child!r}]); time.sleep(30)'
            with open(os.devnull, 'w') as log, self.assertRaises(subprocess.TimeoutExpired):
                capture_process([sys.executable, '-c', parent], directory, os.environ, log, .2)
            time.sleep(.7)
            self.assertFalse(marker.exists(), 'Timed-out child continued running')


if __name__ == '__main__':
    unittest.main()
