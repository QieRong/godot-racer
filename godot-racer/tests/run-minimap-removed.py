"""Bounded real gameplay test of the removed minimap and M binding."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
p = argparse.ArgumentParser()
p.add_argument("tag")
p.add_argument("--graphics", action="store_true")
a = p.parse_args()
if not re.fullmatch(r"[A-Za-z0-9_-]+", a.tag):
    p.error("Fresh ASCII evidence tag required")
root = Path(__file__).resolve().parents[2]
directory = root / "godot-logs/minimap-remove-20261025"
directory.mkdir(parents=True, exist_ok=True)
base = directory / a.tag
if base.with_suffix(".json").exists():
    raise SystemExit("Existing evidence; choose a fresh tag")
command = ["E:/godot/Godot_v4.4.1-stable_win64_console.exe", "--path", str(root / "godot-racer"),
           "--log-file", str(base) + ".engine.log", "--audio-driver", "WASAPI"]
command += ["--rendering-method", "forward_plus"] if a.graphics else ["--display-driver", "headless"]
command += ["--script", "res://tests/minimap_removed_test.gd", "--", "--tag=" + a.tag,
            "--aioff", "--minimap=on", "--render-fps=60"]
try:
    result = subprocess.run(command, capture_output=True, timeout=35)
    output, code = result.stdout + result.stderr, result.returncode
except subprocess.TimeoutExpired as exc:
    output, code = (exc.stdout or b"") + (exc.stderr or b""), 124
Path(str(base) + ".log").write_bytes(output)
engine = Path(str(base) + ".engine.log")
log = engine.read_text(encoding="utf-8", errors="replace") if engine.exists() else output.decode(errors="replace")
complete = re.search(r"MINIMAP_REMOVED_COMPLETE PASS=(\d+) FAIL=(\d+)", log)
errors = re.findall(r"SCRIPT ERROR|ERROR:|Leaked instance|Resource still in use|ObjectDB instances leaked", log)
failures = [line for line in log.splitlines() if "ASSERT FAIL" in line]
passed = code == 0 and complete is not None and int(complete[1]) > 0 and complete[2] == "0" and not errors and not failures
data = {"command": command, "exit": code, "complete": complete[0] if complete else None,
        "failures": failures, "errors_or_leaks": errors, "passed": passed}
base.with_suffix(".json").write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
for line in log.splitlines():
    if "MINIMAP_REMOVED" in line or "ERROR" in line:
        print(line)
print("PROCESS_EXIT", code, "HARNESS", "PASS" if passed else "FAIL")
raise SystemExit(0 if passed else 1)
