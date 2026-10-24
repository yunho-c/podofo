"""Portable preparation checks; no downloads, native builds or real model assets."""
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import prepare_mlsr as prepare


class PreparationTests(unittest.TestCase):
    def test_supported_native_targets(self):
        self.assertEqual(prepare.target_for("Windows", "AMD64"), "x86_64-pc-windows-msvc")
        self.assertEqual(prepare.target_for("Windows", "ARM64"), "aarch64-pc-windows-msvc")
        self.assertEqual(prepare.target_for("Darwin", "arm64"), "aarch64-apple-darwin")
        self.assertEqual(prepare.target_for("Linux", "x86_64"), "x86_64-unknown-linux-gnu")
        with self.assertRaises(ValueError):
            prepare.target_for("Android", "arm64")

    def test_portable_package_is_idempotent_and_preserves_real_models(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(prepare, "ROOT", root):
                prepare.prepare_model_free_package(root / "sdk")
                package = root / "model_assets"
                first = (package / "pubspec.yaml").read_bytes()
                prepare.prepare_model_free_package(root / "sdk")
                self.assertEqual(first, (package / "pubspec.yaml").read_bytes())
                self.assertIn(b"version: 0.1.0", first)
                self.assertIn("model_platform_unsupported", (package / "lib/app_models.dart").read_text())
                (package / ".model-free").unlink()
                with self.assertRaises(ValueError):
                    prepare.prepare_model_free_package(root / "sdk")
                self.assertEqual(first, (package / "pubspec.yaml").read_bytes())


if __name__ == "__main__":
    unittest.main()
