# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-AI-003 A/B 比对分析器 v2。

输入：godot-logs/split-checks-ai-ab-{m1,m2,c1,c2}-{opponents,aidiag,avoid,obstacles,aistart}.log
（m = 迁移态 / c = HEAD 态；数字 = 第几跑）

做法：
  1. 只取 `[自检]` / `[CHECK]` 行（与 run-check.ps1 同口径，滤掉引擎噪声）；
  2. 归一化**唯一的两处逐跑变动源**（都在 run_opponents 里）：
       · `对手用时 X 秒` —— Time.get_ticks_msec，墙钟；
       · `（N 帧）` —— 完成圈数的物理帧计数（break 时机），可能是 ±1 帧相位。
     两者都换成占位符后做逐行比对 —— 归一化后要求**完全相同**；
     帧计数单独列表比较（判据：四跑极差 ≤ 1 帧）。
  3. 判据（数据驱动，不靠拍的阈值）：
       · 归一化后 m/c 各组内 + 跨组必须 0 差异；
       · ✔/✘ 计数四跑一致；
       · 完成帧计数极差 ≤ 1。

退出码：0 = 全部满足；1 = 有项不满足。
"""
import io
import os
import re
import sys
import difflib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.path.join(ROOT, "godot-logs")

CHECKS = ["opponents", "aidiag", "avoid", "obstacles", "aistart"]
PASSES = ["m1", "m2", "c1", "c2"]

WALL = re.compile(r"对手用时 (\d+\.\d+) 秒（(\d+) 帧）")


def load(pass_, check):
    p = os.path.join(LOGDIR, "split-checks-ai-ab-%s-%s.log" % (pass_, check))
    if not os.path.exists(p):
        return None, None
    txt = io.open(p, "r", encoding="utf-8", errors="replace").read()
    lines = []
    frames = None
    for l in txt.replace("\r\n", "\n").split("\n"):
        if "[自检]" not in l and "[CHECK]" not in l:
            continue
        m = WALL.search(l)
        if m:
            frames = int(m.group(2))
            l = WALL.sub("对手用时 <WALL> 秒（<FRAMES> 帧）", l)
        lines.append(l.rstrip())
    return lines, frames


def stats(lines):
    return len(lines), sum(1 for l in lines if "✔" in l), sum(1 for l in lines if "✘" in l)


def diffcount(a, b):
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    n = 0
    hunks = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        n += max(i2 - i1, j2 - j1)
        hunks.append((tag, a[i1:i2], b[j1:j2]))
    return n, hunks


rep = []
rep.append("================ SPLIT-CHECKS-AI-003 A/B 分析（归一化逐行比对）================")
rep.append("口径：只取 [自检]/[CHECK] 行；把 run_opponents 里两处唯一的逐跑变动源")
rep.append("      （墙钟秒数 + 完成帧计数）换成占位符后**逐行**比对；帧计数单独列表。")
rep.append("")

all_ok = True
for check in CHECKS:
    data, frames = {}, {}
    for p in PASSES:
        data[p], frames[p] = load(p, check)
    rep.append("---- %s ----" % check)
    miss = [p for p in PASSES if data[p] is None]
    if miss:
        rep.append("  !! 缺日志：%s" % ",".join(miss))
        all_ok = False
        rep.append("")
        continue
    for p in PASSES:
        n, ok, bad = stats(data[p])
        rep.append("  %-3s 行数=%4d ✔=%-4d ✘=%-3d 完成帧=%s" % (p, n, ok, bad, frames[p]))

    pairs = [("m1", "m2"), ("c1", "c2"), ("m1", "c1"), ("m2", "c2"), ("m1", "c2"), ("m2", "c1")]
    diffs = {}
    for a, b in pairs:
        diffs[(a, b)] = diffcount(data[a], data[b])[0]
    rep.append("  归一化后差异行数：" + "  ".join("%s↔%s=%d" % (a, b, v) for (a, b), v in diffs.items()))

    inner = max(diffs[("m1", "m2")], diffs[("c1", "c2")])
    cross = max(diffs[("m1", "c1")], diffs[("m2", "c2")], diffs[("m1", "c2")], diffs[("m2", "c1")])
    okbad_same = len({stats(data[p])[1:] for p in PASSES}) == 1
    if any(frames[p] is None for p in PASSES):
        fr_spread = 0
        fr_txt = "-"
    else:
        frs = [frames[p] for p in PASSES]
        fr_spread = max(frs) - min(frs)
        fr_txt = str(fr_spread)
    verdict = (cross == 0 and inner == 0 and okbad_same and fr_spread <= 1)
    if not verdict:
        all_ok = False
    rep.append("  判据：跨组最大差=%d（要求 0）；同代码组内极差=%d（要求 0）；"
               "✔/✘ 四跑一致=%s；完成帧极差=%s（要求 ≤1，“-” 表示本项无该行）"
               % (cross, inner, "是" if okbad_same else "否", fr_txt))
    rep.append("  结论：%s" % ("✔ 归一化后逐行完全相同、无任何可辨识差异" if verdict else "✘ 有差异"))
    if not verdict:
        for (a, b) in [("m1", "c1"), ("m2", "c2")]:
            n, hunks = diffcount(data[a], data[b])
            if n:
                rep.append("    差异 %s vs %s：" % (a, b))
                for tag, la, lb in hunks:
                    for x in la:
                        rep.append("      - %s" % x)
                    for x in lb:
                        rep.append("      + %s" % x)
    rep.append("")

rep.append("总判：%s" % ("全部 5 项满足判据 ✔" if all_ok else "有项不满足 ✘"))

out = "\n".join(rep)
io.open(os.path.join(LOGDIR, "split-checks-ai-ab-analysis.log"), "w",
        encoding="utf-8", newline="\n").write(out + "\n")
print(out)
sys.exit(0 if all_ok else 1)
