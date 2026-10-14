# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-ENVPHYS-004 A/B 闭环判定（结构比对；依据 AGENTS §4.3）。

为什么需要第二套判据（不覆盖原判据）：
  split-checks-envphys-ab-analyze.py 用的是**逐行**判据（跨组差 ≤ 同代码组内极差 +
  存在一对零差跨组对）。实测 flip/phys/weather/friction 四项跨组**零差**；但
  wallslide/stuck 的逐行残差是 1~2 / 7~12 行，且**同代码对照**（m1↔m2、c1↔c2）
  本身就非零（9 行 / 7 行 / 2 行）—— 因为这两个 check 会**打印物理浮点**
  （pos 到 6 位小数、侧倾 0.1°、km/h 0.1、命中距离 0.01m），跨进程必然抖动；
  m1↔m2 与 m1↔c2 甚至出现**逐字相同的 ±1~2 帧相位移位块**。
  ⇒ 对这类检查，"逐行相等"不是可用判据，AGENTS §4.3 对 Level 4 早已定规：
     「只比结构（判定行逐字相同 + 逐类行数 + 允许 ±1 帧相位差）」。

本脚本即按该规定实现**结构判据**（三道，全过才算通过）：
  ① 行数一致：所有样本的 [自检]/[CHECK] 行数相同；
  ② 判定串集合一致：analyze.py 同款定义（含 `卡墙验收：12/12 通过 ✔` 这类结论行）；
  ③ 骨架多重集一致：把每行内所有数字替换为 `#` 后，**行内容的多重集**逐对相同
     —— 没有任何行被增删、改文案或改逻辑分支；差异只能来自数值与 ±k 帧相位。
  ④（佐证，不参与判定）列出同代码组 / 跨组的逐行 diffcount 分布，证明同代码组非零。

口径与 analyze.py / diffdetail.py 完全一致（只取 [自检]/[CHECK] 行；归一化
Hz/ms/秒 数字、帧计数、进程内对象 ID）。

