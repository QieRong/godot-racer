#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""路段布局的闭环设计工具（离线、开发期用）。

为什么需要它：
    路段拼装（straight / arc / hairpin / chicane）**不保证首尾相接**。
    净转角 = 360° 只说明"朝向对上了"，位置还要另外满足 Σ(位移) = 0。
    手写长度几乎不可能刚好闭合 —— 实测 L2 的第一版设计残差 **340m**，
    靠游戏内解算去补会解出"负长度"这种荒谬结果（游戏内已经会拒绝，但那时设计已经废了）。
    所以设计阶段就该在这里把长度解出来，游戏内的解算只负责收拾最后几厘米。

用法：
    python tools/layout_closure.py --level 2

坐标约定（与 GDScript 的 track_layout.gd 完全一致，已数值校验）：
    前进方向 dir(θ) = (cosθ, -sinθ)   （x, z 两个分量）
    左法向 left = UP × dir = (-sinθ, -cosθ)
    绕 +Y 旋转 A：v' = (vx·cosA + vz·sinA, -vx·sinA + vz·cosA)
    验证：dir(0) = (1,0)，绕 +90° 后应为 -Z=(0,-1)：v'=(1·0+0·1, -1·1+0·0)=(0,-1) ✔

解算说明：
    固定若干条"手感值"直道，解出剩下两条。两条可调直道必须**不平行**，
    否则只有 1 个自由度、方程组无解（必须报错，不许糊过去）。
