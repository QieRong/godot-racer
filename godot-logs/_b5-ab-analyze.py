# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-BASIC-005 A/B 判定（HEAD 代码 vs 迁移后代码）。

两组样本（见 _b5-ab-dance.ps1）：
  work = 迁移后（main.gd 分发到 _checks_basic / _checks_lap）
  head = HEAD（旧 main.gd 自带 _check_* 函数体）
判据（依 AGENTS §4.3）：
  A. reverse 的**纯函数段**（剔除 "端到端" 行）——两组的这条段必须**逐行完全相同**
     （纯函数不依赖物理浮点 / 时序，跨进程可逐行复现 ⇒ 强判据）。
  B. lap —— 打印物理浮点，跨进程不可逐行复现 ⇒ 只比**结构**：
     ① 行数一致 ② 判定串集合一致 ③ 骨架多重集一致（数字全抹为 # 后逐对相同）；
     并列出同代码组（work1↔work2、head1↔head2）的逐行残差作噪声底佐证。
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
PREFIX = "split-checks-basic-005-ab-"

NORM = [
    (re.compile(r"(\d+\.\d+) Hz"), "<HZ> Hz"),
    (re.compile(r"(\d+\.\d+) ms"), "<MS> ms"),
    (re.compile(r"(\d+\.\d+) 秒"), "<SEC> 秒"),
    (re.compile(r"(\d+) 帧"), "<N> 帧"),
    (re.compile(r"#\d+"), "#<ID>"),
]
DIGIT = re.compile(r"-?\d+(?:\.\d+)?")


def load(logname):
    p = os.path.join(LOGDIR, logname + ".log")
    if not os.path.exists(p):
        return None
    txt = io.open(p, "r", encoding="utf-8", errors="replace").read()
    lines, skel, verd = [], [], []
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
                or "验收 ✔" in l or "验收 ✘" in l):
            verd.append(s)
    return {"lines": lines, "skel": skel, "verd": verd}


def diffcount(a, b):
    n = 0
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_opcodes():
        if tag != "equal":
            n += max(i2 - i1, j2 - j1)
    return n


rep = []
rep.append("======== SPLIT-CHECKS-BASIC-005 A/B 判定（HEAD vs 迁移后；AGENTS §4.3）========")
rep.append("口径：只取 [自检]/[CHECK] 行；归一化 Hz/ms/秒 数字、帧计数、进程内对象 ID。")
rep.append("")
all_ok = True

# ---------------- A. reverse 纯函数段：逐行相同 ----------------
rep.append("---- A. reverse 纯函数段（剔除含「端到端」的行）----")
rh = load(PREFIX + "head-reverse")
rw = load(PREFIX + "work-reverse")
if rh is None or rw is None:
    rep.append("  !! 缺样本（head=%s work=%s）" % (rh is not None, rw is not None))
    all_ok = False
else:
    ph = [l for l in rh["lines"] if "端到端" not in l]
    pw = [l for l in rw["lines"] if "端到端" not in l]
    d = diffcount(ph, pw)
    rep.append("  head 纯函数段 = %d 行；work 纯函数段 = %d 行" % (len(ph), len(pw)))
    rep.append("  逐行 diffcount = %d（要求 0）" % d)
    if d == 0:
        rep.append("  结论：✔ 纯函数段逐行完全相同（迁移零差异）")
    else:
        rep.append("  结论：✘ 纯函数段有差异，需人工复核：")
        for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=ph, b=pw, autojunk=False).get_opcodes():
            if tag == "equal":
                continue
            for x in ph[i1:i2]:
                rep.append("     - %s" % x)
            for x in pw[j1:j2]:
                rep.append("     + %s" % x)
        all_ok = False
rep.append("")

# ---------------- B. lap 结构判据 ----------------
rep.append("---- B. lap（结构判据：① 行数 ② 判定串集合 ③ 骨架多重集）----")
samples = ["work-lap1", "work-lap2", "head-lap1", "head-lap2"]
data = {}
for s in samples:
    data[s] = load(PREFIX + s)
missing = [s for s in samples if data[s] is None]
if missing:
    rep.append("  !! 缺样本：%s" % ", ".join(missing))
    all_ok = False
else:
    for s in samples:
        ok = sum(1 for l in data[s]["lines"] if "✔" in l)
        bad = sum(1 for l in data[s]["lines"] if "✘" in l)
        rep.append("  %-10s 行数=%3d ✔=%-3d ✘=%-3d 判定串=%s"
                   % (s, len(data[s]["lines"]), ok, bad,
                      " | ".join(data[s]["verd"][-2:]) if data[s]["verd"] else "-"))
    lens = set(len(data[s]["lines"]) for s in samples)
    vset = set(x for s in samples for x in data[s]["verd"])
    crit1 = (len(lens) == 1)
    crit2 = all(set(data[s]["verd"]) == vset for s in samples)
    bad_pairs = []
    for i in range(len(samples)):
        for j in range(i + 1, len(samples)):
            a, b = samples[i], samples[j]
            if Counter(data[a]["skel"]) != Counter(data[b]["skel"]):
                bad_pairs.append("%s↔%s" % (a, b))
    crit3 = (len(bad_pairs) == 0)
    rep.append("  ① 行数一致 ? %s（实测 %s）" % ("是" if crit1 else "**否**", sorted(lens)))
    rep.append("  ② 判定串集合一致 ? %s（%d 种）" % ("是" if crit2 else "**否**", len(vset)))
    rep.append("  ③ 骨架多重集一致 ? %s%s"
               % ("是" if crit3 else "**否**",
                  "" if crit3 else "（不一致对：%s）" % ", ".join(bad_pairs)))
    # 噪声底佐证：同代码组逐行残差
    nw = diffcount(data["work-lap1"]["lines"], data["work-lap2"]["lines"])
    nh = diffcount(data["head-lap1"]["lines"], data["head-lap2"]["lines"])
    xc = diffcount(data["work-lap1"]["lines"], data["head-lap1"]["lines"])
    mx = 0
    for a in ["work-lap1", "work-lap2"]:
        for b in ["head-lap1", "head-lap2"]:
            mx = max(mx, diffcount(data[a]["lines"], data[b]["lines"]))
    rep.append("  ④ 佐证：同代码残差 work1↔work2=%d / head1↔head2=%d；跨组最大=%d" % (nw, nh, mx))
    rep.append("       ⇒ 逐行判据对 lap 不适用（同代码组本身残差 %d / %d，来自物理浮点抖动 + ±帧相位）"
               % (nw, nh))
    verdict = crit1 and crit2 and crit3
    rep.append("  结论：%s" % ("✔ 结构零差 —— 迁移未引入可辨识差异"
                              if verdict else "✘ 结构层出现差异，需人工复核"))
    if not verdict:
        all_ok = False
rep.append("")

rep.append("总判：%s" % ("通过 ✔（A 逐行相同 + B 结构零差）" if all_ok else "有项未通过 ✘"))
out = "\n".join(rep)
io.open(os.path.join(LOGDIR, "split-checks-basic-005-ab-analysis.log"), "w",
        encoding="utf-8", newline="\n").write(out + "\n")
print(out)
sys.exit(0 if all_ok else 1)
