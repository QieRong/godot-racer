"""独立只读实际轨迹/过门验收；反例不能靠最终两圈信号伪通过。"""
import argparse
import json
import math
from pathlib import Path
import numpy as np
from scipy.spatial import cKDTree

COLUMNS = 'frame sim_s wall_s x y z vx vy vz arc global_arc lane lateral_error yaw_deg steer engine_force brake rescues laps'.split()

def wrapped(d, length):
    return (d + length/2) % length - length/2

def analyze(data, road, events):
    failures = []
    length = road['length']
    points = np.asarray(road['centerline'])
    positions = np.column_stack([data[k] for k in ['x','y','z']])
    tree = cKDTree(points[:,[0,2]])
    dist, idx = tree.query(positions[:,[0,2]])
    tangent = points[(idx+1)%len(points)] - points[(idx-1)%len(points)]
    tangent[:,1] = 0
    tangent /= np.linalg.norm(tangent,axis=1)[:,None]
    side = np.column_stack([tangent[:,2],np.zeros(len(idx)),-tangent[:,0]])
    lateral = np.einsum('ij,ij->i', positions-points[idx],side)
    yaw = np.radians(data['yaw_deg'])
    body_lateral = road['body_half_width']*np.abs(np.cos(yaw)) + road['body_half_length']*np.abs(np.sin(yaw))
    footprint = np.abs(lateral) + body_lateral
    if np.max(footprint) > road['half_width']:
        failures.append('body_outside_road')
    displacement = np.linalg.norm(np.diff(positions,axis=0),axis=1)
    arc_delta = wrapped(np.diff(data['arc']),length)
    if np.any(np.abs(arc_delta) > displacement + 2.0):
        failures.append('arc_jump')
    if np.any(displacement > np.linalg.norm(np.column_stack([data[k] for k in ['vx','vy','vz']])[:-1],axis=1)/road['physics_hz'] + 2.0):
        failures.append('position_jump')
    branch_gap = np.abs(wrapped(data['arc']-data['global_arc'],length))
    # 原全局查询粗步长L/512，本路线约5.8m；不能把粗采样误差当跨分支。
    # 用独立1m空间索引核对合法拓扑；局部与独立参考仍用原拟定2m上限。
    reference_gap = np.abs(wrapped(data['arc']-idx,length))
    global_reference_gap = np.abs(wrapped(data['global_arc']-idx,length))
    global_sampling_bound = max(length/512.0,2.0)/2.0 + 0.5
    if np.max(reference_gap) > 2.0 or np.max(global_reference_gap) > global_sampling_bound:
        failures.append('nearest_branch_disagreement')
    if np.max(data['rescues']) > 0:
        failures.append('rescue_used')
    target_laps = int(road.get('target_laps', 2))
    if np.max(data['laps']) < target_laps:
        failures.append('core_target_laps_missing')
    if np.max(data['sim_s']) >= 600:
        failures.append('ai_over_600_seconds')
    # 以真实位置线段与实际门平面相交，独立于核心计圈和 Area 信号。
    crosses = []
    for gate in road['gates']:
        center = np.asarray(gate['pos'])
        forward = np.asarray(gate['forward'])
        side_gate = np.array([forward[2],0,-forward[0]])
        signed = (positions-center) @ forward
        candidates = np.flatnonzero((signed[:-1] < 0) & (signed[1:] >= 0))
        for j in candidates:
            blend = -signed[j]/(signed[j+1]-signed[j])
            hit = positions[j]*(1-blend)+positions[j+1]*blend
            if abs((hit-center) @ side_gate) <= road['half_width'] and abs(hit[1]-center[1]) <= 3:
                crosses.append((int(data['frame'][j]),gate['order']))
    crosses.sort()
    physical_orders = [order for _,order in crosses]
    sensor_orders = [event['order'] for event in events]
    gate_count = len(road['gates'])
    expected = list(range(gate_count))*target_laps + [0]
    if physical_orders != expected:
        failures.append('physical_gate_sequence')
    if sensor_orders != expected:
        failures.append('area_gate_sequence')
    if np.any(np.diff(data['frame']) != 1):
        failures.append('missing_physics_frames')
    # 不相邻路段间距：轨道半宽/护栏厚度必须容纳；排除沿线80m以内的邻点。
    pairs = np.asarray(list(tree.query_pairs(22.0)),dtype=int).reshape(-1,2)
    if len(pairs):
        sep = np.abs(wrapped(pairs[:,0]-pairs[:,1],length))
        if np.any(sep > 80):
            failures.append('nonlocal_road_overlap')
    return dict(passed=not failures, failures=failures, frames=len(data),
                simulation_seconds=float(data['sim_s'][-1]),wall_seconds=float(data['wall_s'][-1]),
                max_body_lateral_m=float(np.max(footprint)),road_half_width_m=road['half_width'],
                max_lane_error_m=float(np.max(np.abs(data['lateral_error']))),
                max_branch_disagreement_m=float(np.max(branch_gap)),
                max_local_independent_gap_m=float(np.max(reference_gap)),
                max_global_independent_gap_m=float(np.max(global_reference_gap)),
                global_sampling_bound_m=global_sampling_bound,
                max_arc_delta_m=float(np.max(np.abs(arc_delta))),
                max_position_delta_m=float(np.max(displacement)),
                max_speed_kmh=float(np.max(np.linalg.norm(np.column_stack([data[k] for k in ['vx','vz']]),axis=1))*3.6),
                rescues=int(np.max(data['rescues'])),core_laps=int(np.max(data['laps'])),
                physical_gate_orders=physical_orders,area_gate_orders=sensor_orders,
                active_brake_frames=int(np.sum((np.abs(data['engine_force']) < 0.001) & (data['brake'] > 1.21))))

