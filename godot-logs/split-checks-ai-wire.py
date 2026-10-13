# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-AI-003 main.gd 接线器。

在 scenes/main.gd（CRLF）上做四件事：
  1. 4 处迁出位：删掉常量块/5 个函数的文档+实体，原地留 breadcrumb 注释
     （注释不参与 structcheck 的"去注释代码零残留"判据，也便于 audit）；
  2. `_checks_bench` 之后插入模块声明块（preload + new）；
  3. `_checks_bench.setup(...)` 之后插入 setup 接线；
  4. `match _check:` 分发口 5 行改为 await _checks_ai.run_*()。

行号基于 HEAD 态（工作区与 HEAD 一致）；处理从后往前，行号不漂。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN = os.path.join(ROOT, "godot-racer", "scenes", "main.gd")

with io.open(MAIN, "r", encoding="utf-8", newline="") as f:
    raw = f.read()
nl = "\r\n" if "\r\n" in raw else "\n"
lines = raw.replace("\r\n", "\n").split("\n")
n = len(lines)
# 文件以换行结尾 → split 末尾多一个空元素；实际行数 = n - 1
print("原 main.gd 行数 =", n - 1)
assert n == 3347, "行数不是 3346，HEAD 态已变，停下"

# ---------------------------------------------------------------- 迁出位 → breadcrumb
BC_CONSTS = [
    "# aidiag 的 9 个 AI_* 判据常量（AI_RECOVER_WARN_SEC / AI_TARGET_* / AI_BEND_GUARD_SEG）",
    "# 已迁至 scripts/checks/ai.gd（SPLIT-CHECKS-AI-003 纯迁移，行为零变化）—— 不复制第二份。",
]
BC_OPP = [
    "# --check=opponents 已迁至 scripts/checks/ai.gd 的 run_opponents()",
    "# （SPLIT-CHECKS-AI-003 纯迁移，行为零变化）。",
]
BC_DIAG = [
    "# --check=aidiag 已迁至 scripts/checks/ai.gd 的 run_ai_diag()",
    "# （SPLIT-CHECKS-AI-003 纯迁移，行为零变化）。",
]
BC_TRIO = [
    "# --check=avoid / obstacles / aistart 已迁至 scripts/checks/ai.gd 的",
    "# run_avoid() / run_obstacles() / run_ai_start()（SPLIT-CHECKS-AI-003 纯迁移，行为零变化）。",
]

# 校验边界（与 extract.py 同一套锚点）
def L(i):
    return lines[i - 1]

assert L(635).startswith("## aidiag 里") and L(691) == "const AI_BEND_GUARD_SEG := 3.0"
assert L(1142).startswith("## AI 对手验收") and L(1149).startswith("func _check_opponents(")
assert L(1216).endswith("见上方 ✘ 行\")")
assert L(1315).startswith("## AI 行为诊断") and L(1327).startswith("func _check_ai_diag(")
assert L(1829).startswith("## AI 避让玩家验收") and L(1836).startswith("func _check_avoid(")
assert L(2059).startswith("func _check_ai_start(") and L(2115).endswith("见上方 ✘ 行\")")

