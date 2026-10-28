"""真实绿轨迹为正对照；仅在内存中注入反例，不改原始证据。"""
import importlib.util
import json
from pathlib import Path
import sys
import numpy as np

spec=importlib.util.spec_from_file_location('observer',Path(__file__).with_name('check-track-trace.py'))
observer=importlib.util.module_from_spec(spec);spec.loader.exec_module(observer)
out=Path(sys.argv[1])
data=np.genfromtxt(out/'trace.csv',delimiter=',',names=True)
road=json.loads((out/'actual-road.json').read_text(encoding='utf-8'))
events=[json.loads(s) for s in (out/'gates.jsonl').read_text(encoding='utf-8').splitlines() if s]
reports={}
reports['real_positive_control']=observer.analyze(data,road,events)
assert reports['real_positive_control']['passed'], reports['real_positive_control']
# 删除整段真实行驶位置，同时保留伪造的完赛与全部 Area 事件；弧长/位置跳变必须拦截。
skip=np.concatenate([data[:2000],data[6000:]])
skip['frame']=np.arange(1,len(skip)+1)
reports['skipped_branch_fake_finish']=observer.analyze(skip,road,events)
assert 'arc_jump' in reports['skipped_branch_fake_finish']['failures']
# 圈数、检查点事件照旧，但车身离路20m；不能只看计圈。
cut=data.copy();cut['z'][5000]+=20
reports['outside_corner_fake_finish']=observer.analyze(cut,road,events)
assert 'body_outside_road' in reports['outside_corner_fake_finish']['failures']
rescue=data.copy();rescue['rescues'][-1]=1
reports['rescued_fake_finish']=observer.analyze(rescue,road,events)
assert 'rescue_used' in reports['rescued_fake_finish']['failures']
branch=data.copy();branch['global_arc'][5000]=(branch['arc'][5000]+road['length']/3)%road['length']
reports['wrong_nearest_branch']=observer.analyze(branch,road,events)
assert 'nearest_branch_disagreement' in reports['wrong_nearest_branch']['failures']
(out/'counterexamples.json').write_text(json.dumps(reports,ensure_ascii=False,indent=2),encoding='utf-8')
print('TRACE_COUNTEREXAMPLES PASS=5 FAIL=0 (1 real control + 4 injected negative controls)')
