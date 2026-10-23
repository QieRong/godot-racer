"""UI-20261020 秒级源码自测；不替代引擎和真人验收。"""
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PROJ = ROOT / "godot-racer"
results = []


def check(key, value, detail):
    results.append(bool(value))
    print(f"{key} {'PASS' if value else 'FAIL'} {detail}")


def read(name):
    path = PROJ / name
    return path.read_text(encoding="utf-8-sig") if path.exists() else ""


menu = read("scripts/menu.gd")
cd = read("scripts/start_countdown.gd")
finish = read("scripts/finish_menu.gd")
hud = read("scripts/hud.gd")
theme = read("scripts/ui_theme.gd")
modal = read("scripts/menu_overlay.gd")
check("MENU-01", all(f'"{n}"' in menu for n in (
    "StartButton", "SettingsButton", "HelpButton", "ExitButton")), "真实入口命名")
check("MENU-08", all(n in menu for n in (
    '--check=', '--level=', '--autostart=', '--shot-menu',
    '_enter_game.call_deferred()', '_shot_menu_after', '_autostart_after')),
    "CLI分支与辅助路径保留")
old_menu = subprocess.check_output(
    ["git", "show", "HEAD:godot-racer/scripts/menu.gd"], cwd=ROOT).decode("utf-8")
for func in ("_ready", "_shot_menu_after", "_autostart_after"):
    pattern = rf"func {func}\(.*?(?=\nfunc |\Z)"
    before = re.search(pattern, old_menu, re.S)
    after = re.search(pattern, menu, re.S)
    # 注释不影响原CLI协程；逐代码行检查其行为保持不变。
    code = lambda m: [s.strip() for s in m.group().splitlines()
                      if s.strip() and not s.lstrip().startswith('#')] if m else []
    check("MENU-08", bool(before and after) and code(before) == code(after), func)
check("CD-01", 'const COUNTDOWN_SECONDS := 3.0' in cd and
      'const GO_HOLD_SECONDS := 0.5' in cd and
      cd.find('finished.emit()') < cd.find('_elapsed >= COUNTDOWN_SECONDS + GO_HOLD_SECONDS'),
      "3秒发车与0.5秒收旗分离")
check("CD-05", 'create_tween()' in cd and 'await ' not in cd,
      "数字Tween不等待发车")
check("FIN-05", all(x in finish for x in (
    'GameState.back_to_menu', 'GameState.restart_race', 'GameState.request_exit',
    '返回主菜单（ESC）', '再玩一局', '退出游戏')), "结算三个真实出口")
check("HUD-02", '"outline_size", 6' in hud and
      'car.call("current_lap_time")' in hud and 'GameState.race_total_time()' in hud,
      "逆行描边与读数来源保留")
check("UI-01", bool(theme and modal) and all('class_name ' not in s for s in (theme, modal)),
      "共享令牌与独立弹层模块")
check("UI-01", all('await ' not in s for s in (theme, modal, finish)), "新增界面无协程")
# 帮助页键位必须来自 InputMap，不得硬编码（否则改键位后说明变成假数据）。
check("HELP-01", 'InputMap.action_get_events' in modal and 'OS.get_keycode_string' in modal,
      "帮助页键位从InputMap读取")
check("HELP-01", not any(k in modal for k in (
    "W 油门", "S 刹车/倒车", "A / D 转向", "空格 手刹", "V 切换视角", "M 显示/隐藏小地图",
    "鼠标右键环视")), "帮助页无硬编码键位字面量")
check("HELP-02", '_binding("reset"' in modal and "复位脱困" in modal, "帮助页含复位脱困键")
for act in ("accelerate", "brake_reverse", "steer_left", "steer_right", "handbrake",
            "reset", "camera_view", "camera_orbit", "toggle_minimap"):
    check("HELP-02", f'_binding("{act}"' in modal, f"帮助页覆盖动作 {act}")
