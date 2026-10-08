# -*- coding: utf-8 -*-
# L4 变道走廊 / 目标翻转 取证汇总（开发期只读工具：解析日志，不碰游戏代码）。
#
# 为什么不用一条大正则：[DEBUG-L4] 行里混了中文、括号、破折号（blocker=-1.0(—)），
# 逐条正则极难维护；改成**按 key= 标签取值**（_kv），新增字段不会把解析打翻。
#
# 用法： python tools/l4_transition_report.py <log> [log...]
import io, re, sys, statistics as st

NUM = r'[-+]?[0-9]*\.?[0-9]+'


def _kv(line, spec):
    out = {}
    for key, kind in spec:
        m = re.search(re.escape(key) + r'(' + NUM + r')', line)
        if kind == 'f':
            out[key] = float(m.group(1)) if m else float('nan')
        elif kind == 'i':
            out[key] = int(float(m.group(1))) if m else -1
        else:
            out[key] = (m.group(1) if m else '?')
    return out


LANE_SPEC = [('f=', 'i'), ('arc=', 'f'), ('decision=', 'f'), ('cur_lat=', 'f'), ('target=', 'f'),
             ('delta=', 'f'), ('rate=', 'f'), ('required=', 'f')]
TRANS_SPEC = [('f=', 'i'), ('arc=', 'f'), ('current=', 'f'), ('target=', 'f'), ('delta=', 'f'),
              ('sample_lane=', 'f'), ('sample_arc_dist=', 'f')]
IMPACT_SPEC = [('n=', 'i'), ('f=', 'i'), ('arc=', 'f'), ('lat=', 'f'), ('v_before=', 'f'),
               ('v_after=', 'f'), ('target_lane=', 'f')]
STUCK_SPEC = [('STUCK#', 'i'), ('f=', 'i'), ('arc=', 'f'), ('lat=', 'f'), ('speed=', 'f'),
              ('heading_error=', 'f')]


def med(v):
    return st.median(v) if v else float('nan')


def flag(line, key):
    m = re.search(re.escape(key) + r'(true|false)', line)
    return (m.group(1) == 'true') if m else None


