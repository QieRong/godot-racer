"""Adverse controls for the two approved menu audio contract migrations."""
import ast
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = Path(__file__).with_name("check-ui-pages.py")
tree = ast.parse(source.read_text(encoding="utf-8-sig"))
names = {"menu_audio_exit_only", "menu_shot_audio_cleanup_only"}
functions = [node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name in names]
if len(functions) != len(names):
    print("MIGRATION_GUARD_COMPLETE PASS=0 FAIL=2 missing exact approved predicates")
    raise SystemExit(1)
namespace = {}
exec(compile(ast.Module(body=functions, type_ignores=[]), str(source), "exec"), namespace)
audio = namespace["menu_audio_exit_only"]
shot = namespace["menu_shot_audio_cleanup_only"]

# Reconstruct the approved candidate from its committed delta, independently of dirty source.
fixture = root / "godot-logs/ui-contract-20261024/guard-fixture"
fixture.mkdir(parents=True, exist_ok=True)
subprocess.run(["git", "init", "--quiet", str(fixture)], check=True)
relative = "godot-racer/scripts/game_state.gd"
before = subprocess.check_output(["git", "show", "8f6049d:" + relative], cwd=root).decode().replace("\r\n", "\n")
target = fixture / relative
target.parent.mkdir(parents=True, exist_ok=True)
target.write_bytes(before.encode())
patch = root / "plan/showcase-ogg-fix-evidence-20261024/menu-ogg-exit-fix.patch"
subprocess.run(["git", "-C", str(fixture), "apply", "--include=" + relative, str(patch)], check=True)
after = target.read_text(encoding="utf-8")
old_shot = ["func _shot_menu_after(frames: int) -> void:", "for i in range(maxi(1, frames)):",
            "await get_tree().process_frame", "var img := get_viewport().get_texture().get_image()",
            "var out := original_path", "var err := img.save_png(out)", "print(err)",
            "await get_tree().process_frame", "get_tree().quit()"]
new_shot = old_shot[:-2] + ["await GameState.quit_after_menu_audio()"]
cases = [
    ("exact approved audio repair", audio(before, after), True),
    ("equivalent CRLF serialization", audio(before.replace("\n", "\r\n"), after), True),
    ("unknown baseline", audio(before + "\n", after), False),
    ("clock drift", audio(before, after.replace("var race_start_ms := 0", "var race_start_ms := 1")), False),
    ("extra source", audio(before, after + "var extra = 1\n"), False),
    ("removed exit lock", audio(before, after.replace("_exit_in_progress = true", "_exit_in_progress = false")), False),
    ("unchanged source is not an exception", audio(before, before), False),
    ("reversed transition", audio(after, before), False),
    ("exact screenshot footer migration", shot(old_shot, new_shot), True),
    ("capture frame drift", shot(old_shot, [line.replace("maxi(1, frames)", "maxi(2, frames)") for line in new_shot]), False),
    ("output path drift", shot(old_shot, [line.replace("original_path", "other_path") for line in new_shot]), False),
    ("save removed", shot(old_shot, [line for line in new_shot if "save_png" not in line]), False),
    ("unawaited cleanup", shot(old_shot, new_shot[:-1] + ["GameState.quit_after_menu_audio()"]), False),
    ("extra command", shot(old_shot, new_shot + ["get_tree().quit()"]), False),
    ("unknown original footer", shot(old_shot[:-1] + ["other_exit()"], new_shot), False),
    ("unchanged capture is not migrated", shot(old_shot, old_shot), False),
]
passed = 0
for label, actual, expected in cases:
    ok = actual is expected
    passed += ok
    print(("PASS " if ok else "FAIL ") + label)
print("MIGRATION_GUARD_COMPLETE PASS=%d FAIL=%d" % (passed, len(cases) - passed))
raise SystemExit(0 if passed == len(cases) else 1)
