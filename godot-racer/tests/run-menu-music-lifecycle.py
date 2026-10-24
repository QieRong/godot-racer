"""Bounded audio-only OGG lifecycle diagnosis; complete + exit + leak gates."""
import argparse
import hashlib
import json
import re
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("mode", choices=["shutdown", "free", "confirm", "tree_exit", "cancel", "legacy_timer"])
p.add_argument("tag")
p.add_argument("--driver", choices=["WASAPI", "Dummy"], default="WASAPI")
p.add_argument("--frame-delay", type=int, default=0)
a = p.parse_args()
if not 0 <= a.frame_delay <= 500:
    p.error("Diagnostic frame delay must be in 0..500 ms")
if not re.fullmatch(r"[A-Za-z0-9_-]+", a.tag):
    p.error("Tag must contain only letters, digits, underscores and hyphens")
root = Path(__file__).resolve().parents[2]
base = root / "godot-logs/ogg-exit-20261024" / a.tag
base.parent.mkdir(exist_ok=True)
if base.with_suffix(".json").exists():
    raise SystemExit("Existing evidence; choose a fresh tag")
cmd = ["E:/godot/Godot_v4.4.1-stable_win64_console.exe", "--path", str(root / "godot-racer"),
       "--log-file", str(base) + ".engine.log", "--display-driver", "headless",
       "--audio-driver", a.driver, "--verbose", "--script", "res://tests/menu_music_lifecycle_probe.gd",
       "--", "--mode=" + a.mode, "--tag=" + a.tag, "--driver=" + a.driver]
if a.frame_delay:
    cmd[1:1] = ["--frame-delay", str(a.frame_delay)]
start = time.monotonic()
try:
    result = subprocess.run(cmd, capture_output=True, timeout=35)
    output, code = result.stdout + result.stderr, result.returncode
except subprocess.TimeoutExpired as exc:
    output, code = (exc.stdout or b"") + (exc.stderr or b""), 124
Path(str(base) + ".log").write_bytes(output)
engine = Path(str(base) + ".engine.log")
log = engine.read_text(encoding="utf-8", errors="replace") if engine.exists() else output.decode(errors="replace")
complete = re.search(r"OGG_COMPLETE MODE=\w+ PASS=(\d+) FAIL=(\d+)", log)
errors = re.findall(r"SCRIPT ERROR|ERROR:|Leaked instance|Resource still in use|ObjectDB instances leaked", log)
passed = code == 0 and complete is not None and int(complete[1]) > 0 and complete[2] == "0" and not errors
source = root / "godot-racer/scripts/menu_music.gd"
data = {"command": cmd, "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "exit": code, "seconds": round(time.monotonic() - start, 3),
        "complete": complete[0] if complete else None, "errors": errors, "passed": passed}
base.with_suffix(".json").write_text(json.dumps(data, indent=2), encoding="utf-8")
for line in log.splitlines():
    if re.search(r"OGG_|AUDIO_DRAIN|SCRIPT ERROR|ERROR:|Leaked instance|Resource still in use", line):
        print(line)
print("PROCESS_EXIT", code, "HARNESS", "PASS" if passed else "FAIL", "LOG", base.name)
raise SystemExit(0 if passed else 1)