def plot_trace(data,road,out):
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    points = np.asarray(road['centerline'])
    fig,axes=plt.subplots(3,1,figsize=(14,11),gridspec_kw={'height_ratios':[2,1,1]})
    ax=axes[0]
    ax.plot(points[:,0],points[:,2],c='#666',linewidth=5,label='Actual road centerline')
    actor=road.get('actor', 'AI')
    ax.plot(data['x'],data['z'],c='#dc5b3e',linewidth=.8,label=f'Actual {actor}, every physics frame')
    height=f"road Y {points[:,1].min():.1f} to {points[:,1].max():.1f} m"
    ax.axis('equal');ax.legend();ax.set_title(f"L{road.get('level', 2)} actual {actor} trajectory, {height}, {road.get('target_laps', 2)} laps")
    speed=np.sqrt(data['vx']**2+data['vz']**2)*3.6
    axes[1].plot(data['sim_s'],speed,label='speed km/h')
    axes[1].plot(data['sim_s'],data['brake'],alpha=.8,label='wheel brake')
    axes[1].legend();axes[1].grid(alpha=.2)
    axes[2].plot(data['sim_s'],data['lateral_error'],label='lane error m')
    axes[2].plot(data['sim_s'],wrapped(data['arc']-data['global_arc'],road['length']),label='local/global arc difference m')
    axes[2].legend();axes[2].grid(alpha=.2);axes[2].set_xlabel('simulation seconds')
    fig.tight_layout();fig.savefig(out/'trajectory.png',dpi=140)

if __name__ == '__main__':
    ap=argparse.ArgumentParser();ap.add_argument('directory');args=ap.parse_args()
    out=Path(args.directory)
    data=np.genfromtxt(out/'trace.csv',delimiter=',',names=True)
    road=json.loads((out/'actual-road.json').read_text(encoding='utf-8'))
    events=[json.loads(s) for s in (out/'gates.jsonl').read_text(encoding='utf-8').splitlines() if s]
    report=analyze(data,road,events)
    (out/'trajectory-verdict.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    plot_trace(data,road,out)
    print(json.dumps(report,ensure_ascii=False,indent=2))
    raise SystemExit(0 if report['passed'] else 1)
