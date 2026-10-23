"""Exercise the real protected-source gate against isolated Git changes."""
from pathlib import Path
import argparse
import ast
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=Path(__file__).with_name("check-ui-pages.py"),
                    help="Checker source containing the HEAD protected list (before pending UI edits)")
args = parser.parse_args()
module = ast.parse(args.source.read_text(encoding="utf-8-sig"))
helper = next(n for n in module.body if isinstance(n, ast.FunctionDef)
              and n.name == "menu_uid_metadata_only")
start = next(i for i, n in enumerate(module.body) if isinstance(n, ast.Assign)
             and any(isinstance(t, ast.Name) and t.id == "protected" for t in n.targets))
end = next(i for i in range(start, len(module.body)) if isinstance(module.body[i], ast.Expr)
           and isinstance(module.body[i].value, ast.Call)
           and isinstance(module.body[i].value.func, ast.Name)
           and module.body[i].value.func.id == "check")
# Execute original helper and gate statements, including real git return codes and path discovery.
code = compile(ast.Module(body=[helper, *module.body[start:end+1]], type_ignores=[]), str(args.source), "exec")
contract = ast.parse(Path(__file__).with_name("menu_uid_guard_test.py").read_text(encoding="utf-8"))
fixtures = {n.targets[0].id: ast.literal_eval(n.value) for n in contract.body
            if isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name)
            and n.targets[0].id in ("before", "after")}
menu_path = "godot-racer/scenes/menu.tscn"
uid_path = "godot-racer/scripts/menu.gd.uid"
uid = "uid://dpi8hmjv8cegm"
cases = [
    ("unchanged protected sources", {}, True),
    ("approved metadata only", {menu_path: fixtures["after"]}, True),
    ("unknown scene UID", {menu_path: fixtures["after"].replace("dqocqawofnujo", "aaaaaaaaaaaaa")}, False),
    ("script sidecar drift", {menu_path: fixtures["after"], uid_path: "uid://aaaaaaaaaaaaa"}, False),
    ("scene node changed", {menu_path: fixtures["after"].replace('name="Menu"', 'name="Changed"')}, False),
    ("additional protected scene", {menu_path: fixtures["after"], "godot-racer/scenes/main.tscn": "changed"}, False),
    ("additional vehicle source", {menu_path: fixtures["after"], "godot-racer/scripts/vehicle.gd": "changed"}, False),
    ("original project protection retained", {menu_path: fixtures["after"], "godot-racer/project.godot": "changed"}, False),
    ("missing Git HEAD", None, False),
]
passed = 0
with tempfile.TemporaryDirectory(prefix="menu-uid-guard-") as directory:
    root = Path(directory)
    def git(*arguments):
        return subprocess.run(["git", "-c", "core.autocrlf=false", *arguments], cwd=root,
                              capture_output=True, check=True)
    def write(name, value):
        target = root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(value, encoding="utf-8")
    git("init", "--quiet")
    git("config", "core.autocrlf", "false")
    baseline = {menu_path: fixtures["before"], uid_path: uid,
                "godot-racer/scenes/main.tscn": "baseline scene",
                "godot-racer/scripts/vehicle.gd": "baseline vehicle",
                "godot-racer/project.godot": "baseline project"}
    for name, content in baseline.items():
        write(name, content)
    git("add", "--", *baseline)
    git("-c", "user.name=UID Contract", "-c", "user.email=uid-contract@example.invalid",
        "commit", "--quiet", "-m", "isolated fixture")
    for label, changes, want in cases:
        for name, content in baseline.items():
            write(name, content)
        if changes is None:
            # Move only the fixture's HEAD to an unborn branch, so Git fails without a baseline.
            git("symbolic-ref", "HEAD", "refs/heads/unborn")
        else:
            for name, content in changes.items():
                write(name, content)
        outcomes = []
        namespace = {"ROOT": root, "subprocess": subprocess,
                     "read": lambda name: (root / "godot-racer" / name).read_text(encoding="utf-8"),
                     "check": lambda key, value, detail: outcomes.append(value)}
        exec(code, namespace)
        ok = len(outcomes) == 1 and outcomes[0] is want
        passed += ok
        print(("PASS " if ok else "FAIL ") + label)
print("UID_INTEGRATION_SUMMARY pass=%d fail=%d" % (passed, len(cases) - passed))
raise SystemExit(0 if passed == len(cases) else 1)
