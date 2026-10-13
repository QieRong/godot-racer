# -*- coding: utf-8 -*-
"""
verify_race_car_glb.py —— 校验 race_car.glb 是否仍满足游戏侧硬契约

背景（AGENTS.md §13 / race_car.tscn 文件头）：
    build_racecar_3d.py → racecar-3d.blend → export_glb.py → race_car.glb
    → race_car.tscn（VehicleWheel3D 硬点由模型实测轮径/轮距/轴距推导）

本脚本是这条链的**机器闸门**：GLB 每次重新导出后必跑，违约即非零退出。
判据（glTF 坐标，Y-up；换算：Blender (x,y,z) → glTF (x,z,-y)）：
  1. 12 个车轮节点名必须在：Tire_/Rim_/Hub_ × {Front,Rear} × {L,R}
     （vehicle.gd::_bind_wheel_visuals 按名 find_child 绑定驱动）
  2. 前轮：直径 ≈0.68 / 胎宽 ≈0.26 / 中心 x≈-1.05 / |z|≈0.68
     后轮：直径 ≈1.00 / 胎宽 ≈0.34 / 中心 x≈+1.05 / |z|≈0.68
     （race_car.tscn 硬点 y = 轮半径 + rest_length(0.15) 由此推导）
  3. 车轮最低点 y ≈ 0（贴地，Blender z=0）
  4. 车头在 -X 一侧（导出后 Godot 里朝 -Z）
  5. 材质命名规范：全部材质名匹配 ^mat_ 前缀（v3 起），关键材质在位
  6. 三角面总数 ≤ 6000（v3 用户约束，超出先砍刹车盘/侧壁点/后视镜细节）
  7. 12 个契约车轮节点的 Origin 在轮心（= 几何中心，glTF translation 与
     mesh 包围盒中心一致）

零第三方依赖（纯标准库）。跑法：
    python verify_race_car_glb.py [race_car.glb 路径]
"""
import json
import re
import struct
import sys

TOL = 0.04          # 米；放样/导出浮点误差 + 倒角的余量
TRI_BUDGET = 6000   # v3 用户约束：三角面数上限
WHEEL_NODES = []
for tag in ("Front", "Rear"):
    for side in ("L", "R"):
        for part in ("Tire", "Rim", "Hub"):
            WHEEL_NODES.append("%s_%s_%s" % (part, tag, side))

# v3 起的规范材质名（v2 及以前的旧名 CarPaint_Red 等已全部改名）
EXPECTED_MATERIALS = (
    "mat_body_red", "mat_tire_rubber", "mat_rim_silver", "mat_trim_black",
    "mat_glass_dark", "mat_carbon", "mat_helmet_white", "mat_visor_dark",
    "mat_stripe_white", "mat_stripe_black", "mat_susp_steel", "mat_brake_disc",
)
MAT_NAME_RE = re.compile(r"^mat_[a-z0-9_]+$")


# ----------------------------------------------------------- 4x4 矩阵（纯 Python）
def mat_identity():
    return [1.0, 0, 0, 0,  0, 1.0, 0, 0,  0, 0, 1.0, 0,  0, 0, 0, 1.0]


def mat_mul(a, b):
    """a @ b，行主序 4x4。"""
    out = [0.0] * 16
    for i in range(4):
        for j in range(4):
            out[i * 4 + j] = sum(a[i * 4 + k] * b[k * 4 + j] for k in range(4))
    return out


def mat_apply(m, p):
    """m @ (p, 1)，返回变换后的 3D 点。"""
    x, y, z = p
    return (m[0] * x + m[1] * y + m[2] * z + m[3],
            m[4] * x + m[5] * y + m[6] * z + m[7],
            m[8] * x + m[9] * y + m[10] * z + m[11])


def node_matrix(node):
    if "matrix" in node:
        return list(node["matrix"])
    t = node.get("translation", [0, 0, 0])
    q = node.get("rotation", [0, 0, 0, 1])
    s = node.get("scale", [1, 1, 1])
    x, y, z, w = q
    rot = [
        1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w),
        2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w),
        2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y),
    ]
    m = mat_identity()
    for i in range(3):
        for j in range(3):
            m[i * 4 + j] = rot[i * 3 + j] * s[j]
    m[0 * 4 + 3], m[1 * 4 + 3], m[2 * 4 + 3] = t[0], t[1], t[2]
    return m


