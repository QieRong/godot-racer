"""Snetterton200结构改编，调用现有闭环工具；不采用历史 DESIGNS 候选。"""
import csv
import importlib.util
import json
import math
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('closure', HERE / 'layout_closure.py')
closure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(closure)
segs = [('straight', None), ('sweeper', 100, -90), ('straight', None),
        ('arc', 55, -105), ('arc', 90, 15), ('straight', None),
        ('arc', 70, 45), ('arc', 60, -90), ('straight', None),
        ('arc', 105, -45), ('straight', None), ('sweeper', 115, -165),
        ('arc', 65, 75), ('straight', None)]
design = dict(segs=segs, targets={0:250, 2:200, 5:700, 8:80, 10:100, 13:200})
solved, residual, heading, pair, lengths = closure.solve_pair_search(design)
# 用解算器保留的未舍入解，不把 to_dsl 的 0.1m 精度误称精确闭环。
for i, value in lengths.items():
    solved[i][1] = value
for seg in solved:
    seg[1] *= 1.2
raw = []
for seg in solved:
    raw.append(seg[0] + ':' + ':'.join(f'{n:.8f}' for n in seg[1:]))
dsl = ', '.join(raw)
labels = ['Home A', 'T1 Riches rhythm', 'Brake 1', 'T2 Wilson rhythm',
          'T3 Chapman opening', 'Bentley reference', 'T4 Brundle entry',
          'T5 Nelson change', 'Recovery', 'T6 Bomb Hole rhythm', 'Brake 2',
          'T7 Coram long right', 'T8 Murrays left', 'Home B']
out = HERE.parents[1] / 'plan/track-L2-001-design'
out.mkdir(parents=True, exist_ok=True)
rows, points, anchors = [], [], []
x = z = angle = distance = 0.0
for index, seg in enumerate(solved):
    length = closure.seg_len(seg)
    anchors.append((x, z))
    rows.append(dict(segment=index+1, reference=labels[index], kind=seg[0],
                     start_m=distance, length_m=length,
                     radius_m=seg[1] if seg[0] != 'straight' else None,
                     turn_deg=seg[2] if seg[0] != 'straight' else 0,
                     x=x, z=z, heading_deg=angle))
    count = max(1, math.ceil(length))
    piece = list(seg)
    piece[1 if seg[0] == 'straight' else 2] /= count
    for _ in range(count):
        points.append((x,z))
        x,z,angle = closure._advance(x,z,angle,piece)
    distance += length
points.append((x,z))
report = dict(layout=dsl, nominal_length_m=distance, closure_residual_m=math.hypot(x,z),
              heading_deg=angle, solved_straights_zero_based=list(pair), segments=rows,
              source='https://www.snetterton.co.uk/about/circuit-layouts',
              map='https://msvstatic.blob.core.windows.net/manual/snetterton/SN%20Map_200%20Circuit_CompressPdf.pdf',
              note='结构与驾驶节奏改编，非测绘复刻；游戏实际弧长必须以geometry.json为准')
(out/'design.json').write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
with (out/'segments.csv').open('w', newline='', encoding='utf-8-sig') as f:
    writer = csv.DictWriter(f, fieldnames=list(rows[0]))
    writer.writeheader()
    writer.writerows(rows)
fig, ax = plt.subplots(figsize=(13,7))
xs,zs=zip(*points)
ax.plot(xs,zs,color='#293c53',linewidth=6)
ax.plot(xs,zs,color='#f1d176',linewidth=1)
for i,(xx,zz) in enumerate(anchors):
    ax.scatter(xx,zz,c='#cf573a',s=16)
    ax.annotate(f'{i+1}',(xx,zz),xytext=(5,7),textcoords='offset points',fontsize=9)
ax.arrow(40,0,45,0,width=2,color='#347d64',length_includes_head=True)
ax.scatter(0,0,s=90,marker='s',c='#347d64',label='Start/finish: +X')
ax.set(aspect='equal',xlabel='X (m)',ylabel='Z (m)',
       title=f'L2-001 | Snetterton 200 structure adaptation | {distance:.3f} m nominal | flat')
ax.grid(alpha=.2)
ax.legend()
fig.tight_layout()
fig.savefig(out/'route-plan.png',dpi=160)
print(json.dumps({k:v for k,v in report.items() if k!='segments'},ensure_ascii=False,indent=2))
