# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-ENVPHYS-004 A/B 差异细目抽取器。

用法：python godot-logs/split-checks-envphys-ab-diffdetail.py <check> <passA> <passB>
例：  python godot-logs/split-checks-envphys-ab-diffdetail.py stuck m1 c2

口径与 analyze.py 一致：只取 [自检]/[CHECK] 行；归一化 Hz/ms/秒 数字、帧计数、对象 ID。
输出两组之间非 equal 的全部行（opcode + 行号 + 内容）。
"""
import io
import os
import re
import sys
import difflib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOGDIR = os.path.join(ROOT, "godot-logs")

NORM = [
    (re.compile(r"(\d+\.\d+) Hz"), "<HZ> Hz"),
    (re.compile(r"(\d+\.\d+) ms"), "<MS> ms"),
    (re.compile(r"(\d+\.\d+) 秒"), "<SEC> 秒"),
    (re.compile(r"(\d+) 帧"), "<N> 帧"),
    (re.compile(r"#\d+"), "#<ID>"),
]


def load(p, check):
    pth = os.path.join(LOGDIR, "split-checks-envphys-ab-%s-%s.log" % (p, check))
    txt = io.open(pth, "r", encoding="utf-8", errors="replace").read()
    out = []
    for l in txt.replace("\r\n", "\n").split("\n"):
        if "[自检]" not in l and "[CHECK]" not in l:
            continue
        for rx, rep in NORM:
            l = rx.sub(rep, l)
        out.append(l.rstrip())
    return out


if len(sys.argv) != 4:
    print("用法：python split-checks-envphys-ab-diffdetail.py <check> <passA> <passB>")
    sys.exit(2)

check, pa, pb = sys.argv[1], sys.argv[2], sys.argv[3]
A, B = load(pa, check), load(pb, check)
print("---- %s  %s vs %s （A %d 行 / B %d 行）----" % (check, pa, pb, len(A), len(B)))
sm = difflib.SequenceMatcher(a=A, b=B, autojunk=False)
n = 0
for tag, i1, i2, j1, j2 in sm.get_opcodes():
    if tag == "equal":
        continue
    n += max(i2 - i1, j2 - j1)
    print("  [%s] A[%d:%d] B[%d:%d]" % (tag, i1, i2, j1, j2))
    for k in range(i1, i2):
        print("    - %s" % A[k])
    for k in range(j1, j2):
        print("    + %s" % B[k])
print("非 equal 行数 = %d（%d 组）" % (n, sum(
    1 for tag, *_ in sm.get_opcodes() if tag != "equal")))
