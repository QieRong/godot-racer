"""Regression contract for the approved menu UID exception; no UI import side effects."""
from pathlib import Path
import argparse
import ast

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", type=Path, default=Path(__file__).with_name("check-ui-pages.py"))
args = parser.parse_args()
module = ast.parse(args.source.read_text(encoding="utf-8-sig"))
function = next((n for n in module.body if isinstance(n, ast.FunctionDef)
                 and n.name == "menu_uid_metadata_only"), None)
if function is None:
    print("FAIL missing approved menu UID predicate")
    print("UID_CONTRACT_SUMMARY pass=0 fail=1")
    raise SystemExit(1)
namespace = {}
exec(compile(ast.Module(body=[function], type_ignores=[]), str(args.source), "exec"), namespace)
check = namespace["menu_uid_metadata_only"]
# Literal fixtures remain independent of Git HEAD and ignored evidence directories.
before = '[gd_scene load_steps=2 format=3 uid="uid://cmenu0000000001"]\n\n[ext_resource type="Script" path="res://scripts/menu.gd" id="1_menu"]\n\n[node name="Menu" type="Control"]\nlayout_mode = 3\nanchors_preset = 15\nanchor_right = 1.0\nanchor_bottom = 1.0\ngrow_horizontal = 2\ngrow_vertical = 2\nscript = ExtResource("1_menu")\n'
after = '[gd_scene load_steps=2 format=3 uid="uid://dqocqawofnujo"]\n\n[ext_resource type="Script" uid="uid://dpi8hmjv8cegm" path="res://scripts/menu.gd" id="1_menu"]\n\n[node name="Menu" type="Control"]\nlayout_mode = 3\nanchors_preset = 15\nanchor_right = 1.0\nanchor_bottom = 1.0\ngrow_horizontal = 2\ngrow_vertical = 2\nscript = ExtResource("1_menu")\n'
paths=['godot-racer/scenes/menu.tscn']; uid='uid://dpi8hmjv8cegm'
cases=[
 ('exact verified metadata',paths,before,after,uid,True),
 ('CRLF input same exact metadata',paths,before.replace('\n','\r\n'),after,uid,True),
 ('other scene UID',paths,before,after.replace('dqocqawofnujo','aaaaaaaaaaaaa'),uid,False),
 ('other script UID',paths,before,after.replace('dpi8hmjv8cegm','aaaaaaaaaaaaa'),uid,False),
 ('sidecar UID drift',paths,before,after,'uid://aaaaaaaaaaaaa',False),
 ('node name changed',paths,before,after.replace('name="Menu"','name="Changed"'),uid,False),
 ('layout changed',paths,before,after.replace('layout_mode = 3','layout_mode = 1'),uid,False),
 ('resource path changed',paths,before,after.replace('res://scripts/menu.gd','res://scripts/other.gd'),uid,False),
 ('script binding changed',paths,before,after.replace('script = ExtResource("1_menu")','script = null'),uid,False),
 ('load steps changed',paths,before,after.replace('load_steps=2','load_steps=3'),uid,False),
 ('extra property',paths,before,after+'visible = false\n',uid,False),
 ('removed node',paths,before,after.replace('[node name="Menu" type="Control"]\n',''),uid,False),
 ('blank line drift',paths,before,after+'\n',uid,False),
 ('additional protected scene',paths+['godot-racer/scenes/main.tscn'],before,after,uid,False),
 ('additional vehicle source',paths+['godot-racer/scripts/vehicle.gd'],before,after,uid,False),
 ('wrong protected path',['godot-racer/scenes/main.tscn'],before,after,uid,False),
 ('missing changed path',[],before,after,uid,False),
 ('unknown baseline UID',paths,before.replace('cmenu0000000001','unknown'),after,uid,False),
 ('missing baseline resource',paths,before.replace('res://scripts/menu.gd','res://scripts/other.gd'),after,uid,False),
 ('unchanged scene not an exception',paths,before,before,uid,False),
]
results = []
for label, paths, before, after, uid, want in cases:
    actual = check(paths, before, after, uid)
    ok = actual is want
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + label)
print("UID_CONTRACT_SUMMARY pass=%d fail=%d" % (sum(results), len(results) - sum(results)))
raise SystemExit(0 if len(results) == 20 and all(results) else 1)
