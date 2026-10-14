# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-ENVPHYS-004：把 main.gd 中已迁至 scripts/checks/env_phys.gd 的函数块
按精确行范围删除，替换成 breadcrumb 注释；并把 _check_lap 里 _probe_blocker() 调用点
改走 _checks_envphys.probe_blocker()。

⚠ 只在 main.gd 处于 HEAD（未改动）时运行 —— 行号按 HEAD 实测。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN = os.path.join(ROOT, "godot-racer", "scenes", "main.gd")

# (start, end) 1-based inclusive，倒序应用；repl = 替换文本（list of lines）
RANGES = [
    (431, 532, [
        "# 卡墙验收族（_check_wallslide + _visual_lateral_extent）已迁至",
        "# scripts/checks/env_phys.gd 的 run_wallslide()（SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。",
    ]),
    (535, 643, [
        "# 卡墙诊断族（_check_stuck）已迁至 scripts/checks/env_phys.gd 的 run_stuck()",
        "# （SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。",
    ]),
    (655, 709, [
        "# 卡住取证（_probe_blocker）已迁至 scripts/checks/env_phys.gd 的 probe_blocker()",
        "# （SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）；下面 _check_lap 的卡住取证调用点",
        "# 改走 _checks_envphys.probe_blocker()。",
    ]),
    (1134, 1200, [
        "# 物理开销测量（--check=phys）已迁至 scripts/checks/env_phys.gd 的 run_phys()",
        "# （SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。",
    ]),
    (1349, 1434, [
        "# 天气验收族（_check_weather + _luminance + MIN_WEATHER_CONTRAST）已迁至",
        "# scripts/checks/env_phys.gd 的 run_weather()（SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。",
    ]),
    (1437, 1562, [
        "# 抓地力验收族（_check_friction + _friction_probe）已迁至",
        "# scripts/checks/env_phys.gd 的 run_friction()（SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。",
    ]),
    (1574, 2026, [
        "# 翻车恢复验收族（--check=flip：_check_flip + 7 个 helper）已迁至",
        "# scripts/checks/env_phys.gd 的 run_flip()（SPLIT-CHECKS-ENVPHYS-004 纯迁移，行为零变化）。",
    ]),
]

with io.open(MAIN, "r", encoding="utf-8", newline="") as f:
    raw = f.read()
EOL = "\r\n" if "\r\n" in raw else "\n"
text = raw.replace("\r\n", "\n")
lines = text.split("\n")  # 末尾空串占位
before = len(lines)

for start, end, repl in sorted(RANGES, key=lambda r: r[0], reverse=True):
    assert 1 <= start <= end <= len(lines), "范围越界 %s-%s" % (start, end)
    lines[start - 1:end] = repl

text = "\n".join(lines)
# _probe_blocker 调用点改走模块
old = "\t\t\t\t_probe_blocker()"
new = "\t\t\t\t_checks_envphys.probe_blocker()"
assert text.count(old) == 1, " _probe_blocker() 调用点计数异常: %d" % text.count(old)
text = text.replace(old, new)

out = text.replace("\n", EOL)
with io.open(MAIN, "w", encoding="utf-8", newline="") as f:
    f.write(out)

print("EOL=%r before lines=%d after lines=%d" % (EOL, before, len(text.split("\n"))))
