"""Exercise the real screenshot gate before and after publishing its baseline."""
import argparse
import ast
import re
import subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--source", type=Path, default=Path(__file__).with_name("check-ui-pages.py"))
a = p.parse_args()
tree = ast.parse(a.source.read_text(encoding="utf-8-sig"))
helper = next(n for n in tree.body if isinstance(n, ast.FunctionDef)
              and n.name == "menu_shot_audio_cleanup_only")
loop = next(n for n in tree.body if isinstance(n, ast.For)
            and isinstance(n.target, ast.Name) and n.target.id == "func")
loop.iter = ast.Tuple(elts=[ast.Constant("_shot_menu_after")], ctx=ast.Load())
code = compile(ast.fix_missing_locations(ast.Module(body=[helper, loop], type_ignores=[])),
               str(a.source), "exec")
root = Path(__file__).resolve().parents[2]
old = subprocess.check_output(["git", "show", "8f6049d:godot-racer/scripts/menu.gd"], cwd=root).decode()
new = (root / "godot-racer/scripts/menu.gd").read_text(encoding="utf-8-sig")
assert "await GameState.quit_after_menu_audio()" in new
cases = [
    ("approved old-to-new migration", old, new, True),
    ("published new baseline unchanged", new, new, True),
    ("published baseline frame drift", new, new.replace("maxi(1, frames)", "maxi(2, frames)"), False),
    ("published baseline path drift", new, new.replace('path_join("menu.png")', 'path_join("other.png")'), False),
    ("published baseline save removed", new, new.replace("img.save_png(out)", "OK"), False),
    ("published baseline exit removed", new, new.replace("await GameState.quit_after_menu_audio()", "pass"), False),
    ("reversed migration rejected", new, old, False),
    ("missing before function rejected", "", new, False),
    ("missing after function rejected", new, "", False),
]
passed = 0
for name, before, after, expected in cases:
    results = []
    exec(code, {"re": re, "old_menu": before, "menu": after,
                "check": lambda key, ok, detail: results.append(bool(ok))})
    ok = results == [expected]
    passed += ok
    print(("PASS " if ok else "FAIL ") + name)
print("PUBLICATION_CONTRACT_COMPLETE PASS=%d FAIL=%d" % (passed, len(cases) - passed))
raise SystemExit(0 if passed == len(cases) else 1)
