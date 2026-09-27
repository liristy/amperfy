#!/usr/bin/env python3
"""Stage verified release assets; never sign or alter the IPA payload."""

import hashlib
import plistlib
import re
import shutil
import sys
import zipfile
from pathlib import Path


def prepare(source: Path, output: Path, tag: str, commit: str) -> None:
    match = re.fullmatch(r"v(\d+\.\d+\.\d+)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?", tag)
    if not match:
        raise ValueError("Release tag must be vX.Y.Z or vX.Y.Z-prerelease")
    notes = Path("docs/releases") / f"{tag}.md"
    if not notes.is_file():
        raise ValueError(f"Missing release notes: {notes}")
    packages = list(source.rglob("Amperfy-unsigned.ipa"))
    if len(packages) != 1:
        raise ValueError("Expected exactly one IPA in the build artifact")
    ipa = packages[0]
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    sums = (ipa.parent / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
    if f"{digest}  Amperfy-unsigned.ipa" not in sums:
        raise ValueError("Build artifact checksum mismatch")
    build_info = (ipa.parent / "build-info.txt").read_text(encoding="utf-8")
    if f"Source commit: {commit}" not in build_info.splitlines():
        raise ValueError("Build artifact source does not match the release commit")
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError("Corrupt IPA ZIP")
        info = plistlib.loads(archive.read("Payload/Amperfy.app/Info.plist"))
    if info.get("CFBundleShortVersionString") != match[1]:
        raise ValueError("App version does not match the release tag")
    if info.get("CFBundleDisplayName") != "qMusic":
        raise ValueError("Unexpected app display name")
    if info.get("CFBundleIdentifier") != "de.familie-zimba.amperfy-music.sideload":
        raise ValueError("Unexpected app identifier")
    output.mkdir(parents=True, exist_ok=True)
    name = f"qMusic-{tag[1:]}.ipa"
    shutil.copyfile(ipa, output / name)
    (output / "SHA256SUMS").write_text(f"{digest}  {name}\n", encoding="utf-8")
    (output / "build-info.txt").write_text(
        f"Release: {tag}\nApp version: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})\n"
        + build_info, encoding="utf-8"
    )
    shutil.copyfile(ipa.parent / "ipa-integrity.log", output / "ipa-integrity.log")
    shutil.copyfile("docs/iphone-install-zh.md", output / "iphone-install-zh.md")
    shutil.copyfile("BuildTools/verify_ipa.py", output / "verify_ipa.py")
    print(f"Prepared {tag} from {commit}: {name}, SHA256 {digest}")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        raise SystemExit("Usage: prepare-release.py INPUT OUTPUT TAG COMMIT")
    prepare(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4])
