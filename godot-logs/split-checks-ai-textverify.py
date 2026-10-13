# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-AI-003 转录保真核验器（独立于 extract.py 的**反向**检查）。

思路（刻意不复用 extract.py 的替换代码，避免自证）：
  把 HEAD 态 main.gd 的四处原始块拼成"原文"，把 scripts/checks/ai.gd 的
  迁移正文取出来做 diff；要求
    ① 没有任何 delete/insert 行（行数必须完全对应）；
    ② 每一对"改动行"（a→b）都必须能用**文件头登记的那 10 条替换之一**从 a 推出来；
    ③ 改动行总数 == 21（T1~T5 各 1 + T6 六 + T7 一 + T8 一 + T9 六 + T10 二）。
  任何"看起来对但其实是顺手改的"漂移（多一个空格、文案改字、%占位换序）都会被
  ②③ 抓到。

用法：python godot-logs/split-checks-ai-textverify.py
退出码：0 = 零漂移；1 = 有未解释差异。
"""
import difflib
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN = os.path.join(ROOT, "godot-racer", "scenes", "main.gd")
MOD = os.path.join(ROOT, "godot-racer", "scripts", "checks", "ai.gd")

# ---- 1. 取 HEAD 态 main.gd（用 git show，确保比对的是入库版本而不是被改后的工作区）
import subprocess
head_raw = subprocess.run(
    ["git", "-C", ROOT, "show", "HEAD:godot-racer/scenes/main.gd"],
    capture_output=True, check=True).stdout.decode("utf-8")
head = head_raw.replace("\r\n", "\n").split("\n")

# 注意：HEAD 态的行号 = 迁移前（3346 行），下面这套锚点与 extract.py 一致
BLOCKS = [
    ("CONSTS", 635, 691),
    ("OPP", 1142, 1216),
    ("DIAG", 1315, 1688),
    ("TRIO", 1829, 2115),
]
orig = []
for name, a, b in BLOCKS:
    orig.extend(head[a - 1:b])

# ---- 2. 取模块正文（去掉 header / 注入段 / 段落横幅）
mod = io.open(MOD, "r", encoding="utf-8").read().replace("\r\n", "\n").split("\n")
# 正文从 `func run_opponents()` 往上回溯到常量首行；常量首行 = `## aidiag 里`
try:
    i_const = next(i for i, l in enumerate(mod) if l.startswith("## aidiag 里"))
    i_end = len(mod)
    while i_end > 0 and mod[i_end - 1].strip() == "":
        i_end -= 1
except StopIteration:
    print("!! 模块里找不到常量首行锚 `## aidiag 里`")
    sys.exit(1)
actual = mod[i_const:i_end]

# ---- 3. 逐行 diff
SUBS = [
    ("func _check_opponents() -> void:", "func run_opponents() -> void:"),
    ("func _check_ai_diag() -> void:", "func run_ai_diag() -> void:"),
    ("func _check_avoid() -> void:", "func run_avoid() -> void:"),
    ("func _check_obstacles() -> void:", "func run_obstacles() -> void:"),
    ("func _check_ai_start() -> void:", "func run_ai_start() -> void:"),
    ('get_node_or_null("Track")', "_track"),
    ('get_node_or_null("Obstacles")', "_obstacle_field"),
    ("get_world_3d().direct_space_state", "_world_3d.direct_space_state"),
    ("await get_tree().physics_frame", "await _physics_frame.call()"),
    ("await _sample_physics_ms(", "await _sample_physics_ms.call("),
]
EXPECT_EDITED = 21


def apply_subs(s):
    for a, b in SUBS:
        s = s.replace(a, b)
    return s


# 先把原文按"应该变成的样子"算一遍，看行数是否一致
sm = difflib.SequenceMatcher(a=orig, b=actual, autojunk=False)
edits = []
blanks = []
unexplained = []
for tag, i1, i2, j1, j2 in sm.get_opcodes():
    if tag == "equal":
        continue
    if tag == "replace" and (i2 - i1) == (j2 - j1):
        for k in range(i2 - i1):
            a, b = orig[i1 + k], actual[j1 + k]
            if apply_subs(a) == b:
                edits.append((i1 + k + 1, a, b))
            else:
                unexplained.append((i1 + k + 1, a, b))
    elif tag == "insert" and all(l.strip() == "" for l in actual[j1:j2]):
        # 模块装配时在四块之间补的分隔空行（原文各块之间的空行留在了 main.gd 里，
        # 没有随块搬进 orig）。只允许空行，且只允许出现在块接缝处。
        blanks.append((j1 + 1, j2 - j1))
    else:
        unexplained.append(("opcode=%s" % tag, "%d 行" % (i2 - i1), "%d 行" % (j2 - j1)))

print("原文行数 = %d，模块正文行数 = %d" % (len(orig), len(actual)))
print("可解释的改动行 = %d（期望 %d）" % (len(edits), EXPECT_EDITED))
print("块接缝处补的分隔空行 = %d 处 / %d 行（期望 3 处 / 6 行）"
      % (len(blanks), sum(n for _, n in blanks)))
print("未解释差异   = %d" % len(unexplained))
print()
print("逐条改动明细：")
for ln, a, b in edits:
    print("  [原文 L%d]" % ln)
    print("    - %s" % a)
    print("    + %s" % b)
if unexplained:
    print()
    print("!! 未解释差异：")
    for u in unexplained:
        print("  ", u)
print()
print("块接缝空行明细（模块行号, 行数）：", blanks)

ok = (len(unexplained) == 0 and len(edits) == EXPECT_EDITED
      and len(blanks) == 3 and sum(n for _, n in blanks) == 6
      and len(orig) + 6 == len(actual))
print()
print("结论：%s" % ("零转录漂移 ✔" if ok else "存在未解释差异 ✘"))
sys.exit(0 if ok else 1)