# ---------------------------------------------------------------- 声明块 / 接线块
DECL = [
    "",
    "## AI 验收模块（SPLIT-CHECKS-AI-003 从本文件拆出）：--check=opponents / aidiag /",
    "## avoid / obstacles / aistart 五族（对手跑圈、AI 行为诊断 + 任务 15 目标速度判据、",
    "## 避让玩家路障、障碍物位置/碰撞/通行缝隙、并排发车）。同样用 preload 而不是",
    "## class_name，原因同 EnvironmentFX：无编辑器环境下 class_name 依赖编辑器才重建的",
    "## .godot 全局类缓存。",
    "## 注入：_after_world_ready 里 _checks_ai.setup(...) —— 车/赛道/障碍场/物理世界注入",
    "## （模块不 get_node）；对手生成与自动驾驶注入**本文件持有的实例**（状态在实例上，",
    "## 第二份会拿到空）；physics_frame 与 _sample_physics_ms 采样器经 Callable 递入。",
    "const ChecksAi := preload(\"res://scripts/checks/ai.gd\")",
    "var _checks_ai := ChecksAi.new()",
]
SETUP = [
    "\t# AI 验收模块接线（SPLIT-CHECKS-AI-003）：车/赛道/障碍场/物理世界注入（模块不 get_node，",
    "\t# §2.4）；对手生成/自动驾驶注入本文件持有的**实例**（状态在实例上）；physics_frame 与",
    "\t# _sample_physics_ms 采样器经 Callable 递入（同 screenshot_mode / bench）。",
    "\t_checks_ai.setup(_car, track, _obstacle_field, _opponent_spawner, _autopilot,",
    "\t\tget_world_3d(), Callable(self, \"_shot_physics_frame\"), Callable(self, \"_sample_physics_ms\"))",
]

# ---------------------------------------------------------------- 组装（从后往前）
out = list(lines)

def replace_range(a, b, new):
    """1-based 闭区间 [a,b] 换成 new（行列表）。"""
    out[a - 1:b] = new

replace_range(1829, 2115, BC_TRIO)
replace_range(1315, 1688, BC_DIAG)
replace_range(1142, 1216, BC_OPP)
replace_range(635, 691, BC_CONSTS)

text = "\n".join(out)

# 声明块：插在 `var _checks_bench := ChecksBench.new()` 之后
anchor1 = "const ChecksBench := preload(\"res://scripts/checks/bench.gd\")\nvar _checks_bench := ChecksBench.new()\n"
assert text.count(anchor1) == 1
text = text.replace(anchor1, anchor1 + "\n".join(DECL) + "\n")

# setup 接线：插在 bench 的 setup 之后
anchor2 = "	_checks_bench.setup(_car, track, Callable(self, \"_shot_physics_frame\"))\n"
assert text.count(anchor2) == 1
text = text.replace(anchor2, anchor2 + "\n".join(SETUP) + "\n")

# 分发口 5 行
disp = {
    "\t\tawait _check_opponents()\n": "\t\tawait _checks_ai.run_opponents()\n",
    "\t\tawait _check_ai_start()\n": "\t\tawait _checks_ai.run_ai_start()\n",
    "\t\tawait _check_obstacles()\n": "\t\tawait _checks_ai.run_obstacles()\n",
    "\t\tawait _check_avoid()\n": "\t\tawait _checks_ai.run_avoid()\n",
    "\t\tawait _check_ai_diag()\n": "\t\tawait _checks_ai.run_ai_diag()\n",
}
for a, b in disp.items():
    c = text.count(a)
    assert c == 1, "dispatch 锚 %r 命中 %d 次" % (a, c)
    text = text.replace(a, b)

# ---------------------------------------------------------------- 复核
final = text.split("\n")
print("新 main.gd 行数 =", len(final) - 1)
print("func 数 =", sum(1 for l in final if l.startswith("func ")))
for pat in ("_check_opponents", "_check_ai_diag", "_check_avoid", "_check_obstacles",
            "_check_ai_start", "AI_RECOVER_WARN_SEC", "AI_TARGET_", "AI_BEND_GUARD_SEG"):
    print("  残留 %-22s = %d" % (pat, sum(1 for l in final if pat in l and not l.lstrip().startswith("#"))))
for pat in ("_checks_ai.run_opponents()", "_checks_ai.run_ai_diag()", "_checks_ai.run_avoid()",
            "_checks_ai.run_obstacles()", "_checks_ai.run_ai_start()", "_checks_ai.setup("):
    print("  接线 %-30s = %d" % (pat, text.count(pat)))

if "--write" in sys.argv:
    with io.open(MAIN, "w", encoding="utf-8", newline="") as f:
        f.write(text.replace("\n", nl))
    print("\n已写回", MAIN)
else:
    print("\n（干跑；加 --write 落地）")
