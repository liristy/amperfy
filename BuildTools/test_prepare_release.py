import hashlib
import importlib.util
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("prepare_release", Path(__file__).with_name("prepare-release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseAssetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source = Path(self.temp.name) / "input"
        self.source.mkdir()
        self.output = Path(self.temp.name) / "output"
        self.commit = "a" * 40
        self.ipa = self.source / "Amperfy-unsigned.ipa"
        self.write_package("3.0.0")
        (self.source / "build-info.txt").write_text(f"Source commit: {self.commit}\n", encoding="utf-8")
        (self.source / "ipa-integrity.log").write_text("Fixture integrity log\n", encoding="utf-8")

    def write_package(self, version):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr("Payload/Amperfy.app/Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": version,
                "CFBundleVersion": "1",
                "CFBundleDisplayName": "qMusic",
                "CFBundleIdentifier": "de.familie-zimba.amperfy-music.sideload",
            }))
        self.digest = hashlib.sha256(self.ipa.read_bytes()).hexdigest()
        (self.source / "SHA256SUMS").write_text(f"{self.digest}  Amperfy-unsigned.ipa\n", encoding="utf-8")

    def prepare(self):
        release.prepare(self.source, self.output, "v3.0.0-beta.1", self.commit)

    def test_release_keeps_ipa_bytes_and_relabels_checksum(self):
        original = self.ipa.read_bytes()
        self.prepare()
        self.assertEqual((self.output / "qMusic-3.0.0-beta.1.ipa").read_bytes(), original)
        self.assertEqual((self.output / "SHA256SUMS").read_text(encoding="utf-8"),
                         f"{self.digest}  qMusic-3.0.0-beta.1.ipa\n")
        self.assertTrue((self.output / "verify_ipa.py").is_file())

    def test_rejects_wrong_app_version(self):
        self.write_package("2.1.1")
        with self.assertRaisesRegex(ValueError, "version"):
            self.prepare()

    def test_rejects_wrong_source_commit(self):
        self.commit = "b" * 40
        with self.assertRaisesRegex(ValueError, "source"):
            self.prepare()

    def test_rejects_tampered_download(self):
        with self.ipa.open("ab") as handle:
            handle.write(b"unexpected")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
