"""Bounded Godot showcase runner. Exit, completion marker and errors all gate PASS."""
import argparse
import json
import re
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("case", choices=["p0", "perf", "gaps", "art", "intro", "logo", "capture"])
p.add_argument("tag")
p.add_argument("--size", default="1366x705")
p.add_argument("--graphics", action="store_true")
p.add_argument("--renderer", default="gl_compatibility")
p.add_argument("--variant", default="current", choices=["current", "original", "no_shadows", "no_pick", "no_podium", "reduced_viewport"])
p.add_argument("--verbose", action="store_true")
p.add_argument("--accurate-breadcrumbs", action="store_true")
p.add_argument("--movie", action="store_true")
a = p.parse_args()
if a.variant in ["no_pick", "no_podium", "reduced_viewport"] and a.case != "perf":
    p.error("Diagnostic variants are restricted to perf")
root = Path(__file__).resolve().parents[2]
base = root / "godot-logs" / "showcase-20261023" / a.tag
base.parent.mkdir(exist_ok=True)
if base.with_suffix(".json").exists():
    raise SystemExit("Existing evidence; use a fresh tag")
cmd = ["E:/godot/Godot_v4.4.1-stable_win64_console.exe", "--path", str(root / "godot-racer"),
       "--log-file", str(base) + ".engine.log"]
cmd += ["--rendering-method", a.renderer, "--resolution", a.size] if a.graphics else ["--headless"]
if a.verbose: cmd += ["--verbose"]
if a.accurate_breadcrumbs: cmd += ["--accurate-breadcrumbs"]
if a.movie:
    if not a.graphics: raise SystemExit("Movie requires --graphics")
    cmd += ["--write-movie", str(base) + ".avi", "--fixed-fps", "60"]
cmd += ["--script", "res://tests/showcase_contract.gd", "--", "--case=" + a.case,
        "--tag=" + a.tag, "--size=" + a.size, "--variant=" + a.variant]
start = time.monotonic()
try:
    result = subprocess.run(cmd, capture_output=True, timeout=55)
    output, code = result.stdout + result.stderr, result.returncode
except subprocess.TimeoutExpired as exc:
    output, code = (exc.stdout or b"") + (exc.stderr or b""), 124
Path(str(base) + ".log").write_bytes(output)
engine = Path(str(base) + ".engine.log")
log = engine.read_text(encoding="utf-8", errors="replace") if engine.exists() else output.decode(errors="replace")
complete = re.search(r"SHOWCASE_COMPLETE CASE=\w+ PASS=(\d+) FAIL=(\d+)", log)
errors = re.findall(r"SCRIPT ERROR|ERROR:|Leaked instance|Resource still in use|ObjectDB instances leaked", log)
passed = code == 0 and complete is not None and int(complete[1]) > 0 and complete[2] == "0" and not errors
data = {"command": cmd, "exit": code, "seconds": round(time.monotonic() - start, 3),
        "complete": complete[0] if complete else None, "errors": errors, "passed": passed}
Path(str(base) + ".json").write_text(json.dumps(data, indent=2), encoding="utf-8")
selected = [line for line in log.splitlines() if re.search(r"SHOWCASE_|SCRIPT ERROR|ERROR:|at:", line)]
for line in selected[:70]: print(line)
if len(selected) > 70: print("Additional diagnostic lines retained in log:", len(selected) - 70)
print("PROCESS_EXIT", code, "HARNESS", "PASS" if passed else "FAIL", "LOG", str(base))
raise SystemExit(0 if passed else 1)
