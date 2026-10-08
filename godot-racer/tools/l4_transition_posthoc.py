

import sys

from l4_transition_report import analyse, main


def _q(v, p):
    if not v:
        return float('nan')
    s = sorted(v)
    return s[min(len(s) - 1, int(round(p * (len(s) - 1))))]


def posthoc_rate(lane):
    """横向执行速率（m 横向 / m 纵向）—— 从**已有的 LANE 行**事后重算。

    为什么还要事后重算：游戏内的新采样器要求单帧弧长 > 0.30m，而实测车在弯道每帧只走
    ~0.2m，于是 n=0（这本身就是一次判据设计的教训）。LANE 行每 10 帧一条，用相邻两条
    算 d_lat / d_arc 是同一个物理量、样本量足够，而且**不依赖新代码是否上线**。
    """
    buckets = {0: [], 1: [], 2: [], 3: []}
    allr = []
    for a, b in zip(lane, lane[1:]):
        if b['f='] - a['f='] != 10:
            continue
        if abs(b['target='] - b['cur_lat=']) <= 0.10:
            continue
        d_arc = b['arc='] - a['arc=']
        if not (0.5 < d_arc < 20.0):
            continue
        rate = abs(b['cur_lat='] - a['cur_lat=']) / d_arc
        kmh = d_arc / (10.0 / 120.0) * 3.6
        allr.append(rate)
        bi = 0 if kmh < 40 else (1 if kmh < 80 else (2 if kmh < 120 else 3))
        buckets[bi].append(rate)
    return allr, buckets


def rate_summary(lane):
    allr, buckets = posthoc_rate(lane)
    if not allr:
        return 'no in-transit samples'
    names = ['0-40', '40-80', '80-120', '120+']
    parts = ['n=%d p25=%.4f med=%.4f p75=%.4f max=%.4f'
             % (len(allr), _q(allr, .25), _q(allr, .5), _q(allr, .75), _q(allr, 1.0))]
    for i, nm in enumerate(names):
        parts.append('%skmh n=%d med=%.4f' % (nm, len(buckets[i]), _q(buckets[i], .5)))
    return ' | '.join(parts)


def opportunity(lane, impacts):
    """每次撞车之前：目标车道什么时候翻的、翻到撞点还剩多少米、当时需要挪多少米。

    这是 P0/P1 的收官问题：当走廊判定为「通」时，车**来不来得及**把横向挪到位。
    """
    out = []
    for im in impacts:
        f = im['f=']
        tgt = None
        sw = None
        for r in lane:
            if r['f='] > f:
                break
            if abs(r['target='] - r['cur_lat=']) > 0.10:
                if tgt is None or abs(r['target='] - tgt) > 0.05:
                    tgt = r['target=']
                    sw = r
        if sw is None:
            out.append((im, None, None, None, None))
        else:
            out.append((im, tgt, im['arc='] - sw['arc='], abs(tgt - sw['cur_lat=']), sw['f=']))
    return out


def report(paths):
    main(paths)
    for p in paths:
        o = analyse(p)
        print('==== POSTHOC ' + p.split(chr(92))[-1])
        print('   lateral rate (from LANE lines, 10-frame pairs): ' + rate_summary(o['lane']))
        for im, tgt, d_arc, need, sf in opportunity(o['lane'], o['impacts']):
            if tgt is None:
                print('   IMPACT f=%d : no in-transit sample before impact' % im['f='])
                continue
            print('   IMPACT f=%d lat=%+.2f v=%.1f->%.1f : target=%+.2f switched@f=%d remaining=%.1fm need=%.2fm'
                  % (im['f='], im['lat='], im['v_before='], im['v_after='], tgt, sf, d_arc, need))
    print()


if __name__ == '__main__':
    report(sys.argv[1:])
