# -*- coding: utf-8 -*-
# SPLIT-CHECKS-BENCH-002 A/B 复核比对（修正版判据，2026-10-13）。
#
# 背景：舞步主脚本（split-checks-bench-ab-dance.ps1）内嵌的比对逻辑有两处方法论
# 缺陷，在 steerbench base1-vs-base2（同代码两跑）上自我暴露：
#   ① 数值Mask 后不归一白空格：`%5.1f` 的 slip 在跨过 10 时格式宽度从 2 空格变 1
#      空格（10.4 → " 10.4" vs 9.6 → "  9.6"），Mask 后骨架多/少一个空格 → 假
#      「结构差异」。修法：Mask 后把连续空白折叠成一个空格再比骨架。
#   ② 相对极差对近零值放大：0.01 vs 0 → 100%。修法：采用本项目 repro 脚本的同款
#      约定（steerbench-repro.ps1 / brakebench-repro.ps1 的 $ZeroMean=0.05）——
#      max(|a|,|b|) < 0.05 的字段对跳过相对极差计算，只累计最大绝对差并单独报告。
# 这两处都是**比较方法**的修正，不是迁移判据的放宽：修正后骨架判据更稳（不再被
# 格式宽度伪影骗到），数值判据改用项目自己的跨进程复现口径。
#
# 本脚本只读舞步已落盘的日志，不重跑 Godot、不碰 git。对每个 check 的两组比对
# （base1-vs-base2 = 噪声底；ctrl-vs-after = 行为等价）输出：
#   · 台架证据行数 / 骨架差异数（修正后）
#   · 数值极差：汇总行（[自检] 台架*，测量结果）与逐帧行（[台架帧]/[台架刹帧]，
#     原始trace）分开统计；近零跳过对的绝对差单独报告
#   · 判据：汇总行极差 ≤ min(底, 1%)；逐帧行极差 ≤ 底（原始 trace 的跨进程噪声
#     由实测底界定，1% 是本项目对**测量结果**的复现阈值，不外加于 trace）
import io
import re
import sys

LOGS = r'D:\桌面\DSH-Work\data-analysis\godot-logs'
OUT = LOGS + r'\split-checks-bench-ab-recompare.log'
CHECKS = ['steerbench', 'brakebench']
PAIRS = [('base1', 'base2', '噪声底'), ('ctrl', 'after', '行为等价')]

BENCH_RE = re.compile(r'^\[台架帧\]|^\[台架刹帧\]|^\[自检\] 台架|^\[CHECK\]')
FRAME_RE = re.compile(r'^\[台架帧\]|^\[台架刹帧\]')
NUM_RE = re.compile(r'[-+]?[0-9]+\.?[0-9]*')
ZERO_MEAN = 0.05          # 同 repro 脚本 $ZeroMean：近零字段对跳过相对极差
REPRO_LIMIT = 0.01        # 同 repro 脚本 $ReproLimit：测量结果跨进程复现阈值

lines_out = []


def log(s=''):
    print(s)
    lines_out.append(s)


def read_bench(path, frame_only=False, summary_only=False):
    txt = io.open(path, encoding='utf-8').read().split('\n')
    out = []
    for l in txt:
        if not BENCH_RE.match(l):
            continue
        if frame_only and not FRAME_RE.match(l):
            continue
        if summary_only and FRAME_RE.match(l):
            continue
        out.append(re.sub(r'#[0-9]+', '#ID', l))
    return out


def skeleton(lines):
    res = []
    for l in lines:
        m = NUM_RE.sub('#', l)
        m = re.sub(r'\s+', ' ', m).strip()
        res.append(m)
    return res


def spread(a, b):
    """返回 (worst_rel, where_rel, worst_abs_nearzero, skipped_n)。行数须已相等。"""
    worst = 0.0
    where = '（无数值差异）'
    abs_nz = 0.0
    skipped = 0
    for i in range(len(a)):
        na = [float(x) for x in NUM_RE.findall(a[i])]
        nb = [float(x) for x in NUM_RE.findall(b[i])]
        if len(na) != len(nb):
            return None, ('证据行L%d 数值个数不同（%d vs %d）：%s' % (i + 1, len(na), len(nb), a[i])), None, None
        for k in range(len(na)):
            d = abs(na[k] - nb[k])
            m = max(abs(na[k]), abs(nb[k]))
            if m < ZERO_MEAN:
                skipped += 1
                abs_nz = max(abs_nz, d)
                continue
            r = d / m
            if r > worst:
                worst = r
                where = '证据行L%d 字段%d: %s vs %s' % (i + 1, k + 1, na[k], nb[k])
    return worst, where, abs_nz, skipped


