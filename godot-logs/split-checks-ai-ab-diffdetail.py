# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-AI-003 · A/B 差异细目抽取器。

复用 analyze3.py 的归一化口径（墙钟 / 完成帧 / 进程内对象 ID），
只做一件事：把指定 (check, 左样本, 右样本) 的**非 equal 行**按 opcode 打印出来，
供 A/B 报告逐字引用。退出码恒 0。

用法：
  python split-checks-ai-ab-diffdetail.py aidiag c1 c2
  python split-checks-ai-ab-diffdetail.py avoid  m1 m2
  python split-checks-ai-ab-diffdetail.py aistart c1 c2
  python split-checks-ai-ab-diffdetail.py obstacles m1 c2
"""
import io
import os
import re
import sys
import difflib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.path.join(ROOT, "godot-logs")
WALL = re.compile(r"对手用时 (\d+\.\d+) 秒（(\d+) 帧）")
OBJID = re.compile(r"#\d+")


def load(pass_, check):
    p = os.path.join(LOGDIR, "split-checks-ai-ab-%s-%s.log" % (pass_, check))
    if not os.path.exists(p):
        return None
    txt = io.open(p, "r", encoding="utf-8", errors="replace").read()
    out = []
    for l in txt.replace("\r\n", "\n").split("\n"):
        if "[自检]" not in l and "[CHECK]" not in l:
            continue
        l = WALL.sub("对手用时 <WALL> 秒（<FRAMES> 帧）", l)
        out.append(OBJID.sub("#<ID>", l).rstrip())
    return out


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 0
    check, left, right = sys.argv[1:4]
    a = load(left, check)
    b = load(right, check)
    print("==== %s : %s  vs  %s ====" % (check, left, right))
    if a is None or b is None:
        print("缺日志：%s=%s %s=%s" % (left, a is not None, right, b is not None))
        return 0
    print("行数：%s=%d  %s=%d" % (left, len(a), right, len(b)))
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    ngroup = 0
    nline = 0
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == "equal":
            continue
        ngroup += 1
        nline += max(i2 - i1, j2 - j1)
        print("  [%s] %s[%d:%d] / %s[%d:%d]" % (tag, left, i1, i2, right, j1, j2))
        for x in a[i1:i2]:
            print("      - %s" % x)
        for y in b[j1:j2]:
            print("      + %s" % y)
    print("非 equal 行数 = %d（%d 组）" % (nline, ngroup))
    return 0


sys.exit(main())
