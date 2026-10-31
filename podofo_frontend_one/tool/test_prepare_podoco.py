import unittest
from pathlib import Path
from unittest.mock import patch

import prepare_podoco


class PreparationTests(unittest.TestCase):
    def test_platform_selection(self):
        for system, machine, expected in [
            ('Darwin', 'arm64', 'macos-arm64'), ('Darwin', 'x86_64', 'macos-x64'),
            ('Windows', 'AMD64', 'windows-x64'), ('Windows', 'ARM64', 'windows-arm64'),
            ('Linux', 'aarch64', 'linux-arm64'), ('Linux', 'x86_64', 'linux-x64'),
        ]:
            self.assertEqual(prepare_podoco.resource_platform(system, machine), expected)
        with self.assertRaises(ValueError):
            prepare_podoco.resource_platform('Linux', 'riscv64')

    @patch('prepare_podoco.subprocess.run')
    @patch('prepare_podoco.platform.system', return_value='Windows')
    @patch('prepare_podoco.platform.machine', return_value='AMD64')
    def test_model_free_platform_and_explicit_replacement(self, _machine, _system, run):
        config = Path('directory with spaces/models.yaml')
        prepare_podoco.prepare_models(config)
        args = run.call_args.args[0]
        self.assertEqual(args[-4:], ['--config', str(config), '--platform', 'windows-x64'])
        self.assertNotIn('--replace', args)
        self.assertTrue(run.call_args.kwargs['check'])
        prepare_podoco.prepare_models(config, replace=True)
        self.assertEqual(run.call_args.args[0][-1], '--replace')


if __name__ == '__main__':
    unittest.main()