def compare_pair(check, tagA, tagB, label):
    pa = '%s/split-checks-bench-ab-%s-%s.log' % (LOGS, check, tagA)
    pb = '%s/split-checks-bench-ab-%s-%s.log' % (LOGS, check, tagB)
    log('== [%s] %s vs %s（%s）' % (check, tagA, tagB, label))
    la = read_bench(pa)
    lb = read_bench(pb)
    log('   台架证据行：%d vs %d' % (len(la), len(lb)))
    if len(la) != len(lb):
        log('   ✘ 行数不同 —— 结构不等价')
        return False
    ska, skb = skeleton(la), skeleton(lb)
    skdiff = [i + 1 for i in range(len(ska)) if ska[i] != skb[i]]
    log('   骨架差异（数值Mask+空白折叠后）：%d 处' % len(skdiff))
    if skdiff:
        for i in skdiff[:5]:
            log('      L%d: %s' % (i, la[i - 1]))
            log('      L%d: %s' % (i, lb[i - 1]))
    # 汇总行（测量结果）
    sa, sb = read_bench(pa, summary_only=True), read_bench(pb, summary_only=True)
    w, wh, an, sn = spread(sa, sb)
    log('   汇总行（%d 行）数值极差：%s（%s）；近零跳过 %d 对（最大绝对差 %s）'
        % (len(sa), ('%.4f%%' % (w * 100)) if w is not None else 'n/a', wh, sn, an))
    # 逐帧行（原始 trace）
    fa, fb = read_bench(pa, frame_only=True), read_bench(pb, frame_only=True)
    w2, wh2, an2, sn2 = spread(fa, fb)
    log('   逐帧行（%d 行）数值极差：%s（%s）；近零跳过 %d 对（最大绝对差 %s）'
        % (len(fa), ('%.4f%%' % (w2 * 100)) if w2 is not None else 'n/a', wh2, sn2, an2))
    return w, w2, len(skdiff)


log('================ SPLIT-CHECKS-BENCH-002 A/B 复核比对（修正版判据）================')
log('判据：骨架（数值Mask+空白折叠）零差异；汇总行极差 ≤ min(实测底, 1%)；逐帧行极差 ≤ 实测底。')
log('近零约定：max(|a|,|b|) < 0.05 的字段对跳过相对极差（同 repro 脚本 $ZeroMean），绝对差单独报告。')
log('')

results = {}
for check in CHECKS:
    log('---------------- %s ----------------' % check)
    floors = {}
    for tagA, tagB, label in PAIRS:
        r = compare_pair(check, tagA, tagB, label)
        if r is False:
            results[(check, label)] = (False, '结构不等价')
            continue
        w_sum, w_frame, skd = r
        ok = (skd == 0) and (w_sum is not None) and (w_frame is not None)
        if label == '噪声底':
            floors['sum'] = w_sum if w_sum is not None else 0.0
            floors['frame'] = w_frame if w_frame is not None else 0.0
            log('   → 噪声底记录：汇总行 %s / 逐帧行 %s' %
                ('%.4f%%' % (floors['sum'] * 100), '%.4f%%' % (floors['frame'] * 100)))
            results[(check, label)] = (ok, '底=汇总%.4f%%/逐帧%.4f%%' % (floors['sum'] * 100, floors['frame'] * 100))
        else:
            if 'sum' not in floors:
                log('   （无噪声底数据，跳过判定）')
                results[(check, label)] = (False, '无噪声底')
                continue
            lim_sum = min(floors['sum'], REPRO_LIMIT)
            pass_sum = (w_sum is not None) and (w_sum <= lim_sum)
            pass_frame = (w_frame is not None) and (w_frame <= floors['frame'])
            verdict = pass_sum and pass_frame and (skd == 0)
            log('   判定：汇总行极差 %s ≤ min(底 %s, 1%%) = %s → %s；逐帧行极差 %s ≤ 底 %s → %s；骨架 %d 处 → %s'
                % ('%.4f%%' % (w_sum * 100) if w_sum is not None else 'n/a',
                   '%.4f%%' % (floors['sum'] * 100), '%.4f%%' % (lim_sum * 100),
                   'PASS' if pass_sum else 'FAIL',
                   '%.4f%%' % (w_frame * 100) if w_frame is not None else 'n/a',
                   '%.4f%%' % (floors['frame'] * 100), 'PASS' if pass_frame else 'FAIL',
                   skd, 'PASS' if skd == 0 else 'FAIL'))
            results[(check, label)] = (verdict, '汇总%.4f%%/逐帧%.4f%%' % (
                (w_sum or 0) * 100, (w_frame or 0) * 100))
    log('')

log('---------------- 总判据 ----------------')
allok = True
for (check, label), (ok, crit) in sorted(results.items()):
    log('  [%s/%s] %s（%s）' % (check, label, 'PASS' if ok else 'FAIL', crit))
    if not ok:
        allok = False
log('================ %s ================' % ('✔ 全部通过' if allok else '✘ 有未过项 —— 停下人工核，不许调参掩盖'))

io.open(OUT, 'w', encoding='utf-8').write('\n'.join(lines_out) + '\n')
print('已写 %s' % OUT)
sys.exit(0 if allok else 1)
