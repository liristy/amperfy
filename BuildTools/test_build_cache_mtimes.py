import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("cache_mtimes", Path(__file__).with_name("build-cache-mtimes.py"))
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class CacheTimestampTests(unittest.TestCase):
    def test_only_identical_existing_sources_recover_timestamps(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            paths = ["same.swift", "changed.swift", "deleted.swift"]
            for name in paths:
                (root / name).write_text("original", encoding="utf-8")
                os.utime(root / name, ns=(1_000_000_000, 1_000_000_000))
            manifest = root / "cache/mtimes.json"
            self.assertEqual(cache.save(root, paths, manifest), 3)
            for name in paths[:2]:
                os.utime(root / name, ns=(2_000_000_000, 2_000_000_000))
            (root / paths[1]).write_text("modified", encoding="utf-8")
            changed_time = (root / paths[1]).stat().st_mtime_ns
            (root / paths[2]).unlink()
            self.assertEqual(cache.restore(root, paths, manifest), 1)
            self.assertEqual((root / paths[0]).stat().st_mtime_ns, 1_000_000_000)
            self.assertEqual((root / paths[1]).stat().st_mtime_ns, changed_time)
            self.assertFalse((root / paths[2]).exists())

    def test_first_run_without_cache(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.assertEqual(cache.restore(root, [], root / "missing.json"), 0)


if __name__ == "__main__":
    unittest.main()
