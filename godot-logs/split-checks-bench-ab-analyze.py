# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-BENCH-002 A/B 复现分布分析（组内极差 vs 跨组极差）。

问题：台架结论矩阵有「单格双稳态」——同代码两跑也会有 1 格越 1%（v1 实测 45.58 vs 45.05）。
      只跑 2+1 份样本无法把「迁移引入的差异」与「进程噪声」分开。
方法：采集 mig 组（迁移后）×N 与 ctrl 组（HEAD）×M，逐格比较：
      · 组内极差（同代码）= 噪声底；
      · 跨组差（mig 均值 vs ctrl 均值）= 待判定的信号；
      · 判定：跨组差 ≤ max(两组组内极差, 显示精度 0.05 绝对值) → 迁移未引入可辨识差异。

被比对对象（与项目 steerbench-repro.ps1 同源：6×4 lat_peak 矩阵）：
  steerbench: 6×4 lat_peak 均值矩阵 + 每格有效帧数
  brakebench: 4 初速 × 3 重复的 a_brake 表 + 停距 + 有效帧

用法：python split-checks-bench-ab-analyze.py
"""
import io
import re
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
STEERS = [0.050, 0.100, 0.150, 0.200, 0.300, 0.450]
SPEEDS = [40, 80, 120, 160]
EPS_ABS = 0.05   # 显示精度量级

# 组定义：mig = 迁移后（bench.gd 生效）；ctrl = HEAD（bench 内联在 main.gd）
MIG_STEER = ['split-checks-bench-ab-steerbench-base1.log', 'split-checks-bench-ab-steerbench-base2.log',
             'split-checks-bench-ab2-steerbench-s3.log']
CTRL_STEER = ['split-checks-bench-ab-steerbench-ctrl.log', 'split-checks-bench-ab2-steerbench-c2.log']
MIG_BRAKE = ['split-checks-bench-ab2-brakebench-k1.log', 'split-checks-bench-ab2-brakebench-k2.log']
CTRL_BRAKE = ['split-checks-bench-ab2-brakebench-j1.log', 'split-checks-bench-ab2-brakebench-j2.log']
HIST_STEER = ['l4-steerbench-repro-A.log', 'l4-steerbench-repro-B.log', 'l4-steerbench-repro-C.log']


def lines(name):
    p = os.path.join(HERE, name)
    if not os.path.exists(p):
        return None
    return io.open(p, encoding='utf-8', errors='replace').read().replace('\r\n', '\n').splitlines()


def steer_matrix(name):
    """6×4 lat_peak 均值矩阵"""
    ls = lines(name)
    if ls is None:
        return None
    inm = False
    rows = 0
    res = {}
    for ln in ls:
        if not inm:
            if '舵角\\速度' in ln:
                inm = True
            continue
        if rows >= 6:
            break
        m = re.match(r'^\[自检\]\s*台架\s+([0-9]+\.[0-9]+)\s+([0-9]+\.[0-9]+)\s+([0-9]+\.[0-9]+)\s+([0-9]+\.[0-9]+)\s+([0-9]+\.[0-9]+)\s*$', ln)
        if m:
            s = float(m.group(1))
            for c in range(4):
                res[(s, SPEEDS[c])] = float(m.group(c + 2))
            rows += 1
    return res if rows >= 6 else None


def steer_valid(name):
    """每格有效帧 a（`有效帧=47/84`）"""
    ls = lines(name)
    if ls is None:
        return None
    res = {}
    for ln in ls:
        m = re.match(r'^\[自检\] 台架 steer=([-+0-9.]+) v0=\s*([0-9]+) → .*有效帧=([0-9]+)/([0-9]+)', ln)
        if m:
            res[(float(m.group(1)), int(m.group(2)))] = (int(m.group(3)), int(m.group(4)))
    return res


def brake_table(name):
    """{(v0, rep): (a_brake, 峰值, 全程, 停距, 刹时, 首帧v, 稳态帧, 有效帧a, 有效帧b)}"""
    ls = lines(name)
    if ls is None:
        return None
    res = {}
    for ln in ls:
        m = re.match(r'^\[自检\] 台架刹 v0=\s*([0-9]+) 第([0-9])次 → (.*)$', ln)
        if m:
            nums = [float(x) for x in re.findall(r'[-+]?[0-9]+\.?[0-9]*', m.group(3))]
            res[(int(m.group(1)), int(m.group(2)))] = nums
    return res


def load_group(names, parser):
    out = []
    for n in names:
        d = parser(n)
        if d is None:
            print('  !! 缺日志: %s' % n)
        else:
            out.append((n, d))
    return out


def analyze(tag, mig, ctrl, keyfn, keys, fmt):
    print('')
    print('================ %s ================' % tag)
    print('mig 组 %d 份: %s' % (len(mig), ', '.join(n.replace('split-checks-bench-ab', '') for n, _ in mig)))
    print('ctrl 组 %d 份: %s' % (len(ctrl), ', '.join(n.replace('split-checks-bench-ab', '') for n, _ in ctrl)))
    if not mig or not ctrl:
        print('  样本不足，跳过')
        return
    worst_cross = 0.0
    worst_cross_at = ''
    worst_within = 0.0
    worst_within_at = ''
    viol = []
    print('')
    print('%-24s %-26s %-20s %-22s %s' % ('格', 'mig 值', 'ctrl 值', '组内极差(MIG/CTRL)', '跨组差'))
    for k in keys:
        mv = [d.get(k) for _, d in mig]
        cv = [d.get(k) for _, d in ctrl]
        if any(v is None for v in mv) or any(v is None for v in cv):
            print('%-24s （缺数据）' % str(k))
            continue
        mo = float(sum(mv) / len(mv))
        co = float(sum(cv) / len(cv))
        rr_m = (max(mv) - min(mv)) / mo * 100.0 if mo > 1e-9 else 0.0
        rr_c = (max(cv) - min(cv)) / co * 100.0 if co > 1e-9 else 0.0
        cross_abs = abs(mo - co)
        cross_rel = cross_abs / max(abs(mo), abs(co)) * 100.0 if max(abs(mo), abs(co)) > 1e-9 else 0.0
        # 噪声底 = 两组组内极差的绝对值上界 + 显示精度
        floor_abs = max(max(mv) - min(mv), max(cv) - min(cv), EPS_ABS)
        flag = ''
        if cross_abs > floor_abs:
            flag = '  ← 超组内噪声底'
            viol.append((k, mv, cv, mo, co, cross_abs, floor_abs))
        if cross_rel > worst_cross:
            worst_cross = cross_rel
            worst_cross_at = str(k)
        w = max(rr_m, rr_c)
        if w > worst_within:
            worst_within = w
            worst_within_at = str(k)
        print('%-24s %-26s %-20s %9.2f%% / %-6.2f%%  %6.2f%%%s' % (
            fmt(k), ' '.join('%.3f' % v for v in mv), ' '.join('%.3f' % v for v in cv),
            rr_m, rr_c, cross_rel, flag))
    print('')
    print('最大跨组差 = %.4f%% @ %s' % (worst_cross, worst_cross_at))
    print('最大组内极差 = %.4f%% @ %s   （同代码噪声底的上界）' % (worst_within, worst_within_at))
    if viol:
        print('✘ 有 %d 格跨组差超过「两组组内极差 + 显示精度」：' % len(viol))
        for k, mv, cv, mo, co, ca, fl in viol:
            print('   %s  mig=%s(%.3f) ctrl=%s(%.3f)  |Δ|=%.3f > 噪声底 %.3f'
                  % (fmt(k), ['%.3f' % v for v in mv], mo, ['%.3f' % v for v in cv], co, ca, fl))
    else:
        print('✔ 全部格的跨组差都 ≤ 组内极差（同代码噪声底）→ 迁移未引入可辨识差异')


def main():
    mig = load_group(MIG_STEER, steer_matrix)
    ctrl = load_group(CTRL_STEER, steer_matrix)
    keys = [(s, v) for s in STEERS for v in SPEEDS]
    analyze('steerbench lat_peak 矩阵（6×4）', mig, ctrl, None, keys,
            lambda k: 'steer=%.3f v0=%3d' % k)

    print('')
    print('---- 参考：历史基线（2026-10-11 repro A/B/C，同代码 3 份） ----')
    hist = load_group(HIST_STEER, steer_matrix)
    if len(hist) >= 2:
        analyze('历史基线 lat_peak 矩阵', hist[:1], hist[1:], None, keys,
                lambda k: 'steer=%.3f v0=%3d' % k)

    # brakebench
    def brake_first(d):
        return {k: v[0] for k, v in d.items()}
    migb = [(n, brake_first(d)) for n, d in load_group(MIG_BRAKE, brake_table)]
    ctrlb = [(n, brake_first(d)) for n, d in load_group(CTRL_BRAKE, brake_table)]
    keysb = [(v, r) for v in [40, 60, 80, 100] for r in [1, 2, 3]]
    analyze('brakebench a_brake（4 初速 × 3 重复）', migb, ctrlb, None, keysb,
            lambda k: 'v0=%3d 第%d次' % k)

    # 有效帧结构
    print('')
    print('================ 结构：steerbench 每格有效帧 ================')
    mg = load_group(MIG_STEER, steer_valid)
    cg = load_group(CTRL_STEER, steer_valid)
    bad = 0
    for s in STEERS:
        for v in SPEEDS:
            k = (s, v)
            vs = sorted(set(d.get(k) for _, d in mg + cg if d.get(k) is not None))
            if len(vs) > 1:
                bad += 1
                print('  steer=%.3f v0=%3d  有效帧不同: %s' % (s, v, vs))
    if bad == 0:
        print('  ✔ 全部 24 格的有效帧数（有效/总）在 mig 与 ctrl 的全部样本里完全一致')
    else:
        print('  ⚠ %d 格有效帧数有跨样本差异（墙钟/剔除边界噪声，按噪声底判读）' % bad)

    # 逐帧分歧起点（相位噪声层）
    print('')
    print('================ 逐帧 dump 的分歧起点（相位噪声层） ================')

    def frames(name):
        ls = lines(name)
        if ls is None:
            return None
        return [l for l in ls if l.startswith('[台架帧]')]

    def onset(a, b):
        fa, fb = frames(a), frames(b)
        if fa is None or fb is None:
            return None
        n = min(len(fa), len(fb))
        first = None
        nd = 0
        for i in range(n):
            if fa[i] != fb[i]:
                nd += 1
                if first is None:
                    first = i
        pre_ok = all(fa[i] == fb[i] for i in range(min(539, n)))
        return len(fa), len(fb), first, nd, pre_ok

    pairs = [('mig×mig', MIG_STEER[0], MIG_STEER[1]),
             ('mig×mig', MIG_STEER[0], MIG_STEER[2]),
             ('ctrl×ctrl', CTRL_STEER[0], CTRL_STEER[1]),
             ('mig×ctrl', MIG_STEER[0], CTRL_STEER[0]),
             ('mig×ctrl', MIG_STEER[1], CTRL_STEER[0]),
             ('mig×ctrl', MIG_STEER[2], CTRL_STEER[1])]
    for tag, a, b in pairs:
        r = onset(a, b)
        if r is None:
            print('  %-10s %s vs %s  （缺日志）' % (tag, a[-22:], b[-22:]))
            continue
        na, nb, first, nd, pre_ok = r
        print('  %-10s %-34s 帧 %d/%d 不同=%d 首差@%s  前539帧逐字节相同=%s'
              % (tag, b[-34:], na, nb, nd, first, pre_ok))
    return 0


if __name__ == '__main__':
    sys.exit(main())