"""

import argparse
import math

# 每关的设计（与 docs/plans/tracks-and-elevation.md §6 一一对应）
# targets：每条直道的"设计意图"长度。工具会遍历所有可解的两条直道组合，
#          挑一组**全部为正**且最接近意图的（找不到就报"这个设计要重做"）。
DESIGNS = {
    1: dict(mode="mirror180", half="straight:110, arc:70:90, straight:60, arc:70:90"),
    2: dict(
        mode="solve",
        # 方向：0° →(扫弯 100°)→ 100° →(扫弯 80°)→ 180° →(发夹 180°)→ 0°
        segs=[("straight", None), ("sweeper", 95.0, 100.0), ("straight", None),
              ("sweeper", 70.0, 80.0), ("straight", None), ("hairpin", 24.0),
              ("straight", None)],
        targets={0: 220.0, 2: 60.0, 4: 35.0, 6: 90.0},
        tune=[(1, 1, [70.0, 85.0, 95.0, 110.0]), (3, 1, [55.0, 70.0, 85.0]),
              (5, 1, [18.0, 24.0, 30.0])]),
    3: dict(
        mode="solve",
        # 方向：0° →(90°)→ 90° →(90°)→ 180° →(90°)→ 270° →(90°)→ 0°
        segs=[("straight", None), ("arc", 20.0, 90.0), ("straight", None),
              ("chicane", 30.0, 4.0), ("arc", 20.0, 90.0), ("straight", None),
              ("arc", 20.0, 90.0), ("straight", None), ("arc", 20.0, 90.0)],
        targets={0: 150.0, 2: 40.0, 5: 160.0, 7: 60.0}),
    4: dict(
        mode="solve",
        # 方向：0° →(120°)→ 120° →(80°)→ 200° →(120°)→ 320° →(40°)→ 0°
        segs=[("straight", None), ("sweeper", 110.0, 120.0), ("straight", None),
              ("arc", 80.0, 80.0), ("straight", None), ("arc", 70.0, 120.0),
              ("straight", None), ("arc", 60.0, 40.0)],
        targets={0: 260.0, 2: 120.0, 4: 70.0, 6: 60.0}),
    5: dict(mode="mirror180", half="straight:90, chicane:30:4, straight:50, hairpin:18"),
    # L2 重做候选 2：直道方向铺开到 0/100/180/320（原来那版只有 0/100/180，
    # 三条里两条不带 z 分量，而发夹弦长是 +z —— 锥形上就不可能凑出正长度）。
    21: dict(
        mode="solve",
        segs=[("straight", None), ("sweeper", 95.0, 100.0), ("straight", None),
              ("sweeper", 70.0, 80.0), ("straight", None), ("arc", 24.0, 140.0),
              ("straight", None), ("arc", 40.0, 40.0)],
        targets={0: 220.0, 2: 60.0, 4: 35.0, 6: 90.0},
        tune=[(1, 1, [80.0, 95.0, 110.0]), (3, 1, [60.0, 70.0, 85.0])]),
}


def seg_turn(seg):
    """一段的净转角（度）。"""
    if seg[0] in ("arc", "sweeper"):
        return float(seg[2])
    if seg[0] == "hairpin":
        return 180.0
    return 0.0


def _advance(x, z, heading, seg):
    """把一段从 (x,z,heading) 推进；返回新的 (x, z, heading)。"""
    if seg[0] == "straight":
        L = float(seg[1])
        h = math.radians(heading)
        return x + math.cos(h) * L, z - math.sin(h) * L, heading
    pieces = []
    if seg[0] in ("arc", "sweeper"):
        pieces = [(float(seg[1]), float(seg[2]))]
    elif seg[0] == "hairpin":
        pieces = [(float(seg[1]), 180.0)]
    elif seg[0] == "chicane":
        R, off = float(seg[1]), float(seg[2])
        a = math.degrees(math.acos(max(-1.0, min(1.0, 1.0 - off / (2.0 * R)))))
        pieces = [(R, a), (R, -a)]
    for R, Adeg in pieces:
        A = math.radians(Adeg)
        h = math.radians(heading)
        left = (-math.sin(h), -math.cos(h))
        sgn = 1.0 if A >= 0 else -1.0
        cx, cz = x + left[0] * R * sgn, z + left[1] * R * sgn
        vx, vz = x - cx, z - cz
        ca, sa = math.cos(A), math.sin(A)
        x, z = cx + vx * ca + vz * sa, cz - vx * sa + vz * ca
        heading += Adeg
    return x, z, heading


def run(segs):
    """走完全部段。返回 (终点 x, 终点 z, 净转角, {直道下标: 方向})。"""
    x = z = 0.0
    heading = 0.0
    dirs = {}
    for i, seg in enumerate(segs):
        if seg[0] == "straight":
            h = math.radians(heading)
            dirs[i] = (math.cos(h), -math.sin(h))
        x, z, heading = _advance(x, z, heading, seg)
    return x, z, heading, dirs


def solve_grid(design, top=3):
    """网格搜索：找**存在正长度解**的直道组合。

    为什么不能只固定一堆"设计意图值"再解两条：
        正长度的**存在性**取决于你给其余直道定的值 —— 实测 L2 用意图值去解，
        任何两条的组合都会解出负长度（-123m）。所以设计阶段必须搜索：
        选两条解算，其余在意图值附近取网格，挑出"全部为正且最接近意图"的方案。

    返回 [(score, segs, resid, pair, lens), ...]（最多 top 个），找不到就返回 []。
    """
    base = []
    for s in design["segs"]:
        base.append([s[0]] + [0.0 if v is None else float(v) for v in s[1:]])
    idx = [i for i, s in enumerate(base) if s[0] == "straight"]
    # 每条直道的候选值：意图值附近 0.4~1.6 倍，8 档，取整到 5m
    grid = {}
    for i in idx:
        t = float(design["targets"][i])
        vals = sorted({max(5.0, round(t * f / 5.0) * 5.0)
                       for f in (0.4, 0.55, 0.7, 0.85, 1.0, 1.15, 1.3, 1.6)})
        grid[i] = vals

    results = []
    pairs = [(a, b) for k, a in enumerate(idx) for b in idx[k + 1:]]
    # 可选"半径调参"：design["tune"] = [(段下标, 参数下标, [候选值...])]。
    # 为什么需要：弧的**弦长是固定的**，只有直道可调时某些布局的残差根本吃不下 ——
    # 正长度的存在性还取决于弧的半径。实测 L2 就是这样（直道怎么调都无解）。
    tunes = design.get("tune", [])
    tune_combos = [[]]
    for (si, ai, vals) in tunes:
        tune_combos = [c + [(si, ai, v)] for c in tune_combos for v in vals]
    for tcombo in tune_combos:
        for (a, b) in pairs:
            others = [i for i in idx if i != a and i != b]
            # 其余直道的笛卡尔积（最多 2 条 → 64 组合）
            combos = [[]]
            for i in others:
                combos = [c + [v] for c in combos for v in grid[i]]
            for combo in combos:
                segs = [list(s) for s in base]
                for (si, ai, v) in tcombo:
                    segs[si][ai] = float(v)
                for k, i in enumerate(others):
                    segs[i][1] = float(combo[k])
                for i in (a, b):
                    segs[i][1] = 0.0
                x, z, heading, dirs = run(segs)
                net = heading % 360.0
                if abs(net) > 0.5 and abs(net - 360.0) > 0.5:
                    continue
                u1, u2 = dirs[a], dirs[b]
                det = u1[0] * u2[1] - u1[1] * u2[0]
                if abs(det) < math.sin(math.radians(11.0)):
                    continue
                gx, gz = -x, -z
                L1 = (gx * u2[1] - gz * u2[0]) / det
                L2 = (u1[0] * gz - u1[1] * gx) / det
                if L1 < 5.0 or L2 < 5.0:
                    continue
                segs[a][1] = round(L1, 1)
                segs[b][1] = round(L2, 1)
                resid = math.hypot(*run(segs)[:2])
                if resid > 0.5:
                    continue
                lens = {i: float(segs[i][1]) for i in idx}
                score = sum(abs(lens[i] - float(design["targets"][i])) for i in idx)
                results.append((score, segs, resid, (a, b), lens))
    results.sort(key=lambda r: r[0])
    return results[:top]


def solve_pair_search(design, pair=None):
    """解出两条直道的长度。
    pair=None 时自动遍历所有"不平行"的直道组合，挑一组**全部为正**且最接近设计意图的。
    返回 (segs, 残差, 净转角, 选中的 pair, 各直道最终长度)
    """
    segs0 = []
    for s in design["segs"]:
        segs0.append([s[0]] + [0.0 if v is None else float(v) for v in s[1:]])

    straight_idx = [i for i, s in enumerate(segs0) if s[0] == "straight"]
    candidates = []
    pairs = [pair] if pair else [(a, b) for i, a in enumerate(straight_idx)
                                 for b in straight_idx[i + 1:]]
    for (a, b) in pairs:
        segs = [list(s) for s in segs0]
        # 固定除 a、b 之外的所有直道为设计目标值
        for i in straight_idx:
            if i != a and i != b:
                segs[i][1] = float(design["targets"][i])
        for i in (a, b):
            segs[i][1] = 0.0
        x, z, heading, dirs = run(segs)
        net = heading % 360.0
        if abs(net) > 0.5 and abs(net - 360.0) > 0.5:
            continue
        u1, u2 = dirs[a], dirs[b]
        det = u1[0] * u2[1] - u1[1] * u2[0]
        if abs(det) < math.sin(math.radians(11.0)):
            continue                      # 几乎平行：只有 1 个自由度
        gx, gz = -x, -z
        L1 = (gx * u2[1] - gz * u2[0]) / det
        L2 = (u1[0] * gz - u1[1] * gx) / det
        if L1 < 5.0 or L2 < 5.0:
            continue                      # 解出负长度/过短 = 这个组合不可用
        segs[a][1] = round(L1, 1)
        segs[b][1] = round(L2, 1)
        resid = math.hypot(*run(segs)[:2])
        # 打分：两条被解直道偏离设计意图多少（越小越"没走样"）
        score = abs(L1 - design["targets"][a]) + abs(L2 - design["targets"][b])
        candidates.append((score, segs, resid, (a, b), {a: L1, b: L2}))
    if not candidates:
        return None
    candidates.sort(key=lambda c: c[0])
    score, segs, resid, pair_used, lens = candidates[0]
    heading = run(segs)[2]
    return segs, resid, heading, pair_used, lens


def seg_len(seg):
    if seg[0] == "straight":
        return float(seg[1])
    if seg[0] in ("arc", "sweeper"):
        return float(seg[1]) * abs(math.radians(float(seg[2])))
    if seg[0] == "hairpin":
        return float(seg[1]) * math.pi
    if seg[0] == "chicane":
        R, off = float(seg[1]), float(seg[2])
        a = math.acos(max(-1.0, min(1.0, 1.0 - off / (2.0 * R))))
        return 2.0 * R * a
    return 0.0


def to_dsl(segs):
    out = []
    for seg in segs:
        if seg[0] == "straight":
            out.append("straight:%.1f" % seg[1])
        elif seg[0] in ("arc", "sweeper"):
            out.append("%s:%.1f:%.0f" % (seg[0], seg[1], seg[2]))
        elif seg[0] == "hairpin":
            out.append("hairpin:%.1f" % seg[1])
        elif seg[0] == "chicane":
            out.append("chicane:%.1f:%.1f" % (seg[1], seg[2]))
    return ", ".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--level", type=int, choices=sorted(DESIGNS.keys()))
    ap.add_argument("--all", action="store_true", help="打印全部关卡")
    args = ap.parse_args()

    levels = sorted(DESIGNS.keys()) if args.all else [args.level]
    for lv in levels:
        d = DESIGNS[lv]
        if d["mode"] == "mirror180":
            print("==== 关卡 %d（mirror180，只写半条）====" % lv)
            print('  layout = "%s"' % d["half"])
            print("  半条净转角 = %.1f°（点对称加倍要求恰好 180°）" % sum(
                seg_turn([p.split(":")[0]] + [float(v) for v in p.split(":")[1:]])
                for p in [s.strip() for s in d["half"].split(",")]))
            continue
        cands = solve_grid(d)
        if not cands:
            print("==== 关卡 %d：**这个设计闭不上** ====" % lv)
            print("  网格搜索（意图值的 0.4~1.6 倍 × 所有可解直道组合）里没有任何正长度解。")
            print("  → 角度序列要重做：正长度的存在性由角度序列决定，不是靠调数值能救的。")
            continue
        for rank, (score, segs, resid, pair_used, lens) in enumerate(cands):
            if rank == 0:
                print("==== 关卡 %d（solve）====" % lv)
                print('  layout = "%s"' % to_dsl(segs))
                print("  长度 ≈ %.1f m；直道最终长度 = %s；残差 %.4f m"
                      % (sum(seg_len(s) for s in segs),
                         ", ".join("%.1f" % v for v in lens.values()), resid))
            else:
                print("  备选方案 %d（偏离意图 %.0fm 更大）：%s"
                      % (rank, score, to_dsl(segs)))


if __name__ == "__main__":
    main()
