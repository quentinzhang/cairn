from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Scripts"))
import install_opencode_plugin as plugin


class OpenCodeInstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        root = Path(self.temp.name)
        self.source = root / "bundle" / "OpenCodePlugin" / "index.js"
        self.source.parent.mkdir(parents=True)
        self.source.write_text("export default () => ({})\n", encoding="utf-8")
        self.target = root / "config" / "opencode" / "plugins" / "cairn.js"
        self.old_source, self.old_target = plugin.SOURCE, plugin.TARGET
        plugin.SOURCE, plugin.TARGET = self.source, self.target

    def tearDown(self) -> None:
        plugin.SOURCE, plugin.TARGET = self.old_source, self.old_target
        self.temp.cleanup()

    def test_install_relinks_only_cairns_symlink_and_uninstalls_exactly_it(self) -> None:
        self.assertTrue(plugin.relink())
        self.assertTrue(self.target.is_symlink())
        self.assertEqual(self.target.resolve(), self.source.resolve())
        self.assertFalse(plugin.relink())
        self.assertTrue(plugin.unlink())
        self.assertFalse(self.target.exists())

    def test_refuses_real_file_or_directory(self) -> None:
        self.target.parent.mkdir(parents=True)
        self.target.write_text("user plugin", encoding="utf-8")
        with self.assertRaises(RuntimeError):
            plugin.relink()
        with self.assertRaises(RuntimeError):
            plugin.unlink()


if __name__ == "__main__":
    unittest.main()
