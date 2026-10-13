# -*- coding: utf-8 -*-
"""
blender-car-audit.py —— 用 dsh-blender-plugin 的 audit 门给车型 .blend 做网格体检

为什么存在：模型升级（v2）不能只靠"渲染图看着像"——AGENTS.md §23.3 定了
skill 的门是加分验证。本脚本把 §6 的网格体检接到车型管线上，回答三个客观问题：
  1. 有没有洞？（boundary_edges>0 = 放样封盖失败——loft_profile 的
     bm.faces.new 失败是被 try/except 静默吞掉的，只有体检能发现）
  2. 法线朝外吗？（normals_state=fail 会让后续一切穿模判据反号）
  3. 网格自交吗？（自交通常不该有；对象之间的 intentional 穿插不算这里）

跑法（Blender 4.3 无头）：

    "E:/blender/blender.exe" -b --factory-startup \
      --python 02-Blender建模/blender-car-audit.py -- [racecar-3d.blend]

判据（不过即 exit 1）：
  * 每个网格对象 closed（boundary_edges==0 且 nonmanifold_edges==0）
  * 每个网格对象 normals_state != "fail"
  * self_intersections 只报告不计门槛（对象间 intentional 穿插另算）
"""
import json
import os
import sys

RT = os.environ.get(
    "DSH_BLENDER_RUNTIME",
    r"C:\Users\Administrator\.workbuddy\tools\dsh-blender-plugin\runtime")
if not os.path.exists(os.path.join(RT, "kit.py")):
    print("FATAL 定位不到插件 runtime（kit.py 不在）：%s" % RT)
    print("FATAL 请设环境变量 DSH_BLENDER_RUNTIME=<dsh-blender-plugin>/runtime")
    sys.exit(2)
sys.path.insert(0, RT)

HERE = os.path.dirname(os.path.abspath(__file__))
BLEND = os.path.join(HERE, "racecar-3d.blend")
if "--" in sys.argv:
    extra = [a for a in sys.argv[sys.argv.index("--") + 1:]
             if a and not a.startswith("-")]
    if extra:
        BLEND = extra[0]
if not os.path.exists(BLEND):
    print("FATAL 找不到 .blend：%s" % BLEND)
    sys.exit(2)

import bpy  # noqa: E402
bpy.ops.wm.open_mainfile(filepath=BLEND)

import offline_bootstrap as ob  # noqa: E402

ns = ob.boot(["audit"])
audit = ns["kapi"]("audit")

names = sorted(o.name for o in bpy.data.objects
               if o.type == "MESH" and o.name != "Ground")
if not names:
    print("FATAL .blend 里没有网格对象（Ground 已排除）")
    sys.exit(2)

r = json.loads(audit["mesh"](objects=names, self_intersect=True))
totals = r.get("totals", {})
print("AUDIT ok=%s clean=%s state=%s" % (r.get("ok"), r.get("clean"), r.get("state")))
print("TOTALS " + json.dumps(totals, ensure_ascii=False))

failures = []
for ob in r.get("objects", []):
    name = ob.get("name")
    if ob.get("empty"):
        failures.append(name)
        print("FAIL %s 空网格" % name)
        continue
    if not ob.get("closed", False):
        failures.append(name)
        print("FAIL %s 未闭合 boundary=%s nonmanifold=%s"
              % (name, ob.get("boundary_edges"), ob.get("nonmanifold_edges")))
    nstate = ob.get("normals_state")
    if nstate == "fail":
        failures.append(name)
        print("FAIL %s 法线 fail：%s" % (name, ob.get("normals_reason", "")))
    si = ob.get("self_intersections") or 0
    if si:
        print("INFO %s 自交 %s 处（对象内；对象间 intentional 穿插不在本门范围）"
              % (name, si))

print("OBJECTS %d / FAILURES %d" % (len(names), len(failures)))
if failures:
    print("AUDIT_CAR_DONE failures=%s" % sorted(failures))
    sys.exit(1)
print("AUDIT_CAR_DONE ok")
