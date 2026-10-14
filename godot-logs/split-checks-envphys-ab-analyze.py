# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-ENVPHYS-004 A/B 比对分析器（数据驱动噪声底判据）。

输入：godot-logs/split-checks-envphys-ab-{m,c}{1..N}-{check}.log
      （m = 迁移态 / c = HEAD 态；数字 = 第几跑）

做法：
  1. 只取 `[自检]` / `[CHECK]` 行（与 run-check.ps1 同口径，滤掉引擎噪声）；
  2. 归一化**逐跑变动源**：
       · phys / weather 的墙钟量：`Hz` / `ms` / `秒` 数字 + `帧` 计数（本族双稳态来源）；
       · 进程内对象 ID（`VehicleBody3D#12345` 之类）。
       （wallslide / stuck / flip / friction 是纯物理量，理论确定；若出现漂移由判据兜底。）
  3. 判据（**数据驱动**，不拍阈值）：
       ① **跨组差 ≤ 同代码组内极差** —— 迁移带来的差必须落在"同一份代码两跑也不一样"的量级内；
       ② **存在至少一对 m↔c 完全零差** —— 迁移不是"普遍扰动"，而是能逐行复现 HEAD 的输出；
       ③ 判定串（`✔/✘` 收尾/结论行）的**集合**不因代码版本改变。
       三者同时满足才算通过。

退出码：0 = 全部 check 通过；1 = 有不通过。
"""
import io
import os
import re
import sys
import difflib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.path.join(ROOT, "godot-logs")

CHECKS = ["wallslide", "stuck", "flip", "phys", "weather", "friction"]

# 逐跑变动源（归一化）
NORM = [
    (re.compile(r"(\d+\.\d+) Hz"), "<HZ> Hz"),
    (re.compile(r"(\d+\.\d+) ms"), "<MS> ms"),
    (re.compile(r"(\d+\.\d+) 秒"), "<SEC> 秒"),
    (re.compile(r"(\d+) 帧"), "<N> 帧"),
    (re.compile(r"#\d+"), "#<ID>"),
]


def passes_for(check):
    m = []
    c = []
    for f in sorted(os.listdir(LOGDIR)):
        mt = re.match(r"split-checks-envphys-ab-(m|c)(\d+)-%s\.log$" % re.escape(check), f)
        if mt:
            (m if mt.group(1) == "m" else c).append(mt.group(1) + mt.group(2))
    key = lambda s: int(s[1:])
    return sorted(m, key=key), sorted(c, key=key)


def load(pass_, check):
    p = os.path.join(LOGDIR, "split-checks-envphys-ab-%s-%s.log" % (pass_, check))
    if not os.path.exists(p):
        return None, None
    txt = io.open(p, "r", encoding="utf-8", errors="replace").read()
    lines = []
    verdicts = []
    for l in txt.replace("\r\n", "\n").split("\n"):
        if "[自检]" not in l and "[CHECK]" not in l:
            continue
        for rx, rep in NORM:
            l = rx.sub(rep, l)
        l = l.rstrip()
        lines.append(l)
        s = l.strip()
        if (s.endswith("✔") or s.endswith("✘") or s.endswith("⊘")
                or "验收 ✔" in l or "验收 ✘" in l or "判定 ✔" in l or "判定 ✘" in l):
            verdicts.append(s)
    return lines, verdicts


def diffcount(a, b):
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    n = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag != "equal":
            n += max(i2 - i1, j2 - j1)
    return n


def max_pairwise(group, data):
    worst = 0
    who = None
    for i in range(len(group)):
        for j in range(i + 1, len(group)):
            d = diffcount(data[group[i]], data[group[j]])
            if d > worst:
                worst, who = d, (group[i], group[j])
    return worst, who


rep = []
rep.append("================ SPLIT-CHECKS-ENVPHYS-004 A/B 分析（噪声底判据）================")
rep.append("口径：只取 [自检]/[CHECK] 行；归一化 Hz/ms/秒 数字、帧计数、进程内对象 ID。")
rep.append("判据：① 跨组差 ≤ 同代码组内极差；② 存在一对 m↔c 零差；③ 判定串集合两组一致。")
rep.append("")

all_ok = True
for check in CHECKS:
    mps, cps = passes_for(check)
    data, verd = {}, {}
    for p in mps + cps:
        data[p], verd[p] = load(p, check)
    rep.append("---- %s ----" % check)
    if not mps or not cps:
        rep.append("  !! 缺组：m=%s c=%s" % (mps, cps))
        all_ok = False
        rep.append("")
        continue
    for p in mps + cps:
        n = len(data[p])
        ok = sum(1 for l in data[p] if "✔" in l)
        bad = sum(1 for l in data[p] if "✘" in l)
        rep.append("  %-3s 行数=%4d ✔=%-3d ✘=%-3d 判定串=%s"
                   % (p, n, ok, bad, " | ".join(verd[p][-2:]) if verd[p] else "-"))

    noise_m, wm = max_pairwise(mps, data)
    noise_c, wc = max_pairwise(cps, data)
    noise = max(noise_m, noise_c)
    cross = 0
    cross_who = None
    zero_pairs = []
    for a in mps:
        for b in cps:
            d = diffcount(data[a], data[b])
            if d == 0:
                zero_pairs.append("%s≡%s" % (a, b))
            if d > cross:
                cross, cross_who = d, (a, b)
    union_m = set(x for p in mps for x in verd[p])
    union_c = set(x for p in cps for x in verd[p])
    verdict_ok = (union_m == union_c)

    rep.append("  同代码组内极差：m 组 %d%s，c 组 %d%s  → 噪声底 %d"
               % (noise_m, ("（%s↔%s）" % wm) if wm else "", noise_c,
                  ("（%s↔%s）" % wc) if wc else "", noise))
    rep.append("  跨组最大差：%d%s" % (cross, ("（%s↔%s）" % cross_who) if cross_who else ""))
    rep.append("  零差跨组对：%s" % (", ".join(zero_pairs) if zero_pairs else "无"))
    rep.append("  判定串集合：m 组 %d 种 / c 组 %d 种 → 一致=%s" % (len(union_m), len(union_c), verdict_ok))
    crit1 = cross <= noise
    crit2 = len(zero_pairs) > 0
    verdict = crit1 and crit2 and verdict_ok
    if not verdict:
        all_ok = False
    rep.append("  判据：① 跨组差 %d ≤ 噪声底 %d ? %s ② 存在零差跨组对 ? %s ③ 判定串一致 ? %s"
               % (cross, noise, "是" if crit1 else "**否**",
                  "是" if crit2 else "**否**", "是" if verdict_ok else "**否**"))
    rep.append("  结论：%s" % ("✔ 迁移未引入可辨识差异" if verdict else "✘ 存在超噪声底的差异"))
    rep.append("")

rep.append("总判：%s" % ("全部 %d 项通过 ✔" % len(CHECKS) if all_ok else "有项未通过 ✘"))
out = "\n".join(rep)
io.open(os.path.join(LOGDIR, "split-checks-envphys-ab-analysis.log"), "w",
        encoding="utf-8", newline="\n").write(out + "\n")
print(out)
sys.exit(0 if all_ok else 1)
