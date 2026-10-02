#!/usr/bin/env python3
"""Simulator process CPU/RSS measurements; never a battery or watts estimate."""
import argparse
import csv
import datetime
import json
from pathlib import Path
import platform
import subprocess
import time
import urllib.request


PHASES = [
    "paused_cover", "playing_cover", "paused_queue", "playing_queue",
    "playing_queue_scroll", "playing_lyrics", "paused_lyrics",
    "playing_visualizer", "playing_transitions", "playing_background", "paused_background",
]


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def parse_cpu_time(value):
    days = 0
    if "-" in value:
        day, value = value.split("-", 1)
        days = int(day)
    seconds = 0.0
    for part in value.split(":"):
        seconds = seconds * 60 + float(part)
    return days * 86400 + seconds


def process_sample(pid):
    fields = command("ps", "-p", str(pid), "-o", "time=", "-o", "rss=").split()
    if len(fields) != 2:
        raise RuntimeError(f"Cannot sample app PID {pid}")
    return {"wall": time.monotonic(), "cpu": parse_cpu_time(fields[0]), "rss_kib": int(fields[1])}


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def wait_for_server(server, timeout=45):
    # A live process is not evidence that it has started accepting requests.
    # Bypass host HTTP proxies for this loopback-only fixture.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if server.poll() is not None:
            raise RuntimeError("Mock server exited before becoming ready; see server.log")
        try:
            with opener.open("http://127.0.0.1:8765/rest/ping.view", timeout=1) as response:
                body = response.read()
                if response.status == 200 and b'subsonic-response' in body and b'status="ok"' in body:
                    print("Loopback fixture responded successfully before app launch", flush=True)
                    return
        except OSError:
            pass
        time.sleep(0.5)
    raise RuntimeError("Mock server readiness timed out; see server.log")