def analyse(path):
    t = io.open(path, 'r', encoding='utf-8', errors='replace').read()
    lines = t.split(chr(10))
    lane = [_kv(l, LANE_SPEC) for l in lines if '[DEBUG-L4] LANE f=' in l]
    trans = [dict(_kv(l, TRANS_SPEC), tb=flag(l, 'transition_blocked='))
             for l in lines if '[DEBUG-L4] TRANSITION_FULL' in l]
    impacts = [dict(_kv(l, IMPACT_SPEC), tb=flag(l, 'transition_blocked='))
               for l in lines if '[DEBUG-L4] IMPACT ' in l]
    stuck = [_kv(l, STUCK_SPEC) for l in lines
             if '[DEBUG-L4] STUCK#' in l and 'OBST' not in l and 'WINDOW' not in l]

    o = {'path': path, 'lane_lines': len(lane), 'transition_full': len(trans),
         'impacts': impacts, 'transitions': trans, 'stuck': stuck, 'lane': lane}
    m = re.search(r'跑圈结束：用时 ([\d.]+)s 完成 (\d+) 圈 复位次数=(\d+)', t)
    o['run'] = ('%ss %s laps resets=%s' % m.groups()) if m else 'INCOMPLETE'
    m = re.search(r'\[自检\] 卡住事件：(\d+) 次', t)
    o['stuck_events'] = int(m.group(1)) if m else -1

    deltas, times = [], []
    prev = None
    for r in lane:
        tgt = r['target=']
        if prev is None:
            prev = tgt
            continue
        if abs(tgt - prev) > 0.05:
            deltas.append(tgt - prev)
            times.append(r['f='] / 120.0)
            prev = tgt
    gaps = [times[i] - times[i - 1] for i in range(1, len(times))]
    o['lane_switch_count'] = len(deltas)
    o['max_lane_delta'] = max((abs(x) for x in deltas), default=float('nan'))
    o['median_lane_delta'] = med([abs(x) for x in deltas])
    o['big_switches'] = sum(1 for x in deltas if abs(x) > 2.0)
    o['fast_switches'] = sum(1 for g in gaps if g < 0.5)
    o['gap_min'] = min(gaps) if gaps else float('nan')
    o['gap_median'] = med(gaps)
    o['direction_reversal'] = sum(1 for i in range(1, len(deltas)) if deltas[i] * deltas[i - 1] < 0)

    o['impact_count'] = len(impacts)
    o['impact_corridor_blocked'] = sum(1 for i in impacts if i['tb'] is True)
    tb = [x for x in trans if x['tb'] is True]
    o['transition_blocked_n'] = len(tb)
    o['transition_clear_n'] = len(trans) - len(tb)
    blockers = {}
    for l in lines:
        if '[DEBUG-L4] TRANSITION_FULL' in l and 'transition_blocked=true' in l:
            m = re.search(r'blocker=(\S+)', l)
            if m:
                blockers[m.group(1)] = blockers.get(m.group(1), 0) + 1
    o['blockers'] = blockers
    o['impact_v_before_max'] = max((i['v_before='] for i in impacts), default=float('nan'))

    for pat, key in [(r'SUMMARY L4TSWITCH (.*)', 'summary_switch'),
                     (r'SUMMARY L4RATE (.*)', 'summary_rate'),
                     (r'SUMMARY L4RATE_BUCKET (.*)', 'summary_bucket')]:
        m = re.search(pat, t)
        o[key] = m.group(1) if m else None

    nar = []
    for s in stuck:
        near = [r for r in lane if abs(r['f='] - s['f=']) <= 240]
        tgts = sorted({round(r['target='], 2) for r in near})
        cur = [round(r['cur_lat='], 2) for r in near]
        lo = min(cur) if cur else float('nan')
        hi = max(cur) if cur else float('nan')
        nar.append((s['STUCK#'], s['f='], s['arc='], s['lat='], s['heading_error='], lo, hi, tgts[:6]))
    o['narrative'] = nar
    return o


def f2(x, n=2):
    try:
        return ('%.' + str(n) + 'f') % x
    except Exception:
        return str(x)


def main(paths):
    rows = [analyse(p) for p in paths]
    print()
    print('=' * 118)
    print('L4 lane-transition corridor / lane-target-switch forensics')
    print('=' * 118)
    print(' | '.join(['log', 'stuck', 'impacts', 'corr_blk@impact', 'TRANS blk/clear',
                      'lane_switch', 'max_delta', 'median_delta', 'gap_min(s)', 'reversals']))
    for r in rows:
        print(' | '.join([
            r['path'].split(chr(92))[-1], str(r['stuck_events']), str(r['impact_count']),
            '%d/%d' % (r['impact_corridor_blocked'], r['impact_count']),
            '%d/%d' % (r['transition_blocked_n'], r['transition_clear_n']),
            str(r['lane_switch_count']), f2(r['max_lane_delta']), f2(r['median_lane_delta']),
            f2(r['gap_min']), str(r['direction_reversal'])]))
    print()
    for r in rows:
        print('---- ' + r['path'].split(chr(92))[-1] + ' : ' + r['run'])
        print('   blockers on blocked corridor : ' + str(r['blockers']))
        print('   in-game summary switch       : ' + str(r['summary_switch']))
        print('   in-game summary rate         : ' + str(r['summary_rate']))
        print('   in-game summary rate buckets : ' + str(r['summary_bucket']))
        print('   lane-report lines            : %d' % r['lane_lines'])
        for n in r['narrative']:
            print('   STUCK#%d f=%d arc=%.1f lat=%+.2f head=%.0f cur_lat=(%.2f..%.2f) targets=%s' % n)
        for i in r['impacts'][:24]:
            print('   IMPACT n=%d f=%d arc=%.1f lat=%+.2f v=%.1f->%.1f target=%+.2f corridor_blk=%s'
                  % (i['n='], i['f='], i['arc='], i['lat='], i['v_before='], i['v_after='],
                     i['target_lane='], str(i['tb'])))
    print()


if __name__ == '__main__':
    main(sys.argv[1:])
