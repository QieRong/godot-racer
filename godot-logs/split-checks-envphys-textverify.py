# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-ENVPHYS-004 转录保真核验器（独立于 _envphys_apply.py 的**反向**检查）。

思路（刻意不复用 _envphys_apply.py 的替换/删除代码，避免自证）：
  把 HEAD 态 main.gd 的**七处**原始块按顺序拼成"原文"，把 scripts/checks/env_phys.gd
  的迁移正文取出来做 diff；要求
    ① 归一化后（丢空行 / 丢段落横幅 `# ====` 与孤立 `#`）行数完全对应；
    ② 每一对"改动行"（a→b）都必须能用**文件头登记的 12 条替换之一**从 a 推出来；
    ③ 没有任何"未解释差异"。
  任何"看起来对但其实是顺手改的"漂移（多一个空格、文案改字、%占位换序、阈值改动、
  少搬/多搬一行）都会被 ②③ 抓到。

为什么与 split-checks-ai-textverify.py 不同：本族是**七段非连续块**（ai 是四段），
且模块里每段前都加了 `# ==== … ====` 段落横幅（ai 没有），所以归一化里额外丢掉横幅与
孤行 `#`；块之间也不再依赖"接缝空行"计数，而是统一丢空行后逐行比对。

用法：python godot-logs/split-checks-envphys-textverify.py
退出码：0 = 零漂移；1 = 有未解释差异。
"""
import difflib
import io
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOD = os.path.join(ROOT, "godot-racer", "scripts", "checks", "env_phys.gd")

# ---- 1. 取 HEAD 态 main.gd（用 git show，确保比对的是入库版本而不是被改后的工作区）
head_raw = subprocess.run(
    ["git", "-C", ROOT, "show", "HEAD:godot-racer/scenes/main.gd"],
    capture_output=True, check=True).stdout.decode("utf-8")
head = head_raw.replace("\r\n", "\n").split("\n")

# HEAD 态行号 = 迁移前（2578 行）；七处范围与 _envphys_apply.py 的 RANGES 逐一对应。
BLOCKS = [
    ("WALL", 431, 532),
    ("STUCK", 535, 643),
    ("PROBE", 655, 705),  # 705 止：HEAD L706-709 是「_probe_blocker 刻意留在本文件」的过期注记，随迁移作废、不进模块
    ("PHYS", 1134, 1200),
    ("WEATHER", 1349, 1434),
    ("FRIC", 1437, 1562),
    ("FLIP", 1574, 2026),
]
orig = []
for name, a, b in BLOCKS:
    orig.extend(head[a - 1:b])

# ---- 2. 取模块正文（从第一段横幅 `# ==== 卡墙验收` 起；上面的 header / 注入段 / setup 不算）
mod = io.open(MOD, "r", encoding="utf-8").read().replace("\r\n", "\n").split("\n")
try:
    i_start = next(i for i, l in enumerate(mod) if l.startswith("# ======================== 卡墙验收"))
    i_end = len(mod)
    while i_end > 0 and mod[i_end - 1].strip() == "":
        i_end -= 1
except StopIteration:
    print("!! 模块里找不到段落横幅锚 `# ==== 卡墙验收`")
    sys.exit(1)
actual = mod[i_start:i_end]

# ---- 3. 归一化：丢空行 + 丢段落横幅（`# ====` 起头）+ 丢孤立 `#`
def normalize(lines):
    out = []
    for l in lines:
        s = l.strip()
        if s == "":
            continue
        if s.startswith("# ====") or s == "#" or s.startswith("# ===="):
            continue
        out.append(l)
    return out

# ---- 4. 替换表（文件头决策 ①②③④ 登记的全部改写）
SUBS = [
    ("func _check_wallslide() -> void:", "func run_wallslide() -> void:"),
    ("func _check_stuck() -> void:", "func run_stuck() -> void:"),
    ("func _probe_blocker() -> void:", "func probe_blocker() -> void:"),
    ("func _check_phys() -> void:", "func run_phys() -> void:"),
    ("func _check_weather() -> void:", "func run_weather() -> void:"),
    ("func _check_friction() -> void:", "func run_friction() -> void:"),
    ("func _check_flip() -> void:", "func run_flip() -> void:"),
    ('get_node_or_null("Track")', "_track"),
    ('get_node_or_null("WorldEnvironment") as WorldEnvironment', "_world_environment"),
    ("_car.get_world_3d().direct_space_state", "_world_3d.direct_space_state"),
    ("get_world_3d().direct_space_state", "_world_3d.direct_space_state"),
    ("await get_tree().physics_frame", "await _physics_frame.call()"),
]


def apply_subs(s):
    for a, b in SUBS:
        s = s.replace(a, b)
    return s


orig_n = normalize(orig)
actual_n = normalize(actual)

print("原文范围七段合计 = %d 行 → 归一化 %d 行" % (len(orig), len(orig_n)))
print("模块正文 = %d 行 → 归一化 %d 行" % (len(actual), len(actual_n)))
print()

sm = difflib.SequenceMatcher(a=orig_n, b=actual_n, autojunk=False)
edits = []
unexplained = []
for tag, i1, i2, j1, j2 in sm.get_opcodes():
    if tag == "equal":
        continue
    if tag == "replace" and (i2 - i1) == (j2 - j1):
        for k in range(i2 - i1):
            a, b = orig_n[i1 + k], actual_n[j1 + k]
            if apply_subs(a) == b:
                edits.append((i1 + k + 1, a, b))
            else:
                unexplained.append((i1 + k + 1, a, b))
    else:
        # 删除/插入/长度不等的替换 —— 任何一条都算未解释
        if tag == "delete":
            for k in range(i1, i2):
                unexplained.append(("delete", orig_n[k], ""))
        elif tag == "insert":
            for k in range(j1, j2):
                unexplained.append(("insert", "", actual_n[k]))
        else:
            unexplained.append(("opcode=%s" % tag, "%d 行" % (i2 - i1), "%d 行" % (j2 - j1)))

print("可解释的改动行 = %d（每一行都能由替换表推出）" % len(edits))
print("未解释差异   = %d" % len(unexplained))
print()
print("逐条改动明细：")
for ln, a, b in edits:
    print("  [原文归一化行 %d]" % ln)
    print("    - %s" % a.strip())
    print("    + %s" % b.strip())
if unexplained:
    print()
    print("!! 未解释差异：")
    for u in unexplained:
        print("  ", u)

ok = (len(unexplained) == 0 and len(orig_n) == len(actual_n))
print()
print("结论：%s" % ("零转录漂移 ✔" if ok else "存在未解释差异 ✘"))
sys.exit(0 if ok else 1)