# ----------------------------------------------------------- GLB 读取
def load_glb(path):
    data = open(path, "rb").read()
    if data[:4] != b"glTF":
        raise SystemExit("不是 GLB 文件：%s" % path)
    json_len = struct.unpack("<I", data[12:16])[0]
    gltf = json.loads(data[20:20 + json_len])
    off = 20 + json_len
    if off % 4:
        off += 4 - off % 4
    bin_len = struct.unpack("<I", data[off:off + 4])[0]
    bin_data = data[off + 8: off + 8 + bin_len]
    return gltf, bin_data


CT_SIZE = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}
CT_FMT = {5120: "b", 5121: "B", 5122: "h", 5123: "H", 5125: "I", 5126: "f"}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "02-Blender建模/race_car.glb"
    gltf, bin_data = load_glb(path)

    # 收集所有网格节点的世界变换（glTF 坐标）
    world = {}   # node index -> 4x4

    def walk(idx, parent_m):
        node = gltf["nodes"][idx]
        m = mat_mul(parent_m, node_matrix(node))
        if "mesh" in node:
            world[idx] = m
        for ch in node.get("children", []):
            walk(ch, m)

    children = {c for n in gltf["nodes"] for c in n.get("children", [])}
    roots = [i for i in range(len(gltf["nodes"])) if i not in children]
    for r in roots:
        walk(r, mat_identity())

    # 节点名 -> (mesh index, world matrix)
    name_of = {}
    for i, node in enumerate(gltf["nodes"]):
        if "mesh" in node and i in world:
            name_of[node.get("name", "node%d" % i)] = (node["mesh"], world[i])

    failures = []

    def check(name, cond, detail=""):
        print("%s %s%s" % ("PASS" if cond else "FAIL", name,
                           (" | " + detail) if detail else ""))
        if not cond:
            failures.append(name)

    # ① 12 个车轮节点名
    missing = [n for n in WHEEL_NODES if n not in name_of]
    check("wheel_node_names_12", not missing, "missing=%s" % missing)

    # 网格世界包围盒（优先用 accessor 的 min/max，没有再解点）
    def mesh_bbox(mesh_idx, m):
        mesh = gltf["meshes"][mesh_idx]
        lo = [1e9] * 3
        hi = [-1e9] * 3
        for prim in mesh["primitives"]:
            acc = gltf["accessors"][prim["attributes"]["POSITION"]]
            if "min" in acc and "max" in acc:
                mn, mx = acc["min"], acc["max"]
            else:
                # 没有 min/max 时解出来（极少见）
                n = NCOMP[acc["type"]]
                size = CT_SIZE[acc["componentType"]]
                fmt = CT_FMT[acc["componentType"]]
                bv = gltf["bufferViews"][acc.get("bufferView", 0)]
                start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
                stride = bv.get("byteStride") or size * n
                pts = [struct.unpack_from("<%d%s" % (n, fmt), bin_data,
                                          start + i * stride)
                       for i in range(acc["count"])]
                mn = [min(p[k] for p in pts) for k in range(3)]
                mx = [max(p[k] for p in pts) for k in range(3)]
            for cx in (mn[0], mx[0]):
                for cy in (mn[1], mx[1]):
                    for cz in (mn[2], mx[2]):
                        p = mat_apply(m, (cx, cy, cz))
                        for k in range(3):
                            lo[k] = min(lo[k], p[k])
                            hi[k] = max(hi[k], p[k])
        return lo, hi

    # ②③ 轮径 / 轮距 / 轴距 / 贴地
    expect = {"Front": (0.34, 0.26, -1.05), "Rear": (0.50, 0.34, 1.05)}
    for tag, (r, w, cx) in expect.items():
        for side in ("L", "R"):
            nm = "Tire_%s_%s" % (tag, side)
            if nm not in name_of:
                continue
            lo, hi = mesh_bbox(name_of[nm][0], name_of[nm][1])
            size = [hi[k] - lo[k] for k in range(3)]
            ctr = [(lo[k] + hi[k]) / 2 for k in range(3)]
            # 轮盘面在 glTF XY（半径占 X/Y），胎宽沿 Z
            check("%s_diameter" % nm,
                  abs(size[0] - 2 * r) < TOL and abs(size[1] - 2 * r) < TOL,
                  "size=%s" % [round(v, 3) for v in size])
            check("%s_width" % nm, abs(size[2] - w) < TOL,
                  "size=%s" % [round(v, 3) for v in size])
            check("%s_center_x" % nm, abs(ctr[0] - cx) < TOL,
                  "x=%.3f (expect %.2f)" % (ctr[0], cx))
            check("%s_track" % nm, abs(abs(ctr[2]) - 0.68) < TOL,
                  "z=%.3f" % ctr[2])
            check("%s_on_ground" % nm, abs(lo[1]) < 0.03,
                  "y_min=%.3f" % lo[1])

    # ④ 车头在 -X；上车体在 +Y
    all_lo = [1e9] * 3
    all_hi = [-1e9] * 3
    for nm, (mi, m) in name_of.items():
        lo, hi = mesh_bbox(mi, m)
        for k in range(3):
            all_lo[k] = min(all_lo[k], lo[k])
            all_hi[k] = max(all_hi[k], hi[k])
    print("INFO 全车包围盒(glTF) x[%.2f,%.2f] y[%.2f,%.2f] z[%.2f,%.2f]"
          % (all_lo[0], all_hi[0], all_lo[1], all_hi[1], all_lo[2], all_hi[2]))
    check("nose_at_minus_x", all_lo[0] < -1.7, "x_min=%.2f" % all_lo[0])
    check("up_is_plus_y", all_lo[1] > -0.05 and all_hi[1] > 1.0,
          "y=[%.2f,%.2f]" % (all_lo[1], all_hi[1]))

    # ⑤ 材质命名规范（v3：全部 mat_ 前缀，关键材质在位）
    mats = [m.get("name") for m in gltf.get("materials", [])]
    bad = [m for m in mats if not MAT_NAME_RE.match(m or "")]
    check("material_naming_convention", not bad, "bad=%s" % bad)
    for want in EXPECTED_MATERIALS:
        check("material_%s" % want, want in mats, "have=%s" % mats)

    # ⑥ 三角面总数预算（v3 用户约束 ≤6000）
    total_tris = 0
    for mesh in gltf.get("meshes", []):
        for prim in mesh["primitives"]:
            if "indices" in prim:
                total_tris += gltf["accessors"][prim["indices"]]["count"] // 3
            else:
                total_tris += gltf["accessors"][prim["attributes"]["POSITION"]]["count"] // 3
    check("tri_budget_6000", total_tris <= TRI_BUDGET,
          "tris=%d budget=%d" % (total_tris, TRI_BUDGET))

    # ⑦ 车轮 Origin 在轮心（v3 用户约束：= 几何中心）
    # 换算：Blender (x, y, z) → glTF (x, z, -y)；轮心 (±1.05, ±0.68, r)
    expect_center = {"Front": (-1.05, 0.34), "Rear": (1.05, 0.50)}
    for tag, (cx, r) in expect_center.items():
        for side in ("L", "R"):
            for part in ("Tire", "Rim", "Hub"):
                nm = "%s_%s_%s" % (part, tag, side)
                if nm not in name_of:
                    continue
                node = next(n for n in gltf["nodes"]
                            if n.get("name") == nm and "mesh" in n)
                t = node.get("translation", [0, 0, 0])
                # glTF 世界坐标（车轮节点无父级变换，translation 即世界位）
                # 注意符号：Blender (x,y,z) → glTF (x,z,-y)，
                # L 侧（Blender y=+0.68）在 glTF 里是 z=-0.68
                want = (cx, r, -0.68 if side == "L" else 0.68)
                check("%s_origin_at_hub" % nm,
                      all(abs(t[k] - want[k]) < TOL for k in range(3)),
                      "t=%s want=%s" % ([round(v, 3) for v in t],
                                        [round(v, 3) for v in want]))
                # Origin = 几何中心：mesh 包围盒中心与世界 translation 一致
                lo, hi = mesh_bbox(name_of[nm][0], name_of[nm][1])
                ctr = [(lo[k] + hi[k]) / 2 for k in range(3)]
                check("%s_origin_is_geometric_center" % nm,
                      all(abs(ctr[k] - t[k]) < TOL for k in range(3)),
                      "center=%s t=%s" % ([round(v, 3) for v in ctr],
                                          [round(v, 3) for v in t]))

    print("GLB_VERIFY_DONE failures=%d" % len(failures))
    if failures:
        sys.exit(1)
    print("GLB_VERIFY_DONE ok")


if __name__ == "__main__":
    main()
