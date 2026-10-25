"""Run one short interaction case with a real exit code and immutable log name."""
import argparse
import json
import re
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("case", choices=["selection", "showcase", "music", "pages", "preview", "capture"])
p.add_argument("tag")
p.add_argument("--graphics", action="store_true")
p.add_argument("--verbose", action="store_true")
p.add_argument("--renderer", default="gl_compatibility")
p.add_argument("--audio-driver", choices=["WASAPI", "Dummy"])
p.add_argument("--kind", default="home")
p.add_argument("--size", default="1366x705")
a = p.parse_args()
root = Path(__file__).resolve().parents[2]
base = root / "godot-logs" / f"int-{a.case}-{a.tag}"
if base.with_suffix(".exit.json").exists():
    raise SystemExit("Log already exists; choose a new tag")
script = {"pages": "ui_pages_test.gd", "preview": "ui_pages_preview.gd", "capture": "interaction_capture.gd"}.get(a.case, "menu_interactions_test.gd")
cmd = ["E:/godot/Godot_v4.4.1-stable_win64_console.exe", "--path", str(root / "godot-racer"),
       "--log-file", str(base) + ".engine.log"]
cmd += ["--rendering-method", a.renderer, "--resolution", a.size] if a.graphics else (
    ["--display-driver", "headless"] if a.audio_driver else ["--headless"])
if a.audio_driver:
    cmd += ["--audio-driver", a.audio_driver]
if a.verbose:
    cmd.append("--verbose")
cmd += ["--script", "res://tests/" + script, "--", "--interaction=" + a.case,
        "--ui-preview=" + a.kind, "--ui-size=" + a.size,
        "--capture-kind=" + a.kind, "--capture-size=" + a.size]
start = time.monotonic()
try:
    result = subprocess.run(cmd, capture_output=True, timeout=29)
    output, code = result.stdout + result.stderr, result.returncode
except subprocess.TimeoutExpired as exc:
    output, code = (exc.stdout or b"") + (exc.stderr or b""), 124
Path(str(base) + ".log").write_bytes(output)
engine = Path(str(base) + ".engine.log")
log = engine.read_text(encoding="utf-8", errors="replace") if engine.exists() else output.decode("gb18030", errors="replace")
summary = [line for line in log.splitlines() if re.search(r"(?:DONE|SAVE=|FRAME_MS|PREVIEW_PHASE|SCRIPT ERROR|ERROR:|FAIL |Resource still in use|Leaked instance)", line)]
pattern = (r"UI_RUNTIME_DONE" if a.case == "pages" else
           r"INTERACTION_DONE KIND=" + re.escape(a.case)) + r" PASS=(\d+) FAIL=(\d+)"
complete = re.search(pattern, log)
errors = re.findall(r"SCRIPT ERROR|ERROR:|Leaked instance|Resource still in use|ObjectDB instances leaked", log)
assertion_case = a.case in ["pages", "selection", "showcase", "music"]
passed = code == 0 and not errors and (not assertion_case or
    (complete is not None and int(complete[1]) > 0 and complete[2] == "0"))
data = {"exit": code, "seconds": round(time.monotonic() - start, 3), "command": cmd,
        "script_errors": log.count("SCRIPT ERROR"), "errors": log.count("ERROR:"),
        "error_matches": errors, "complete": complete[0] if complete else None, "passed": passed}
Path(str(base) + ".exit.json").write_text(json.dumps(data, indent=2), encoding="utf-8")
for line in summary:
    print(line)
print("PROCESS_EXIT", code, "HARNESS", "PASS" if passed else "FAIL", "SECONDS", data["seconds"], "LOG", base.name)
raise SystemExit(0 if passed else 1)