def wait_for(path, predicate, documents, timeout=75):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        failure = read_json(documents / "player-resource-failed.json")
        if failure:
            raise RuntimeError(f"App staging failed: {failure}")
        value = read_json(path)
        if value is not None and predicate(value):
            return value
        time.sleep(0.2)
    raise RuntimeError(f"Timed out waiting for {path.name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--output", type=Path, default=Path("build/resource-profile"))
    args = parser.parse_args()
    if not 10 <= args.seconds <= 20:
        parser.error("Sampling must fit the staged window: 10–20 seconds")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    app = Path("build/validation/DerivedData/Build/Products/Debug-iphonesimulator/Amperfy.app").resolve()
    bundle_id = command("/usr/libexec/PlistBuddy", "-c", "Print CFBundleIdentifier", str(app / "Info.plist"))
    devices = json.loads(command("xcrun", "simctl", "list", "devices", "available", "-j"))["devices"]
    runtime, device = next((runtime, device) for runtime, entries in devices.items()
                           if "iOS-26" in runtime for device in entries
                           if device["state"] == "Booted" and device["name"].startswith("iPhone"))
    device_id = device["udid"]
    documents = Path(command("xcrun", "simctl", "get_app_container", device_id, bundle_id, "data")) / "Documents"
    for name in ("phase", "background", "ready", "failed"):
        (documents / f"player-resource-{name}.json").unlink(missing_ok=True)
    # The preceding UI suite's recording/server have stopped. Do not record
    # video, take screenshots, or run sample/Instruments during these windows.
    server_log = (output / "server.log").open("w")
    stdout = (output / "app.stdout.log").open("w")
    stderr = (output / "app.stderr.log").open("w")
    server = subprocess.Popen(["python3", "-u", "BuildTools/subsonic-smoke-server.py"], stdout=server_log, stderr=subprocess.STDOUT)
    rows = []
    raw_samples = []
    report = {
        "schema_version": 1, "simulator_only": True, "battery_measured": False,
        "source_commit": command("git", "rev-parse", "HEAD"),
        "measured_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "host": platform.platform(), "host_machine": platform.machine(),
        "simulator": {"runtime": runtime, "device": device["name"]},
        "configuration": "Debug", "audio": "Loopback mock server, 180s silent 16kHz mono 16-bit PCM WAV",
        "cpu_definition": "Delta app-process user+system CPU time / monotonic wall time; 100% is one host CPU core",
        "rss_definition": "App-process current RSS from host ps, KiB; excludes simulator/compositor/server processes",
        "limitations": ["No physical battery, watts, mWh or percent/hour measurement",
                        "CPU excludes GPU/compositor, audio hardware, display, cellular/Wi-Fi/Bluetooth power",
                        "Background means actual app background via opening Settings; not physical screen lock",
                        "Short sequential Debug simulator windows on a shared CI host; no absolute iPhone energy inference",
                        "Synthetic PCM audio does not characterize MP3/AAC/FLAC decoding or real network energy"],
        "phases": rows,
    }
    try:
        wait_for_server(server)
        launch = command("xcrun", "simctl", "launch", "--terminate-running-process",
                         "--stdout=" + str(output / "app.stdout.log"), "--stderr=" + str(output / "app.stderr.log"),
                         device_id, bundle_id, "-AppleLanguages", "(zh-Hans)", "--smoke-resource-profile")
        pid = int(launch.rsplit(":", 1)[1].strip())
        for index, name in enumerate(PHASES):
            staged = wait_for(documents / "player-resource-phase.json", lambda value: value.get("index") == index, documents)
            if staged.get("phase") != name or staged.get("pid") != pid or staged.get("state") != 0:
                raise RuntimeError(f"Unexpected staging state: {staged}")
            background_event = None
            if staged["background"]:
                command("xcrun", "simctl", "launch", device_id, "com.apple.Preferences")
                background_event = wait_for(documents / "player-resource-background.json",
                                            lambda value: value.get("phase") == name, documents, timeout=15)
                if background_event["playing"] != staged["playing"]:
                    raise RuntimeError("Background playback state changed before sampling")
            time.sleep(3)
            samples = [process_sample(pid)]
            deadline = samples[0]["wall"] + args.seconds
            while time.monotonic() < deadline:
                time.sleep(min(1, max(0, deadline - time.monotonic())))
                samples.append(process_sample(pid))
            last_phase = read_json(documents / "player-resource-phase.json")
            if not last_phase or last_phase["index"] != index:
                raise RuntimeError(f"Phase changed during {name} sampling")
            wall = samples[-1]["wall"] - samples[0]["wall"]
            cpu = samples[-1]["cpu"] - samples[0]["cpu"]
            if cpu < 0 or wall < args.seconds:
                raise RuntimeError("Invalid CPU time window")
            row = {"phase": name, "wall_seconds": round(wall, 4), "cpu_seconds": round(cpu, 4),
                   "cpu_one_core_percent": round(100 * cpu / wall, 3),
                   "rss_mean_mib": round(sum(s["rss_kib"] for s in samples) / len(samples) / 1024, 2),
                   "rss_peak_mib": round(max(s["rss_kib"] for s in samples) / 1024, 2),
                   "staged_ui": staged, "background_lifecycle": background_event}
            rows.append(row)
            raw_samples.append({"phase": name, "samples": samples})
            (output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
            (output / "samples.json").write_text(json.dumps(raw_samples, indent=2) + "\n")
            print(f"{name}: {row['cpu_one_core_percent']:.3f}% of one host CPU core, RSS {row['rss_mean_mib']:.2f} MiB", flush=True)
            if staged["background"]:
                restored = command("xcrun", "simctl", "launch", device_id, bundle_id)
                if int(restored.rsplit(":", 1)[1].strip()) != pid:
                    raise RuntimeError("App was restarted instead of foregrounded")
        wait_for(documents / "player-resource-ready.json", lambda value: value.get("completed") is True, documents)
        fields = ["phase", "wall_seconds", "cpu_seconds", "cpu_one_core_percent", "rss_mean_mib", "rss_peak_mib"]
        with (output / "summary.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=fields, extrasaction="ignore")
            writer.writeheader()
            writer.writerows(rows)
        report["completed"] = True
        (output / "report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        (output / "interpretation.txt").write_text(
            "这里只测量 Debug 模拟器中应用进程的 CPU 和 RSS，未测得真机功率或电池耗电。\n"
            "CPU 100% 表示一颗 Mac CPU 核心，不是 iPhone 电量；后台场景通过打开设置确认应用进入后台，未模拟真实锁屏功耗。\n"
            "不含屏幕、GPU 合成、基带、蓝牙、扬声器、电池健康和实际 MP3/AAC/FLAC 解码/网络开销。不能换算 mW、mWh 或每小时掉电百分比。\n"
            "真机测试：使用同一台手机、同一版 IPA，记录型号/iOS/电池健康。每种场景连续测 60 分钟，至少重复两轮。\n"
            "固定亮度、音量、耳机/扬声器、音源与网络；不充电，不操作其他应用。分别测锁屏待机、锁屏播放、封面、歌词、队列、频谱和反复转场。\n"
            "记录开始/结束时间、电量、发热和后台播放情况；掉电百分比点/小时 = (开始电量-结束电量)/时长(小时)。与同条件基线比较。\n"
            "系统电池页面里的应用占比是总消耗中的份额，不等于手机总电量下降。精确功率需真实设备支持的 Instruments Power Profiler。\n",
            encoding="utf-8")
    except Exception:
        # Preserve app staging diagnostics even when no measurement window ran.
        for name in ("phase", "background", "ready", "failed"):
            value = read_json(documents / f"player-resource-{name}.json")
            if value is not None:
                (output / f"player-resource-{name}.json").write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
        raise
    finally:
        server.terminate()
        server.wait(timeout=10)
        server_log.close()
        stdout.close()
        stderr.close()


if __name__ == "__main__":
    main()
