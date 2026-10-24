"""Bounded final rendering/CLI route probe; no racing or AI regression."""
import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("mode", choices=["matrix", "check", "level", "autostart"])
p.add_argument("tag")
a = p.parse_args()
if not re.fullmatch(r"[A-Za-z0-9_-]+", a.tag):
    p.error("Fresh ASCII evidence tag required")
root = Path(__file__).resolve().parents[2]
directory = root / "godot-logs/showcase-delivery-20261025"
directory.mkdir(exist_ok=True)
base = directory / a.tag
if base.with_suffix(".json").exists():
    raise SystemExit("Existing evidence; choose a fresh tag")
command = ["E:/godot/Godot_v4.4.1-stable_win64_console.exe", "--path", str(root / "godot-racer"),
           "--log-file", str(base) + ".engine.log", "--audio-driver", "WASAPI", "--verbose"]
command += ["--rendering-method", "forward_plus"] if a.mode == "matrix" else ["--display-driver", "headless"]
command += ["--script", "res://tests/showcase_delivery_probe.gd", "--", "--delivery=" + a.mode, "--tag=" + a.tag]
if a.mode == "check": command += ["--check=menu-route-fixture"]
elif a.mode == "level": command += ["--level=2"]
elif a.mode == "autostart": command += ["--autostart=2"]
try:
    result = subprocess.run(command, capture_output=True, timeout=35)
    output, code = result.stdout + result.stderr, result.returncode
except subprocess.TimeoutExpired as exc:
    output, code = (exc.stdout or b"") + (exc.stderr or b""), 124
Path(str(base) + ".log").write_bytes(output)
engine = Path(str(base) + ".engine.log")
log = engine.read_text(encoding="utf-8", errors="replace") if engine.exists() else output.decode(errors="replace")
complete = re.search(r"DELIVERY_COMPLETE MODE=" + a.mode + r" PASS=(\d+) FAIL=(\d+)", log)
errors = re.findall(r"SCRIPT ERROR|ERROR:|Leaked instance|Resource still in use|ObjectDB instances leaked", log)
passed = code == 0 and complete is not None and int(complete[1]) > 0 and complete[2] == "0" and not errors
sources = ["menu", "homepage", "car_showcase", "showcase_podium", "showcase_intro", "menu_music", "game_state"]
data = {"command": command, "exit": code, "complete": complete[0] if complete else None,
        "errors": errors, "passed": passed,
        "source_sha256s": {name: hashlib.sha256((root / "godot-racer/scripts" / (name + ".gd")).read_bytes()).hexdigest() for name in sources}}
base.with_suffix(".json").write_text(json.dumps(data, indent=2), encoding="utf-8")
for line in log.splitlines():
    if re.search(r"DELIVERY_|MENU_AUDIO|SCRIPT ERROR|ERROR:|Leaked instance", line): print(line)
print("PROCESS_EXIT", code, "HARNESS", "PASS" if passed else "FAIL")
raise SystemExit(0 if passed else 1)
