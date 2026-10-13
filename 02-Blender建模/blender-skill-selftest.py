# -*- coding: utf-8 -*-
"""
blender-skill-selftest.py —— dsh-blender-plugin 离线通道「判据先红」自证

背景：AGENTS.md §23 记录的 blender-modeling skill + dsh-blender-plugin 装在本机后，
用本脚本证明它的验收门**不是永远绿的假门**（本项目铁律：判据必须先证明能红）。

跑法（Blender 4.3 无头，约 10-30 秒）：

    "E:/blender/blender.exe" -b --factory-startup \
      --python 02-Blender建模/blender-skill-selftest.py

三条断言（全机器判，不靠肉眼）：
  ① audit selftest  ：已知脏网格（开放网格 + 立方体）必须被报出
                      （boundary_edges>0 且 clean=false；不存在的对象必须 ok=false）
  ② gate selftest   ：合成坏装配（远端浮块 / 0.2mm 真微隙 / bbox 骗人用例）
                      必须 gate fail —— 15 条子句全过才算门是真的
  ③ vehicle selftest：比例门该过/该挂 + 建壳尺寸吻合 + 四轮 + 轮壳零互穿

插件 runtime 目录：默认取本机安装位，可用环境变量 DSH_BLENDER_RUNTIME 覆盖。
⚠ 该默认值是**机器特定路径**，不是项目普适路径（AGENTS.md §12 同款纪律）；
换机器只需设一个环境变量，脚本本身不用改。
"""
import json
import os
import sys

# 本机安装位（2026-10-13 装）；换机器用 DSH_BLENDER_RUNTIME 覆盖
RT = os.environ.get(
    "DSH_BLENDER_RUNTIME",
    r"C:\Users\Administrator\.workbuddy\tools\dsh-blender-plugin\runtime")
if not os.path.exists(os.path.join(RT, "kit.py")):
    print("FATAL 定位不到插件 runtime（kit.py 不在）：%s" % RT)
    print("FATAL 请设环境变量 DSH_BLENDER_RUNTIME=<dsh-blender-plugin>/runtime")
    sys.exit(2)
sys.path.insert(0, RT)

import offline_bootstrap as ob  # noqa: E402

FAILED = []


def check(name, cond, detail=""):
    cond = bool(cond)
    print("%s %s%s" % ("PASS" if cond else "FAIL", name,
                       (" | " + detail) if detail else ""))
    if not cond:
        FAILED.append(name)


def as_obj(x):
    """插件的 API 有的返回 JSON 字符串、有的返回 dict，统一成 dict。"""
    if isinstance(x, str):
        return json.loads(x)
    return x


def main():
    ns = ob.boot(["vehicle", "audit", "qc", "clearance"])
    audit = ns["kapi"]("audit")
    vehicle = ns["kapi"]("vehicle")

    # ① 网格审计门：已知脏网格必须被如实报出
    r = as_obj(audit["selftest"]())
    check("audit.ok", r.get("ok") is True)
    check("audit.dirt_detected",
          (r.get("boundary_edges") or 0) > 0 and r.get("clean") is False,
          "boundary_edges=%s clean=%s" % (r.get("boundary_edges"), r.get("clean")))
    check("audit.empty_must_fail", r.get("empty_must_fail") is True)

    # ② 装配门：合成坏装配必须 gate fail（15 条子句全过）
    g = as_obj(audit["gate_selftest"]())
    check("gate.ok", g.get("ok") is True,
          "gate_state=%s failed_clauses=%s" % (g.get("gate"), g.get("failed_clauses")))

    # ③ 车辆算子链：比例门该过/该挂 + 建壳 + 尺寸吻合 + 轮壳零互穿
    v = as_obj(vehicle["selftest"]())
    check("vehicle.ok", v.get("ok") is True, "error=%s" % (v.get("error", "")))
    ev = v.get("evidence") or {}
    cl = ev.get("clearance")
    if isinstance(cl, dict):
        check("vehicle.clearance_zero_interpenetration",
              cl.get("interpenetrating") is False,
              "gap_mm=%s" % cl.get("gap_mm"))

    print("SELFTEST_DONE failures=%d" % len(FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