退出码：0 = 全部通过。
"""
import io
import os
import re
import sys
import difflib
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.path.join(ROOT, "godot-logs")

CHECKS = ["wallslide", "stuck", "flip", "phys", "weather", "friction"]

# 与 analyze.py / diffdetail.py 逐字相同的归一化表
NORM = [
    (re.compile(r"(\d+\.\d+) Hz"), "<HZ> Hz"),
    (re.compile(r"(\d+\.\d+) ms"), "<MS> ms"),
    (re.compile(r"(\d+\.\d+) 秒"), "<SEC> 秒"),
    (re.compile(r"(\d+) 帧"), "<N> 帧"),
    (re.compile(r"#\d+"), "#<ID>"),
]

# 骨架化：把所有数值 token 抹成 #（只在本脚本使用，与上面 NORM 叠加）
DIGIT = re.compile(r"-?\d+(?:\.\d+)?")


def passes_for(check):
    m, c = [], []
    for f in sorted(os.listdir(LOGDIR)):
        mt = re.match(r"split-checks-envphys-ab-(m|c)(\d+)-%s\.log$" % re.escape(check), f)
        if mt:
            (m if mt.group(1) == "m" else c).append(mt.group(1) + mt.group(2))
    key = lambda s: int(s[1:])
    return sorted(m, key=key), sorted(c, key=key)


def load(pass_, check):
    p = os.path.join(LOGDIR, "split-checks-envphys-ab-%s-%s.log" % (pass_, check))
    if not os.path.exists(p):
        return None, None, None
    txt = io.open(p, "r", encoding="utf-8", errors="replace").read()
    lines, verdicts, skel = [], [], []
    for l in txt.replace("\r\n", "\n").split("\n"):
        if "[自检]" not in l and "[CHECK]" not in l:
            continue
        for rx, rep in NORM:
            l = rx.sub(rep, l)
        l = l.rstrip()
        lines.append(l)
        skel.append(DIGIT.sub("#", l))
        s = l.strip()
        if (s.endswith("✔") or s.endswith("✘") or s.endswith("⊘")
                or "验收 ✔" in l or "验收 ✘" in l or "判定 ✔" in l or "判定 ✘" in l):
            verdicts.append(s)
    return lines, verdicts, skel


def diffcount(a, b):
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    n = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag != "equal":
            n += max(i2 - i1, j2 - j1)
    return n


def max_pairwise(group, data):
    worst, who = 0, None
    for i in range(len(group)):
        for j in range(i + 1, len(group)):
            d = diffcount(data[group[i]], data[group[j]])
            if d > worst:
                worst, who = d, (group[i], group[j])
    return worst, who


rep = []
rep.append("======== SPLIT-CHECKS-ENVPHYS-004 A/B 闭环（结构判据，AGENTS §4.3）========")
rep.append("口径：只取 [自检]/[CHECK] 行；归一化 Hz/ms/秒 数字、帧计数、进程内对象 ID。")
rep.append("判据：① 行数一致 ② 判定串集合一致 ③ 骨架多重集一致（数字全部抹为 # 后逐对相同）")
rep.append("说明：本表**不覆盖** split-checks-envphys-ab-analysis.log 的逐行判据结果（其 ✘ 保留）。")
rep.append("")

all_ok = True
for check in CHECKS:
    mps, cps = passes_for(check)
    data, verd, skels = {}, {}, {}
    for p in mps + cps:
        data[p], verd[p], skels[p] = load(p, check)
    rep.append("---- %s ----" % check)
    if not mps or not cps:
        rep.append("  !! 缺组：m=%s c=%s" % (mps, cps))
        all_ok = False
        rep.append("")
        continue

    for p in mps + cps:
        ok = sum(1 for l in data[p] if "✔" in l)
        bad = sum(1 for l in data[p] if "✘" in l)
        rep.append("  %-3s 行数=%3d ✔=%-3d ✘=%-3d 判定串=%s"
                   % (p, len(data[p]), ok, bad,
                      " | ".join(verd[p][-2:]) if verd[p] else "-"))

    allpass = mps + cps
    # ① 行数一致
    lens = set(len(data[p]) for p in allpass)
    crit1 = (len(lens) == 1)
    # ② 判定串集合一致（全体样本并集）
    vset = set(x for p in allpass for x in verd[p])
    crit2 = all(set(verd[p]) == vset for p in allpass)
    # ③ 骨架多重集一致（逐对）
    bad_pairs = []
    for i in range(len(allpass)):
        for j in range(i + 1, len(allpass)):
            a, b = allpass[i], allpass[j]
            if Counter(skels[a]) != Counter(skels[b]):
                bad_pairs.append("%s↔%s" % (a, b))
    crit3 = (len(bad_pairs) == 0)

    noise_m, wm = max_pairwise(mps, data)
    noise_c, wc = max_pairwise(cps, data)
    cross, cross_who = 0, None
    zero_pairs = []
    for a in mps:
        for b in cps:
            d = diffcount(data[a], data[b])
            if d == 0:
                zero_pairs.append("%s≡%s" % (a, b))
            if d > cross:
                cross, cross_who = d, (a, b)

    rep.append("  ① 行数一致 ? %s（实测 %s）" % ("是" if crit1 else "**否**", sorted(lens)))
    rep.append("  ② 判定串集合一致 ? %s（%d 种）" % ("是" if crit2 else "**否**", len(vset)))
    rep.append("  ③ 骨架多重集一致 ? %s%s"
               % ("是" if crit3 else "**否**",
                  "" if crit3 else "（不一致对：%s）" % ", ".join(bad_pairs)))
    rep.append("  ④ 逐行 diffcount（佐证）：同代码 m 组极差 %d%s / c 组极差 %d%s；跨组最大 %d%s；零差跨组对 %s"
               % (noise_m, ("（%s↔%s）" % wm) if wm else "",
                  noise_c, ("（%s↔%s）" % wc) if wc else "",
                  cross, ("（%s↔%s）" % cross_who) if cross_who else "",
                  ", ".join(zero_pairs) if zero_pairs else "无"))
    same_code_nonzero = (noise_m > 0) or (noise_c > 0)
    rep.append("       ⇒ 同代码组本身%s（说明该检查跨进程不可逐行复现；残差 = 数值抖动 + ±k 帧相位）"
               % ("非零" if same_code_nonzero else "为零"))

    verdict = crit1 and crit2 and crit3
    if not verdict:
        all_ok = False
    rep.append("  结论：%s" % ("✔ 结构零差 —— 迁移未引入可辨识差异"
                              if verdict else "✘ 结构层出现差异，需人工复核"))
    rep.append("")

rep.append("总判：%s" % ("全部 %d 项通过 ✔（结构判据）" % len(CHECKS) if all_ok else "有项未通过 ✘"))
out = "\n".join(rep)
io.open(os.path.join(LOGDIR, "split-checks-envphys-ab-closure.log"), "w",
        encoding="utf-8", newline="\n").write(out + "\n")
print(out)
sys.exit(0 if all_ok else 1)
