# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-BENCH-002 行为等价比对器 v2（结构化记录层）。

为什么不用逐行 diff（本批实证 2026-10-13）：
  台架日志里有两类**跨进程不可复现**内容，逐行/骨架比对必然假红：
    ① 逐帧 dump（`[台架帧]` / `[台架刹帧]`）—— 相位噪声（base1 8528 行 vs base2 8524 行，
       difflib 报 12368 行差异，实则只是 2 行 slip 掩码宽度 + 墙钟诊断块移位）；
    ② `[车辆] t=` 诊断块 —— 按墙钟打印（AGENTS §4.3 双稳态同源）。
  真正可复现的是**结论记录**：24 格摘要 / 矩阵 / 判定行（判定行的「位于 steer=.. v0=..」
  格位标识明确标注「仅信息量」且两跑会翻，比对时剔除）。

比对对象（结构化）：
  steerbench：cells[(steer,v0)]=11 字段；matrix[steer]=4 值；verdict=[有效格, 满舵@40, 格内最大相对标准差]
  brakebench：reps[(v0,rep)]=9 字段；matrix[v0]=3 值；verdict

判据（数据驱动，不预设阈值）：
  先跑同代码两跑（base1 vs base2）得「超容差字段集合」= 噪声底；
  再跑 ctrl vs base1 —— **超容差字段必须是噪声底集合的子集**，多出任何一个即 FAIL。

用法：
  python split-checks-bench-cmp.py <基准.log> <标签> <对照.log> [<对照2.log> ...]
"""
import io
import re
import sys

ABS_EPS = 0.05   # 显示精度量级的绝对容差

# --- 记录抽取 -------------------------------------------------------------

STEER_CELL = re.compile(r'^\[自检\] 台架 steer=([-+0-9.]+) v0=\s*([0-9]+) → (.*)$')
STEER_MROW = re.compile(r'^\[自检\] 台架\s+([0-9.]+)\s+([-+0-9.]+)\s+([-+0-9.]+)\s+([-+0-9.]+)\s+([-+0-9.]+)\s*$')
STEER_VERD = re.compile(r'^\[自检\] 台架\s*[✔✘]\s*(.*)$')
BRAKE_REP = re.compile(r'^\[自检\] 台架刹 v0=\s*([0-9]+) 第([0-9])次 → (.*)$')
BRAKE_MROW = re.compile(r'^\[自检\] 台架刹\s+([0-9.]+(?:\.0)?)\s+((?:[-+0-9.]+\s*)+)$')
BRAKE_VERD = re.compile(r'^\[自检\] 台架刹\s*[✔✘]\s*(.*)$')

NUM_RE = re.compile(r'[-+]?[0-9]+\.?[0-9]*(?:[eE][-+]?[0-9]+)?')

# 明确的信息行（含会漂的说明性数字），不进比对
INFO_PREFIX = ('[自检] 台架 启动', '[自检] 台架 摆位', '[自检] 台架 提示',
               '[自检] 台架 ===', '[自检] 台架刹 启动', '[自检] 台架刹 摆位',
               '[自检] 台架刹 a_brake 定义', '[自检] 台架刹 μ 自核',
               '[自检] 台架刹 注', '[自检] 台架刹 提示', '[自检] 台架刹 ===')


def nums(s):
    return [float(m.group(0)) for m in NUM_RE.finditer(s)]


def parse(path):
    rec = {}
    for ln in io.open(path, encoding='utf-8', errors='replace').read().replace('\r\n', '\n').splitlines():
        if not ln.startswith('[自检]'):
            continue
        if ln.startswith(INFO_PREFIX):
            continue
        m = STEER_CELL.match(ln)
        if m:
            rec[('steer_cell', float(m.group(1)), int(m.group(2)))] = nums(m.group(3))
            continue
        m = STEER_MROW.match(ln)
        if m:
            rec[('steer_mrow', float(m.group(1)))] = [float(m.group(i)) for i in range(2, 6)]
            continue
        m = STEER_VERD.match(ln)
        if m:
            rec[('steer_verdict',)] = nums(m.group(1).split('位于')[0])
            continue
        m = BRAKE_REP.match(ln)
        if m:
            rec[('brake_rep', int(m.group(1)), int(m.group(2)))] = nums(m.group(3))
            continue
        m = BRAKE_MROW.match(ln)
        if m:
            rec[('brake_mrow', float(m.group(1)))] = nums(m.group(2))
            continue
        m = BRAKE_VERD.match(ln)
        if m:
            rec[('brake_verdict',)] = nums(m.group(1).split('位于')[0])
            continue
    return rec


def key_str(k):
    return '%s%s' % (k[0], k[1:])


def diff_records(a, b):
    """返回 (结构差异列表, 超容差列表[(key, idx, va, vb, |Δ|)])"""
    struct, bad = [], []
    ka, kb = set(a), set(b)
    for k in sorted(ka - kb):
        struct.append('仅基准有: %s' % key_str(k))
    for k in sorted(kb - ka):
        struct.append('仅对照有: %s' % key_str(k))
    for k in sorted(ka & kb):
        va, vb = a[k], b[k]
        if len(va) != len(vb):
            struct.append('字段数不同 %s: %d vs %d' % (key_str(k), len(va), len(vb)))
            continue
        for i, (x, y) in enumerate(zip(va, vb)):
            if abs(x - y) > ABS_EPS:
                bad.append((key_str(k), i, x, y, abs(x - y)))
    return struct, bad


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    base_path, tag = sys.argv[1], sys.argv[2]
    base = parse(base_path)
    print('=== %s | 基准 %s | 记录 %d 条 ===' % (tag, base_path.replace('\\', '/').split('/')[-1], len(base)))
    rc = 0
    for other in sys.argv[3:]:
        o = parse(other)
        struct, bad = diff_records(base, o)
        name = other.replace('\\', '/').split('/')[-1]
        print('--- %s  (记录 %d 条) ---' % (name, len(o)))
        if struct:
            print('  结构差异 %d 项：' % len(struct))
            for s in struct[:20]:
                print('    ' + s)
        print('  超容差字段 %d 项 / 共 %d 项' % (len(bad), sum(len(v) for v in base.values())))
        for k, i, x, y, d in sorted(bad, key=lambda t: -t[4])[:25]:
            print('    %-28s 字段#%-2d  %-12g vs %-12g  |Δ|=%.4g' % (k, i, x, y, d))
        ok = (not struct) and (len(bad) == 0)
        print('  判定: %s' % ('PASS（无超容差字段）' if ok else 'SEE-LIST（见上面清单）'))
        if struct:
            rc = 1
    return rc


if __name__ == '__main__':
    sys.exit(main())
