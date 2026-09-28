"""Keep Xcode's incremental cache useful across fresh GitHub checkouts.

Only files with identical content recover their previous timestamps. Changed
sources retain checkout timestamps so Xcode must compile the new implementation.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def fingerprint(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(root, paths, manifest):
    entries = {}
    for name in paths:
        path = root / name
        if path.is_file() and not path.is_symlink():
            entries[name] = [fingerprint(path), path.stat().st_mtime_ns]
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps(entries), encoding="utf-8")
    return len(entries)


def restore(root, paths, manifest):
    if not manifest.is_file():
        return 0
    entries = json.loads(manifest.read_text(encoding="utf-8"))
    count = 0
    for name in paths:
        path = root / name
        previous = entries.get(name)
        if previous and path.is_file() and not path.is_symlink() and fingerprint(path) == previous[0]:
            os.utime(path, ns=(path.stat().st_atime_ns, previous[1]))
            count += 1
    return count


if __name__ == "__main__":
    mode, destination = sys.argv[1:]
    root = Path.cwd()
    paths = subprocess.check_output(["git", "ls-files", "-z"]).decode("utf-8").strip("\0").split("\0")
    operation = {"save": save, "restore": restore}[mode]
    print(f"{mode}: {operation(root, paths, Path(destination))} unchanged-source timestamps")
