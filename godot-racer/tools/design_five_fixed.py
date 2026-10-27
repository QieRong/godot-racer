"""真实地图人工结构标定→圆弧/直道DSL；非测绘复刻，不产生运行时第二套道路。"""
import math,json,csv,re,importlib.util
from pathlib import Path
import numpy as np
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('closure',HERE/'layout_closure.py');cl=importlib.util.module_from_spec(spec);spec.loader.exec_module(cl)
ROOT=HERE.parents[1];OUT=ROOT/'plan/five-fixed-design';OUT.mkdir(exist_ok=True)
# 屏幕图像坐标中的折线结构点；圆弧替代折角。窄U口和急弯为车辆能力主动加宽。
DESIGNS={
1:dict(name='Brands Hatch Indy',source='https://www.brandshatch.co.uk/about/circuit-map',map='https://msvstatic.blob.core.windows.net/high-res/8715b2ad-fc61-48f0-b758-cbd0aeff0c90.jpg',
 points=[(105,530),(100,180),(180,170),(182,330),(220,420),(400,380),(550,300),(550,180),(610,95),(690,125),(700,240),(630,340)],scale=1.55,radius=60,
 labels=['Paddock Hill entry','Druids entry','Druids exit','Graham Hill entry','Graham Hill exit','Cooper Straight','Surtees','McLaren entry','McLaren','Clearways','Clark','Brabham return'],
 width=18,laps=2,blurb='Indy结构改编 · 森林宽路 · 学会弯前减速'),
3:dict(name='Oulton Park Fosters',source='https://www.oultonpark.co.uk/about/circuit-map',map='https://msvstatic.blob.core.windows.net/high-res/58e65ae7-af65-4ebf-94a6-77fded38c155.jpg',
 points=[(430,225),(390,375),(350,440),(380,520),(280,530),(220,420),(140,335),(70,305),(60,255),(185,40),(245,120)],scale=2.0,radius=58,
 labels=['Old Hall','Cascades entry','Cascades exit','Fosters connector','Fosters exit','Knickerbrook approach','Druids approach','Druids entry','Druids exit','Lodge entry','Deer Leap return'],
 width=15,laps=2,blurb='Fosters结构改编 · 雨夜路灯 · 提前判断固定路障'),
4:dict(name='Willow Springs Big Willow',source='https://www.grid.life/willow-springs-driver-resources',map='https://images.squarespace-cdn.com/content/v1/541cf31ae4b0ea46588b053b/ba5c2886-6607-4aea-a0b1-4263875eb404/Asset+2%404x.png',
 points=[(540,850),(380,1120),(170,1130),(150,920),(440,750),(450,700),(350,640),(375,550),(535,590),(580,730),(740,630),(1010,725),(1190,725),(1390,850),(1390,1150),(1240,1240)],scale=1.0,radius=65,
 labels=['T1','T2 entry','T2 bowl','T2 exit','T3 entry','T3 apex','T4 entry','T4 bowl','T4 exit','T5','T6','T7','T8 entry','T8 sweep','T9 entry','T9 exit'],
 width=14,laps=2,blurb='Big Willow结构改编 · 荒漠长弯 · 固定路障绕行'),
5:dict(name='Hungaroring',source='https://hungaroring.hu/guidebook/',map='Official guidebook page 12, 2018 layout',
 points=[(680,720),(605,600),(605,400),(545,400),(515,520),(270,570),(160,710),(95,650),(115,475),(180,520),(250,410),(185,330),(285,270),(320,160),(570,175),(550,330),(620,330),(620,160),(680,180)],scale=1.6,radius=50,
 labels=['T1 entry','T1 exit','T2 entry','T2 exit','T3','T4','T5 entry','T5 exit','T6','T7','T8','T9','T10','T11','T12','T13 entry','T13 exit','T14 entry','T14 exit'],
 width=13,laps=2,blurb='Hungaroring结构改编 · 雪地组合弯 · 节奏与制动')}

