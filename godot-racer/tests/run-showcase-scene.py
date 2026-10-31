"""Bounded real CLI scene transition, with no AI and strict final evidence."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

p = argparse.ArgumentParser()
p.add_argument("mode", choices=["check", "level", "autostart"])
p.add_argument("tag")
a = p.parse_args()
if not re.fullmatch(r"[A-Za-z0-9_-]+", a.tag):
    p.error("ASCII evidence tag required")
root = Path(__file__).resolve().parents[2]
directory = root / "godot-logs/showcase-capture-20261025"
directory.mkdir(exist_ok=True)
base = directory / a.tag
if any(directory.glob(a.tag + ".*")):
    raise SystemExit("Existing evidence; choose a fresh tag")
command = ["E:/godot/Godot_v4.4.1-stable_win64_console.exe", "--path", str(root / "godot-racer"),
           "--log-file", str(base) + ".engine.log", "--display-driver", "headless",
           "--audio-driver", "WASAPI", "--script", "res://tests/showcase_scene_probe.gd", "--",
           "--scene-probe=" + a.mode, "--tag=" + a.tag, "--aioff"]
command += [{"check": "--check=enclosure", "level": "--level=1", "autostart": "--autostart=1"}[a.mode]]
try:
    result = subprocess.run(command, capture_output=True, timeout=40)
    output, code = result.stdout + result.stderr, result.returncode
except subprocess.TimeoutExpired as exc:
    output, code = (exc.stdout or b"") + (exc.stderr or b""), 124
Path(str(base) + ".log").write_bytes(output)
engine = Path(str(base) + ".engine.log")
log = engine.read_text(encoding="utf-8", errors="replace") if engine.exists() else output.decode(errors="replace")
ready = re.search(r"SCENE_READY MODE=" + a.mode + r" PASS=(\d+) FAIL=(\d+)", log)
complete = "[CHECK] 完成，退出" in log if a.mode == "check" else bool(re.search(
    r"SCENE_COMPLETE MODE=" + a.mode + r" PASS=[1-9]\d* FAIL=0", log))
errors = re.findall(r"SCRIPT ERROR|ERROR:|Leaked instance|Resource still in use|ObjectDB instances leaked", log)
failures = [line for line in log.splitlines() if "ASSERT FAIL" in line or "✘" in line]
checks = [line for line in log.splitlines() if "[自检]" in line and "✔" in line]
passed = (code == 0 and ready is not None and int(ready[1]) > 0 and ready[2] == "0"
          and complete and not errors and not failures and (a.mode != "check" or bool(checks)))
data = {"command": command, "exit": code, "ready": ready[0] if ready else None,
        "complete": complete, "errors": errors, "failures": failures, "production_checks": checks, "passed": passed}
base.with_suffix(".json").write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
for line in log.splitlines():
    if re.search(r"SCENE_|\[CHECK\]|\[自检\]|SCRIPT ERROR|ERROR:|Leaked instance", line):
        print(line)
print("PROCESS_EXIT", code, "HARNESS", "PASS" if passed else "FAIL")
raise SystemExit(0 if passed else 1)