for name in ("menu.gd", "start_countdown.gd", "finish_menu.gd", "hud.gd",
             "ui_theme.gd", "menu_overlay.gd"):
    src = read(f"scripts/{name}")
    check("UI-01", bool(src) and len(src.splitlines()) <= 1000,
          f"{name} lines={len(src.splitlines())}")
for name in ("ui_pages_test.gd", "ui_pages_preview.gd"):
    src = read(f"tests/{name}")
    check("UI-01", bool(src) and len(src.splitlines()) <= 1000,
          f"{name} lines={len(src.splitlines())}")
uids = {}
for path in PROJ.rglob("*.uid"):
    if ".godot" in path.parts or "addons" in path.parts:
        continue
    uids.setdefault(path.read_text(encoding="utf-8-sig").strip(), []).append(path)
for name in ("scripts/ui_theme.gd", "scripts/menu_overlay.gd", "tests/ui_pages_test.gd", "tests/ui_pages_preview.gd"):
    uid = read(name + ".uid").strip()
    check("UI-01", re.fullmatch(r"uid://[a-z0-9]{13}", uid) is not None and
          len(uids.get(uid, [])) == 1, f"{name} UID格式/唯一性")
def menu_uid_metadata_only(paths, before, after, script_uid):
    """Only the two verified Godot 4.4.1 UID serializations may differ."""
    if paths != ["godot-racer/scenes/menu.tscn"] or script_uid != "uid://dpi8hmjv8cegm":
        return False
    before = before.replace("\r\n", "\n")
    after = after.replace("\r\n", "\n")
    old_header = '[gd_scene load_steps=2 format=3 uid="uid://cmenu0000000001"]'
    new_header = '[gd_scene load_steps=2 format=3 uid="uid://dqocqawofnujo"]'
    old_script = '[ext_resource type="Script" path="res://scripts/menu.gd" id="1_menu"]'
    new_script = '[ext_resource type="Script" uid="uid://dpi8hmjv8cegm" path="res://scripts/menu.gd" id="1_menu"]'
    if not before.startswith(old_header + "\n") or before.count("\n" + old_script + "\n") != 1:
        return False
    expected = before.replace(old_header + "\n", new_header + "\n", 1)
    expected = expected.replace("\n" + old_script + "\n", "\n" + new_script + "\n", 1)
    return after == expected


protected = ["godot-racer/scenes/main.gd", "godot-racer/scripts/game_state.gd",
             "godot-racer/scripts/vehicle.gd", "godot-racer/scripts/ai_opponent.gd",
             "godot-racer/scripts/opponent_spawner.gd", "godot-racer/scripts/race_position.gd",
             "godot-racer/scripts/track_layout.gd", "godot-racer/scripts/racing_line.gd",
             "godot-racer/data/levels", "godot-racer/scenes", "godot-racer/project.godot"]
diff = subprocess.run(["git", "diff", "HEAD", "--exit-code", "--", *protected],
                      cwd=ROOT, capture_output=True)
changed = subprocess.run(["git", "diff", "HEAD", "--name-only", "-z", "--", *protected],
                         cwd=ROOT, capture_output=True)
paths = [p.decode("utf-8") for p in changed.stdout.split(b"\0") if p]
menu_before = subprocess.run(["git", "show", "HEAD:godot-racer/scenes/menu.tscn"],
                             cwd=ROOT, capture_output=True)
metadata_only = (diff.returncode == 1 and changed.returncode == 0 and menu_before.returncode == 0
                 and menu_uid_metadata_only(paths, menu_before.stdout.decode("utf-8"),
                                            read("scenes/menu.tscn"), read("scripts/menu.gd.uid").strip()))
check("CD-01", diff.returncode == 0 or metadata_only,
      "受保护源码保持原样；仅允许已核实的menu两处UID元数据序列化")
print(f"UI_SOURCE_DONE PASS={sum(results)} FAIL={len(results)-sum(results)}")
raise SystemExit(0 if all(results) else 1)