def rounded(design):
 p=np.array(design['points'],float)*design['scale'];n=len(p)
 unit=np.roll(p,-1,axis=0)-p;edge=np.linalg.norm(unit,axis=1);unit/=edge[:,None]
 incoming=np.roll(unit,1,axis=0)
 turn=np.arctan2(incoming[:,0]*unit[:,1]-incoming[:,1]*unit[:,0],np.sum(incoming*unit,axis=1))
 t=np.tan(np.abs(turn)/2)
 radius=np.minimum(design['radius'],0.44*np.minimum(edge,np.roll(edge,1))/t)
 cut=radius*t
 # 从最后一边中点发车，起终点落在足够长的直道，朝向+X；最后半段直线收口。
 last_straight=edge[-1]-cut[-1]-cut[0]
 assert last_straight>20
 segments=[['straight',last_straight/2]];labels=['Start straight A']
 for i in range(n):
  segments.append(['arc',float(radius[i]),float(-math.degrees(turn[i]))]);labels.append(design['labels'][i])
  length=edge[i]-cut[i]-cut[(i+1)%n]
  segments.append(['straight',float(length if i<n-1 else last_straight/2)]);labels.append('Link '+str(i+1))
 return segments,labels

def sample(segs,labels):
 points=[];rows=[];x=z=h=d=0.
 for i,s in enumerate(segs):
  length=cl.seg_len(s);rows.append(dict(segment=i+1,reference=labels[i],kind=s[0],length_m=length,radius_m=s[1] if s[0]!='straight' else None,turn_deg=s[2] if s[0]!='straight' else 0,start_m=d,x=x,z=z))
  piece=list(s);steps=max(1,math.ceil(length));piece[1 if s[0]=='straight' else 2]/=steps
  for _ in range(steps):points.append([x,0,z]);x,z,h=cl._advance(x,z,h,piece)
  d+=length
 points.append([x,0,z]);return points,rows,d,math.hypot(x,z),h

reports=[];fig,axes=plt.subplots(2,3,figsize=(17,10))
for level in range(1,6):
 cfg=ROOT/f'godot-racer/data/levels/level_{level}.tres';text=cfg.read_text(encoding='utf-8')
 if level==2:
  dsl=re.search(r'^layout = "(.*)"',text,re.M)[1];segs=[]
  for part in dsl.split(','):
   k,*v=part.strip().split(':');segs.append([k,*map(float,v)])
  labels=['Home A','Riches','Brake 1','Wilson','Chapman','Bentley','Brundle','Nelson','Recovery','Bomb Hole','Brake 2','Coram','Murrays','Home B'];name='Snetterton 200';source='https://www.snetterton.co.uk/about/circuit-layouts';width=16;laps=2
 else:
  design=DESIGNS[level];segs,labels=rounded(design);dsl=', '.join(s[0]+':'+':'.join(f'{v:.8f}' for v in s[1:]) for s in segs);name=design['name'];source=design['source'];width=design['width'];laps=design['laps']
  changes=dict(layout='"'+dsl+'"',closure_mode='"solve"',s_curve_amplitude='0',road_width=str(width),laps_to_finish=str(laps),dynamic_obstacle_count='0',min_corner_radius='20.0',blurb='"'+design['blurb']+'"',fog_density='0.003' if level==3 else ('0.0015' if level==4 else '0.002' if level==5 else '0'))
  for key,value in changes.items():text=re.sub(r'^'+key+r' = .*$',key+' = '+value,text,flags=re.M)
  text+='strict_layout = true\n' if 'strict_layout' not in text else ''
  cfg.write_text(text,encoding='utf-8')
 points,rows,length,gap,heading=sample(segs,labels)
 report=dict(level=level,name=name,source=source,layout=dsl,nominal_length_m=length,closure_residual_m=gap,heading_deg=heading,min_nominal_radius_m=min(s[1] for s in segs if s[0]!='straight'),road_width=width,laps=laps,segments=rows,centerline=points,note='人工结构改编；加宽弯/直道、平面化及游戏尺度；非测绘复刻。实际弧长以Godot实测为准。')
 (OUT/f'L{level}.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
 with (OUT/f'L{level}-segments.csv').open('w',newline='',encoding='utf-8-sig') as f:w=csv.DictWriter(f,fieldnames=rows[0]);w.writeheader();w.writerows(rows)
 p=np.array(points);ax=axes.flat[level-1];ax.plot(p[:,0],-p[:,2],lw=4,c=['#337955','#c08426','#4673a3','#b46732','#657a99'][level-1]);ax.scatter(0,0,c='red',marker='s');ax.set_aspect('equal');ax.set_title(f'L{level} {name}\n{length:.0f}m / {laps} laps / flat');ax.grid(alpha=.2)
 reports.append({k:v for k,v in report.items() if k not in ['segments','centerline','layout']})
axes.flat[5].axis('off');fig.tight_layout();fig.savefig(OUT/'five-routes.png',dpi=150)
(OUT/'summary.json').write_text(json.dumps(reports,indent=2,ensure_ascii=False),encoding='utf-8');print(json.dumps(reports,ensure_ascii=False,indent=2))
