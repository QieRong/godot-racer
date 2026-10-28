"""Bounded Forward+ cursor verification; final exit, assertions and leaks gate PASS."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("case", choices=["theme", "visibility"])
parser.add_argument("tag")
parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument("--output", type=Path,
                    default=Path(__file__).resolve().parents[2] / "godot-logs/cursor-theme-20261026")
args = parser.parse_args()
if not re.fullmatch(r"[A-Za-z0-9_-]+", args.tag):
    parser.error("ASCII evidence tag required")
args.output.mkdir(parents=True, exist_ok=True)
base = args.output.resolve() / args.tag
if any(args.output.glob(args.tag + ".*")):
    raise SystemExit("Existing evidence; choose a fresh tag")
script = "cursor_theme_test.gd" if args.case == "theme" else "cursor_visibility_test.gd"
marker = "CURSOR_COMPLETE" if args.case == "theme" else "CURSOR_VISIBILITY_COMPLETE"
command = ["E:/godot/Godot_v4.4.1-stable_win64_console.exe", "--path", str(args.project.resolve()),
           "--rendering-method", "forward_plus", "--audio-driver", "WASAPI",
           "--log-file", str(base) + ".engine.log", "--script", "res://tests/" + script, "--", "--aioff"]
try:
    result = subprocess.run(command, capture_output=True, timeout=45)
    output, code = result.stdout + result.stderr, result.returncode
except subprocess.TimeoutExpired as exc:
    output, code = (exc.stdout or b"") + (exc.stderr or b""), 124
Path(str(base) + ".log").write_bytes(output)
engine = Path(str(base) + ".engine.log")
log = engine.read_text(encoding="utf-8", errors="replace") if engine.exists() else output.decode(errors="replace")
complete = re.search(marker + r" PASS=(\d+) FAIL=(\d+)", log)
errors = [line for line in log.splitlines() if re.search(
    r"SCRIPT ERROR|ERROR:|leaked|still in use|Unreferenced StringName", line, re.I)]
failures = [line for line in log.splitlines() if re.search(r"CURSOR.*ASSERT FAIL", line)]
passed = (code == 0 and complete is not None and int(complete[1]) > 0 and complete[2] == "0"
          and not errors and not failures)
data = {"command": command, "exit": code, "complete": complete[0] if complete else None,
        "errors_or_leaks": errors, "failed_assertions": failures, "passed": passed}
base.with_suffix(".json").write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
for line in log.splitlines():
    if "CURSOR" in line or line in errors:
        print(line)
print("PROCESS_EXIT", code, "HARNESS", "PASS" if passed else "FAIL")
raise SystemExit(0 if passed else 1)
