"""Bounded audio-only OGG lifecycle diagnosis; complete + exit + leak gates."""
import argparse
import hashlib
import json
import re
import subprocess
import time
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("mode", choices=["shutdown", "free", "confirm", "tree_exit", "cancel", "legacy_timer",
                                "coordinated", "timeout", "rapid", "state_confirm", "state_window",
                                "state_cli", "state_menu_cli", "state_timeout", "showcase_cleanup",
                                "interactions_music"])
p.add_argument("tag")
p.add_argument("--driver", choices=["WASAPI", "Dummy"], default="WASAPI")
p.add_argument("--frame-delay", type=int, default=0)
p.add_argument("--graphics", action="store_true")
a = p.parse_args()
if not 0 <= a.frame_delay <= 500:
    p.error("Diagnostic frame delay must be in 0..500 ms")
if not re.fullmatch(r"[A-Za-z0-9_-]+", a.tag):
    p.error("Tag must contain only letters, digits, underscores and hyphens")
if a.mode == "state_menu_cli" and not a.graphics:
    p.error("Real menu screenshot exit requires --graphics")
root = Path(__file__).resolve().parents[2]
base = root / "godot-logs/ogg-exit-20261024" / a.tag
base.parent.mkdir(exist_ok=True)
if base.with_suffix(".json").exists():
    raise SystemExit("Existing evidence; choose a fresh tag")
cmd = ["E:/godot/Godot_v4.4.1-stable_win64_console.exe", "--path", str(root / "godot-racer"),
       "--log-file", str(base) + ".engine.log", "--audio-driver", a.driver, "--verbose"]
cmd += ["--rendering-method", "forward_plus", "--resolution", "1366x705"] if a.graphics else [
    "--display-driver", "headless"]
script = {"showcase_cleanup": "showcase_contract.gd", "interactions_music": "menu_interactions_test.gd"}.get(
    a.mode, "menu_music_lifecycle_probe.gd")
cmd += ["--script", "res://tests/" + script, "--", "--mode=" + a.mode, "--tag=" + a.tag,
        "--driver=" + a.driver, "--case=cleanup", "--interaction=music"]
if a.frame_delay:
    cmd[1:1] = ["--frame-delay", str(a.frame_delay)]
if a.mode == "state_cli":
    cmd.append("--shot-menu")
start = time.monotonic()
shot = root / "godot-logs/menu.png"
previous_shot = shot.read_bytes() if a.mode == "state_menu_cli" and shot.exists() else None
try:
    result = subprocess.run(cmd, capture_output=True, timeout=35)
    output, code = result.stdout + result.stderr, result.returncode
except subprocess.TimeoutExpired as exc:
    output, code = (exc.stdout or b"") + (exc.stderr or b""), 124
finally:
    if a.mode == "state_menu_cli" and shot.exists():
        Path(str(base) + ".png").write_bytes(shot.read_bytes())
        if previous_shot is not None:
            shot.write_bytes(previous_shot)
Path(str(base) + ".log").write_bytes(output)
engine = Path(str(base) + ".engine.log")
log = engine.read_text(encoding="utf-8", errors="replace") if engine.exists() else output.decode(errors="replace")
pattern = {"showcase_cleanup": r"SHOWCASE_COMPLETE CASE=cleanup", "interactions_music": r"INTERACTION_DONE KIND=music"}.get(
    a.mode, r"OGG_COMPLETE MODE=" + re.escape(a.mode))
complete = re.search(pattern + r" PASS=(\d+) FAIL=(\d+)", log)
errors = re.findall(r"SCRIPT ERROR|ERROR:|Leaked instance|Resource still in use|ObjectDB instances leaked", log)
passed = code == 0 and complete is not None and int(complete[1]) > 0 and complete[2] == "0" and not errors
screenshot_ok = None
if a.mode == "state_menu_cli":
    screenshot = Path(str(base) + ".png")
    screenshot_ok = "save_png -> 0" in log and screenshot.exists() and screenshot.read_bytes().startswith(
        b"\x89PNG\r\n\x1a\n")
    passed = passed and screenshot_ok
source = root / "godot-racer/scripts/menu_music.gd"
data = {"command": cmd, "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "source_sha256s": {str(f.relative_to(root)): hashlib.sha256(f.read_bytes()).hexdigest() for f in [
            source, root / "godot-racer/scripts/game_state.gd", root / "godot-racer/scripts/menu.gd",
            root / "godot-racer/tests" / script]},
        "exit": code, "seconds": round(time.monotonic() - start, 3),
        "complete": complete[0] if complete else None, "errors": errors, "passed": passed,
        "screenshot_ok": screenshot_ok}
base.with_suffix(".json").write_text(json.dumps(data, indent=2), encoding="utf-8")
for line in log.splitlines():
    if re.search(r"OGG_|AUDIO_DRAIN|MENU_AUDIO_EXIT|SHOWCASE_|INT_music|INTERACTION_DONE|菜单截图|SCRIPT ERROR|ERROR:|Leaked instance|Resource still in use", line):
        print(line)
print("PROCESS_EXIT", code, "HARNESS", "PASS" if passed else "FAIL", "LOG", base.name)
raise SystemExit(0 if passed else 1)
