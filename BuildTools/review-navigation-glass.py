"""Record actual system-glass navigation in controlled light/dark appearances.

Uses only the throwaway CI simulator and loopback fixtures. The original behavior,
the immediate material update, and native slide navigation share the same binary.
Pixel/animation review happens from the compositor videos, not drawHierarchy.
"""
import json
from pathlib import Path
import shutil
import subprocess
import time
import urllib.request


def command(*args, check=True):
    result = subprocess.run(args, text=True, capture_output=True, timeout=120)
    if check and result.returncode:
        raise RuntimeError(f"{args[:3]} failed: {result.stderr[-1500:]}")
    return result.stdout.strip()


def wait_file(path, failed=None, timeout=100):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if failed and failed.exists():
            raise RuntimeError(failed.read_text())
        if path.exists():
            return json.loads(path.read_text())
        time.sleep(0.2)
    raise TimeoutError(f"Simulator did not write {path.name}")


def main():
    devices = json.loads(command("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    booted = [d for runtime, values in devices.items() if "iOS-26" in runtime
              for d in values if d["state"] == "Booted" and d["name"].startswith("iPhone")]
    booted.sort(key=lambda d: d["name"] != "iPhone 17 Pro Max")
    if not booted:
        raise RuntimeError("The build step did not boot its throwaway iOS 26 simulator")
    device = booted[0]["udid"]
    app = Path("build/validation/DerivedData/Build/Products/Debug-iphonesimulator/Amperfy.app").resolve()
    bundle = command("/usr/libexec/PlistBuddy", "-c", "Print CFBundleIdentifier", str(app / "Info.plist"))
    output = Path("build/navigation-glass").resolve()
    output.mkdir(parents=True, exist_ok=True)
    command("xcrun", "simctl", "terminate", device, bundle, check=False)
    command("xcrun", "simctl", "uninstall", device, bundle, check=False)
    command("xcrun", "simctl", "install", device, str(app))
    documents = Path(command("xcrun", "simctl", "get_app_container", device, bundle, "data")) / "Documents"
    server_log = (output / "server.log").open("w")
    server = subprocess.Popen(["python3", "-u", "BuildTools/subsonic-smoke-server.py"],
                              stdout=server_log, stderr=subprocess.STDOUT)
    recorder = None
    variants = []
    try:
        for _ in range(60):
            try:
                with urllib.request.urlopen("http://127.0.0.1:8765/rest/ping.view", timeout=2) as response:
                    if response.status == 200:
                        break
            except OSError:
                time.sleep(0.2)
        else:
            raise RuntimeError("Loopback fixture server did not become ready")
        command("xcrun", "simctl", "launch", device, bundle, "-AppleLanguages", "(zh-Hans)", "--smoke-login")
        # The existing login smoke marker is plain text.
        deadline = time.monotonic() + 150
        while not (documents / "login-smoke-ready").exists():
            if time.monotonic() > deadline:
                raise TimeoutError("Initial fixture login did not complete")
            time.sleep(0.5)
        for policy in ("baseline", "immediate", "slide"):
            for appearance in ("light", "dark"):
                name = f"{policy}-{appearance}"
                for path in documents.glob("chrome-review-*"):
                    path.unlink()
                for path in [documents / "chrome-review-recording"]:
                    path.unlink(missing_ok=True)
                args = ["xcrun", "simctl", "launch", "--terminate-running-process",
                        "--stdout=" + str(output / f"{name}.stdout.log"),
                        "--stderr=" + str(output / f"{name}.stderr.log"), device, bundle,
                        "-AppleLanguages", "(zh-Hans)", "--smoke-login", "--smoke-chrome"]
                if policy != "immediate":
                    args.append("--smoke-chrome-" + policy)
                if appearance == "dark":
                    args.append("--smoke-chrome-dark")
                command(*args)
                failed = documents / "chrome-review-failed.json"
                wait_file(documents / "chrome-review-prepared.json", failed)
                with (output / f"{name}.record.log").open("w") as log:
                    recorder = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo", "--codec=h264",
                                                 str(output / f"{name}.mp4")], stdout=log, stderr=subprocess.STDOUT)
                    time.sleep(1)
                    (documents / "chrome-review-recording").touch()
                    try:
                        result = wait_file(documents / "chrome-review-ready.json", failed, timeout=45)
                        if result.get("completed") is not True:
                            raise RuntimeError("Incomplete native navigation recording")
                        (output / f"{name}.json").write_text(json.dumps(result, indent=2))
                    finally:
                        recorder.send_signal(2)
                        recorder.wait(timeout=30)
                        recorder = None
                        for path in documents.glob("chrome-review-*.json"):
                            shutil.copy2(path, output / f"{name}-{path.name}")
                variants.append(name)
                print(f"Recorded actual native glass: {name}", flush=True)
        (output / "source.json").write_text(json.dumps({
            "source_commit": command("git", "rev-parse", "HEAD"),
            "variants": variants, "simulator": booted[0]["name"],
            "baseline": "Previous coordinator-animated interface-style change",
            "immediate": "Native zoom with interface-style committed without animation",
            "slide": "Immediate interface-style with the native slide transition",
        }, indent=2))
    finally:
        if recorder:
            recorder.send_signal(2)
            recorder.wait(timeout=30)
        command("xcrun", "simctl", "terminate", device, bundle, check=False)
        server.terminate()
        server.wait(timeout=10)
        server_log.close()


if __name__ == "__main__":
    main()
