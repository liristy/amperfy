"""Run the same cached simulator app on the user's OS major without rebuilding it."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import time
import urllib.parse
import urllib.request


def command(*args):
    return subprocess.check_output(args, text=True, timeout=180).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["stamp", "wait-cache", "boot"])
    args = parser.parse_args()
    app = Path("build/validation/DerivedData/Build/Products/Debug-iphonesimulator/Amperfy.app")
    stamp = Path("build/validation/DerivedData/simulator-build-source.json")
    if args.mode == "stamp":
        info = plistlib.loads((app / "Info.plist").read_bytes())
        executable = info["CFBundleExecutable"]
        stamp.write_text(json.dumps({
            "source_commit": command("git", "rev-parse", "HEAD"), "executable": executable,
            "sha256": hashlib.sha256((app / executable).read_bytes()).hexdigest(),
            "sdk": info.get("DTSDKName"),
        }, indent=2))
        print("Stamped the successfully built and unit-tested simulator executable", flush=True)
        return
    if args.mode == "wait-cache":
        key = os.environ["SIMULATOR_CACHE_KEY"]
        source = os.environ["SIMULATOR_SOURCE_SHA"]
        if not re.fullmatch(r"[0-9a-f]{40}", source) or not key.endswith("-" + source):
            raise RuntimeError("A full source commit and its exact cache key are required")
        query = urllib.parse.urlencode({"key": key, "ref": os.environ["GITHUB_REF"]})
        url = f"https://api.github.com/repos/{os.environ['GITHUB_REPOSITORY']}/actions/caches?{query}"
        # The producer allows 35 minutes for a cold incremental compile + tests.
        # Do not let the independent runtime consumer expire before that window.
        deadline = time.monotonic() + 2400
        while time.monotonic() < deadline:
            request = urllib.request.Request(url, headers={
                "Authorization": "Bearer " + os.environ["GH_TOKEN"],
                "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28",
            })
            with urllib.request.urlopen(request, timeout=30) as response:
                caches = json.load(response)["actions_caches"]
            if any(c["key"] == key for c in caches):
                print("Exact compiled simulator cache is ready", flush=True)
                return
            print("Waiting for the source-matched simulator build cache", flush=True)
            time.sleep(30)
        raise TimeoutError("The source build did not publish its simulator cache")

    built = json.loads(stamp.read_text())
    if (built["source_commit"] != os.environ["SIMULATOR_SOURCE_SHA"] or
            hashlib.sha256((app / built["executable"]).read_bytes()).hexdigest() != built["sha256"]):
        raise RuntimeError("Cached simulator executable was not successfully built from the requested source")
    manifest = Path("build/validation/DerivedData/source-mtimes.json")
    entries = json.loads(manifest.read_text())
    tracked = command("git", "ls-files", "-z").strip("\0").split("\0")
    app_sources = [name for name in tracked if name.startswith(("Amperfy/", "AmperfyKit/", "Amperfy.xcodeproj/"))]
    if not app_sources:
        raise RuntimeError("No application source files to verify")
    for name in app_sources:
        path = Path(name)
        if not path.is_file() or path.is_symlink():
            continue
        previous = entries.get(name)
        if not previous or hashlib.sha256(path.read_bytes()).hexdigest() != previous[0]:
            raise RuntimeError("Cached simulator binary does not match checked-out app source: " + name)
    print(f"Verified {len(app_sources)} app/project source fingerprints before reusing the binary", flush=True)
    if not app.is_dir():
        raise RuntimeError("The source-matched cache has no simulator application")
    runtimes = json.loads(command("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    output = Path("build/navigation-glass")
    output.mkdir(parents=True, exist_ok=True)
    (output / "runtime-catalog.json").write_text(json.dumps(runtimes, indent=2))
    candidates = [r for r in runtimes if r.get("isAvailable") and r.get("version", "").startswith("27.2")
                  and "SimRuntime.iOS-" in r["identifier"]]
    # Device-specific runtimes (for example iPhone Duo) cannot boot a Pro Max.
    candidates.sort(key=lambda r: r["identifier"] != "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
    runtime = next((r for r in candidates if r["identifier"] == "com.apple.CoreSimulator.SimRuntime.iOS-27-2"), None)
    if not runtime:
        raise RuntimeError("The runner does not have the required iOS 27.2 runtime")
    device_type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"
    device = command("xcrun", "simctl", "create", "qMusic Glass iPhone 17 Pro Max", device_type, runtime["identifier"])
    command("xcrun", "simctl", "boot", device)
    # The first boot of a fresh iOS 27.2 runtime can migrate simulator services
    # for several minutes. Preserve its progress instead of hiding it in a
    # three-minute check_output timeout.
    with (output / "boot.log").open("w") as log:
        subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"],
                       stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
    (output / "runtime.json").write_text(json.dumps({
        "runtime": runtime["identifier"], "version": runtime["version"],
        "device_type": device_type, "application_source": os.environ["SIMULATOR_SOURCE_SHA"],
        "executable_sha256": built["sha256"], "built_sdk": built.get("sdk"),
        "app_sources_verified": len(app_sources), "recompiled": False,
    }, indent=2))
    print("Booted iPhone 17 Pro Max with iOS " + runtime["version"], flush=True)
    with open(os.environ["GITHUB_ENV"], "a") as environment:
        environment.write("SMOKE_GLASS_DEVICE=" + device + "\n")


if __name__ == "__main__":
    main()
