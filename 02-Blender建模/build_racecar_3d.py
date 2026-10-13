# -*- coding: utf-8 -*-
"""
build_racecar_3d.py  --  Blender 脚本（无头运行）  [v4 视觉精修]

    "E:/blender/blender.exe" -b --factory-startup --python build_racecar_3d.py

v4（2026-10-13）按用户观感反馈做六项精修，**物理相关几何与节点契约零变化**，
    GLB 面数 5656 -> 5696（预算 6000，余量 304）：
    1. 轮胎：tread_gap 0.014 -> 0.0，48 段齿纹胎面改**光头胎**（slick），
       拓扑不变 => 0 tri；齿顶=契约半径的设定使包围盒与硬点推导不受影响
    2. 侧箱进气口：12 tri box 外贴 -> 等面数 12 tri **梯形 scoop**（前大后小、
       后口埋入放样体），消除"悬浮黑盒子"观感；净 0 tri
    3. 挡风玻璃：alpha 0.52 -> 0.78（压掉透出的红色内壁）+ 左右补两根边框杆
       （+40 tri），解决"偏红、边缘生硬"
    4. 驾驶员双手：原坐标三轴全落在躯干 box 内 => 渲染里完全隐形。
       移到方向盘轮缘 10 点/2 点位 (-0.105, +-0.014, 0.685)，0 tri（位移 bug 修复）
    5. 辐条/刹车盘：维持现状（用户确认），留作后续预算弹性
    6. 车身条纹：4 片已在，0 tri 提亮材质增强存在感；
       **编号 "01" 明确不做** —— 几何版 +70~150 tri 且低模下不可读，
       贴图版要为纯固色管线首次引入 UV/贴图链路（管线级变更，需单独立项）

v3（2026-10-13）在 v2 基础上做细节升级，**物理相关几何与节点契约零变化**。
v2 的 GLB 三角面已达 6396（超 6000 预算），故 v3 同时做"先瘦身、再增量"：
    * 瘦身：轮胎改为自定义齿纹网格（无 bevel，48 段圆周），
      单条 764 → ~380 tri；悬挂圆柱段数 16 → 8；头盔 ico subdivisions 2 → 1
    * 增量按用户给定优先级分配：轮毂 > 前翼/尾翼 > 轮胎胎面 > 侧箱 > 座舱 > 其他

v3 变更清单：
  视觉细节
    1. 头盔：加面罩（加宽包面）与颈部护具；驾驶员加双手握方向盘（方向盘 + 两只手）
    2. 挡风玻璃：改弧形放样面 + 上下边框（v2 是一片直斜板）
    3. 前翼：3 层翼片（主翼 + 襟翼 + 第二襟翼）+ 垂直端板 + 挂柱
    4. 尾翼：端板加高 + 上延片，支撑立柱 2 → 4 根
    5. 侧箱：box 改前窄后宽流线型放样（前缘贴车身、后部外凸），碳纤进气口保留
    6. 悬挂臂：细棍改 A 臂（上下各两根分叉臂）+ 斜拉杆 + 轮轴
    7. 轮毂：立体化——轮辋外环 + 中心锁紧螺母（6 棱）+ 外露刹车盘 + 5 辐条
    8. 轮胎：胎面 48 段齿纹（齿顶=契约半径，最大半径不变）+ 侧壁 3 个装饰点
  材质与色彩
    1. 车漆 mat_body_red：高饱和糖果红 + 金属光泽；新增白/黑赛车条纹 4 片
    2. 玻璃 mat_glass_dark：深色半透明 + 高光（低粗糙度）
    3. 轮胎 mat_tire_rubber：哑光橡胶（roughness 0.92）
    4. 碳纤 mat_carbon：轻微反光
  技术约束
    * 三角面 ≤ 6000（verify_race_car_glb.py 断言，超出先砍刹车盘/侧壁点/后视镜）
    * 12 个契约节点名 / 轮心 / 轮径 / 轮宽 零变化
    * 视觉零件全部只做 Mesh 子节点，无碰撞体（GLB 无碰撞体，天然满足）
    * 车轮 Tire_/Rim_/Hub_ 的 Origin 均在轮心（几何中心）
    * 材质统一 mat_ 前缀命名规范；导出前 Apply 所有 Modifier
      （build 末尾 apply 一次 + export_glb.py 的 export_apply=True 双保险）

坐标约定：X = 车长（车头 -X），Y = 车宽，Z = 车高

⚠ 与游戏侧的硬契约（改动前必读，违约 = 轮子不转或悬挂压底）：
    * 车轮节点名 Tire_/Rim_/Hub_ × {Front,Rear} × {L,R} 共 12 个不能改
      （vehicle.gd::_bind_wheel_visuals 用 find_child 按名绑定并驱动旋转，
       三个节点一起转——侧壁装饰点挂 Tire_ 子节点下即随轮转）
    * 前轮中心 (±1.05, ±0.68) 半径 0.34 宽 0.26；
      后轮中心 (±1.05, ±0.68) 半径 0.50 宽 0.34
      （race_car.tscn 的车轮硬点由这些值推导，换模型改轮径必须同步手改 tscn）
    * 车头朝 -X；export_glb.py 以 +Y-up 导出，Godot 里车头朝 -Z
    * 新增细节节点名不得与上述 12 个重名
"""
import math
import os

import bpy
import bmesh
from mathutils import Vector

OUT_DIR = os.path.dirname(os.path.abspath(__file__))   # 自定位：与本脚本同目录
BLEND_PATH = os.path.join(OUT_DIR, "racecar-3d.blend")
RENDER_PATH = os.path.join(OUT_DIR, "racecar-3d-render.png")
RENDER_PATH_REAR = os.path.join(OUT_DIR, "racecar-3d-render-rear.png")

# ------------------------------------------------------------ 面数预算参数（v3）
# GLB 三角面预算 6000；这些段数是"超出时优先砍"的旋钮，按细节优先级排序：
# 刹车盘 < 侧壁点 < 后视镜 < 轮辋外环 < 辐条数（不动）
BRAKE_SEGMENTS = 16      # 刹车盘圆周段数
RIM_LIP_SEGMENTS = 24    # 轮辋外环圆周段数
SIDEWALL_DOTS = 3        # 每轮侧壁装饰点数量
TIRE_SEGMENTS = 48       # 轮胎圆周段数（齿纹密度）


# ----------------------------------------------------------------- 场景清理
def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.objects,
                  bpy.data.cameras, bpy.data.lights):
        for item in list(block):
            block.remove(item)


# ----------------------------------------------------------------- 材质工具
def make_material(name, base_color, metallic=0.0, roughness=0.5,
                  alpha=1.0, emission=None, emission_strength=0.0):
    """材质统一 mat_ 前缀命名规范（v3 起）。"""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*base_color, alpha)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    if "Alpha" in bsdf.inputs:
        bsdf.inputs["Alpha"].default_value = alpha
    if emission is not None and "Emission Color" in bsdf.inputs:
        bsdf.inputs["Emission Color"].default_value = (*emission, 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission_strength
    if alpha < 1.0:
        mat.blend_method = "BLEND"
    return mat


def assign_material(obj, mat):
    obj.data.materials.clear()
    obj.data.materials.append(mat)


# ------------------------------------------------------- 由侧视轮廓放样成体
def loft_profile(name, profile_xz, width_fn, material, depth_steps=9,
                 flat=0.86, edge_bevel=0.0):
    """把侧视轮廓 (x, z) 沿 Y 轴放样成实体。

    flat 越大侧壁越平（越像车）；两端各收一层形成圆角过渡。
    """
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)

    n = len(profile_xz)
    layers = []
    for i in range(depth_steps):
        t = i / (depth_steps - 1)          # 0..1 从一侧到另一侧
        s = math.sin(math.pi * t)
        scale = flat + (1.0 - flat) * s    # 中段保持 flat，端部收到 1.0
        scale = min(scale, 1.0)
        y = (t * 2.0 - 1.0)                # -1 .. 1
        ring = []
        for (px, pz) in profile_xz:
            hw = width_fn(px) * scale
            ring.append((px, y * hw, pz))
        layers.append(ring)

    bm = bmesh.new()
    verts = [[bm.verts.new(v) for v in ring] for ring in layers]
    bm.verts.ensure_lookup_table()

    for a, b in zip(verts, verts[1:]):
        for i in range(n):
            j = (i + 1) % n
            try:
                bm.faces.new((a[i], a[j], b[j], b[i]))
            except ValueError:
                pass
    # 两端封盖
    for ring, rev in ((verts[0], True), ((verts[-1]), False)):
        try:
            bm.faces.new(tuple(reversed(ring)) if rev else tuple(ring))
        except ValueError:
            pass

    bm.normal_update()
    bm.to_mesh(mesh)
    bm.free()

    for poly in mesh.polygons:
        poly.use_smooth = False

    if edge_bevel > 0:
        mod = obj.modifiers.new("Bevel", "BEVEL")
        mod.width = edge_bevel
        mod.segments = 2

    assign_material(obj, material)
    return obj


def make_cylinder(name, radius, depth, location, rotation, material,
                  vertices=48, bevel=0.0):
    bpy.ops.mesh.primitive_cylinder_add(
        vertices=vertices, radius=radius, depth=depth, location=location,
        rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    if bevel > 0:
        mod = obj.modifiers.new("Bevel", "BEVEL")
        mod.width = bevel
        mod.segments = 2
    assign_material(obj, material)
    return obj


def make_cylinder_between(name, p0, p1, radius, material, vertices=8):
    """在两点之间生成一根圆柱（用作悬挂 A 臂 / 拉杆 / 后视镜杆）。"""
    p0, p1 = Vector(p0), Vector(p1)
    mid = (p0 + p1) / 2
    direction = p1 - p0
    length = direction.length
    bpy.ops.mesh.primitive_cylinder_add(vertices=vertices, radius=radius,
                                        depth=length, location=mid)
    obj = bpy.context.object
    obj.name = name
    obj.rotation_euler = direction.to_track_quat("Z", "Y").to_euler()
    assign_material(obj, material)
    return obj


def make_box(name, size, location, material, rotation=(0, 0, 0)):
    """生成尺寸为 size 的长方体。

    注意：primitive_cube_add(size=1.0) 生成的就是 1x1x1，
    因此 scale 直接取 size（不要再除以 2），否则整体会缩一半。
    """
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=location, rotation=rotation)
    obj = bpy.context.object
    obj.name = name
    obj.scale = (size[0], size[1], size[2])
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    assign_material(obj, material)
    return obj


def make_sphere(name, radius, location, scale, material, subdivisions=1):
    """低面数球（驾驶员头盔）。v3 起 subdivisions 默认 1（80 面，控预算）。"""
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions,
                                          radius=radius, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    assign_material(obj, material)
    return obj


def make_tire_treaded(name, radius, depth, location, material,
                      segments=TIRE_SEGMENTS, tread_gap=0.0,
                      shoulder=0.055):
    """轮胎：v4 起默认 **光头胎**（tread_gap=0.0，奇偶段同半径）。

    v3 的 tread_gap=0.014（48 段齿纹）在渲染里呈"越野胎/齿轮"的锯齿边，
    与 F1 开轮式赛车气质不符，故按用户反馈 v4 改为平滑胎面（slick 光头胎）。
    拓扑不变 => 面数不变（见下），且外圈顶点全部落在契约半径上，
    GLB 包围盒直径与 race_car.tscn 硬点推导都不受影响。
    注意：不要为了"赛车感"再加环形/斜线凹槽 —— 那需要额外插至少 2 圈外缘顶点，
    +4S 每条胎（4 条共 +768 tri）会直接爆 6000 闸门，已在评估报告中否决。

    结构（本地坐标 Z 为轴向，调用方负责旋转 90° 让轴向沿 Y）：
        * 外缘左右两圈各 segments 个顶点，半径 = radius（tread_gap>0 时
          奇数段退到 radius - tread_gap 形成齿纹，齿顶仍是契约半径）
        * 胎面 = 外缘左右圈之间的环带
        * 内缘两圈收进 shoulder，侧壁平面，端盖 fan 封口
    面数实测 = 8 * segments tri（48 段 = 384/胎，与 GLB 实测吻合；
    v3 注释里的 "96 + 2S + 2(S-2)" 是错的旧公式，v4 已更正）。
    """
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (math.radians(90), 0, 0)

    hw = depth / 2.0
    bm = bmesh.new()
    outer_l, outer_r, inner_l, inner_r = [], [], [], []
    for i in range(segments):
        a = 2.0 * math.pi * i / segments
        ca, sa = math.cos(a), math.sin(a)
        r_out = radius - (tread_gap if i % 2 else 0.0)
        r_in = radius - shoulder
        outer_l.append(bm.verts.new((ca * r_out, sa * r_out, hw)))
        outer_r.append(bm.verts.new((ca * r_out, sa * r_out, -hw)))
        inner_l.append(bm.verts.new((ca * r_in, sa * r_in, hw)))
        inner_r.append(bm.verts.new((ca * r_in, sa * r_in, -hw)))
    bm.verts.ensure_lookup_table()

    for i in range(segments):
        j = (i + 1) % segments
        # 胎面（齿纹环带）：外缘左圈 → 外缘右圈。
        # 顶点序 (左i, 右i, 右j, 左j)：先跨 z 再沿切向，法线径向朝外
        # （绕序错会整体朝内：signed_volume 为负、audit 判 unknown，
        #   Godot 里还会因背面剔除穿洞）
        try:
            bm.faces.new((outer_l[i], outer_r[i], outer_r[j], outer_l[j]))
        except ValueError:
            pass
        # 侧壁（z=+hw 一侧）：外缘圈 → 内缘圈，法线 +z
        try:
            bm.faces.new((outer_l[i], outer_l[j], inner_l[j], inner_l[i]))
        except ValueError:
            pass
        # 侧壁（z=-hw 一侧）：反向绕序，法线 -z
        try:
            bm.faces.new((outer_r[i], inner_r[i], inner_r[j], outer_r[j]))
        except ValueError:
            pass
    # 端盖：内缘圈 fan 到中心点（顶盖 +z 顺绕、底盖 -z 反绕）
    center_l = bm.verts.new((0.0, 0.0, hw))
    center_r = bm.verts.new((0.0, 0.0, -hw))
    for i in range(segments):
        j = (i + 1) % segments
        try:
            bm.faces.new((center_l, inner_l[i], inner_l[j]))
        except ValueError:
            pass
        try:
            bm.faces.new((center_r, inner_r[j], inner_r[i]))
        except ValueError:
            pass

    bm.normal_update()
    bm.to_mesh(mesh)
    bm.free()

    for poly in mesh.polygons:
        poly.use_smooth = False

    assign_material(obj, material)
    return obj


def make_sidepod_scoop(name, y_center, material,
                       x_front=-0.055, x_back=-0.005,
                       z_front=0.43, z_back=0.41,
                       hw_front=0.060, hh_front=0.090,
                       hw_back=0.035, hh_back=0.055):
    """侧箱进气口：梯形 scoop（v4 新增，替代 v3 的 box）。

    v3 的 SidePod_Inlet 是一块 12 tri 的方箱，外贴在侧箱前缘外约 5.7cm，
    渲染里像"悬浮的黑盒子"。本件保持 **等面数 12 tri**（2 端面 + 4 侧面），
    改成前大后小的截头锥：前口露在侧箱前缘外、后口埋进放样体内，
    读起来就是嵌进去的喇叭口，而不是贴片。
    节点名沿用 SidePod_Inlet_L / SidePod_Inlet_R（tri_report 分组连续）。

    全 bmesh 构造（headless 安全，不碰 bpy.ops）。构造后**显式**算
    signed_volume，为负则整体翻面 —— 法线朝外是后续一切审计的前提
    （bpy/blender-modeling skill 坑五：绕向反了，任何"穿模/内含"判据都会整体反号）。
    """
    def ring(x, zc, hw, hh):
        return [(x, y_center - hw, zc - hh), (x, y_center + hw, zc - hh),
                (x, y_center + hw, zc + hh), (x, y_center - hw, zc + hh)]

    fr = ring(x_front, z_front, hw_front, hh_front)
    bk = ring(x_back, z_back, hw_back, hh_back)

    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)

    bm = bmesh.new()
    vf = [bm.verts.new(v) for v in fr]
    vb = [bm.verts.new(v) for v in bk]
    bm.verts.ensure_lookup_table()
    bm.faces.new(tuple(vf))            # 前口面
    bm.faces.new(tuple(vb))            # 后口面
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((vf[i], vf[j], vb[j], vb[i]))
    bm.normal_update()

    vol = bm.calc_volume(signed=True)
    if vol < 0:
        bmesh.ops.reverse_faces(bm, faces=list(bm.faces))
        bm.normal_update()
        vol = -vol
    tris = sum(len(f.verts) - 2 for f in bm.faces)
    bm.to_mesh(mesh)
    bm.free()

    for poly in mesh.polygons:
        poly.use_smooth = False
    assign_material(obj, material)
    print("SCOOP %s tris=%d signed_volume=%.6f" % (name, tris, vol))
    return obj


def parent_keep_world(child, parent):
    """保持世界 transform 不变地把 child 挂到 parent 下。

    glTF 导出会保留层级；Godot 侧旋转父节点时子节点跟随——
    轮辐丝/外环/螺母挂 Rim_* 下即随轮子一起转（vehicle.gd 驱动 Rim）；
    侧壁装饰点挂 Tire_* 下同样随轮转（Tire_/Rim_/Hub_ 三节点一起驱动）。
    """
    child.parent = parent
    child.matrix_parent_inverse = parent.matrix_world.inverted()


def apply_all_modifiers():
    """导出前 Apply 所有 Modifier（v3 技术约束；export_glb.py 另带
    export_apply=True 双保险）。"""
    applied = 0
    for obj in list(bpy.data.objects):
        if obj.type != "MESH":
            continue
        for mod in list(obj.modifiers):
            bpy.context.view_layer.objects.active = obj
            try:
                bpy.ops.object.modifier_apply(modifier=mod.name)
                applied += 1
            except RuntimeError:
                pass
    return applied


# ------------------------------------------------------------------- 建模
def build_car():
    # ---- 材质（v3：统一 mat_ 前缀命名规范）----
    # 车漆：高饱和糖果红 + 金属光泽
    mat_body = make_material("mat_body_red", (0.78, 0.012, 0.030),
                             metallic=0.75, roughness=0.16)
    mat_tire = make_material("mat_tire_rubber", (0.020, 0.020, 0.022),
                             metallic=0.0, roughness=0.92)          # 哑光橡胶
    mat_rim = make_material("mat_rim_silver", (0.80, 0.80, 0.83),
                            metallic=0.95, roughness=0.15)
    # v4：alpha 0.52 -> 0.78。原值太透，把座舱凹陷里露出的红色车身内壁
    # 透上来，观感是"一块偏红的平面"；压到 0.78 后仍是玻璃但红色基本吃掉，
    # 高光保留。仍用深色 + 低粗糙度，材质名不变（verify 材质断言要求）。
    mat_glass = make_material("mat_glass_dark", (0.010, 0.012, 0.020),
                              metallic=0.25, roughness=0.04, alpha=0.78)
    mat_trim = make_material("mat_trim_black", (0.030, 0.030, 0.035),
                             metallic=0.40, roughness=0.40)
    mat_carbon = make_material("mat_carbon", (0.015, 0.015, 0.020),
                               metallic=0.60, roughness=0.30)        # 轻微反光
    mat_helmet = make_material("mat_helmet_white", (0.88, 0.88, 0.90),
                               metallic=0.15, roughness=0.18)
    mat_visor = make_material("mat_visor_dark", (0.020, 0.020, 0.030),
                              metallic=0.95, roughness=0.03)
    # v4：提亮 + 降粗糙度。4 片条纹其实一直在，只是原 base color 0.95 /
    # roughness 0.30 在渲染里几乎读不出来。0 tri，形不动。
    mat_stripe_w = make_material("mat_stripe_white", (0.98, 0.98, 0.99),
                                 metallic=0.10, roughness=0.25)
    mat_stripe_b = make_material("mat_stripe_black", (0.020, 0.020, 0.025),
                                 metallic=0.15, roughness=0.35)
    mat_susp = make_material("mat_susp_steel", (0.42, 0.43, 0.46),
                             metallic=0.90, roughness=0.32)
    mat_brake = make_material("mat_brake_disc", (0.30, 0.30, 0.33),
                              metallic=0.85, roughness=0.35)

    # ---- 车身侧视轮廓（X 前后, Z 高度；单位近似米）----
    # 与 v2 相同：座舱区（x -0.40..0.68）上缘凹陷成开口式座舱；
    #     鼻锥更低尖、引擎盖收窄后翘、车尾收窄。总长 3.6m（-1.80..1.80）。
    body_profile = [
        # 上缘：车头 → 车尾
        (-1.80, 0.26),   # 鼻尖
        (-1.70, 0.38),
        (-1.45, 0.44),
        (-1.05, 0.46),   # 前轴线上方
        (-0.72, 0.60),
        (-0.40, 0.72),   # 座舱前隔板顶
        (-0.30, 0.60),   # 凹陷开始（座舱前缘）
        ( 0.10, 0.56),   # 座舱底前
        ( 0.55, 0.56),   # 座舱底后
        ( 0.68, 0.66),   # 驾驶席后部升起
        ( 0.80, 0.80),   # 引擎盖起
        ( 1.05, 0.88),   # 引擎盖顶
        ( 1.35, 0.84),
        ( 1.58, 0.68),   # 车尾收窄
        ( 1.70, 0.56),
        ( 1.80, 0.50),   # 车尾上缘
        # 下缘：车尾 → 车头
        ( 1.80, 0.24),
        ( 1.20, 0.18),
        ( 0.40, 0.16),   # 底盘
        (-0.60, 0.16),
        (-1.20, 0.20),
        (-1.55, 0.24),
    ]

    def body_width(x):
        """车身半宽：鼻尖收窄 → 中段最宽 → 车尾收窄。"""
        if x < -1.55:
            return 0.16
        if x < -1.15:
            return 0.16 + (x + 1.55) * 0.40
        if x < -0.55:
            return 0.32 + (x + 1.15) * 0.41
        if x < 0.55:
            return 0.55
        if x < 1.30:
            return 0.55 - (x - 0.55) * 0.21
        return 0.40 - (x - 1.30) * 0.25

    body = loft_profile("Body", body_profile, body_width, mat_body,
                        depth_steps=9)

    # ---- 赛车条纹（v3：白/黑两条，贴面薄片，微突出防 z-fighting）----
    # 白条 1：鼻锥上缘（x -1.80..-1.05 斜面）
    make_box("Stripe_White_Nose", (0.62, 0.055, 0.012),
             (-1.42, 0.0, 0.456), mat_stripe_w,
             rotation=(0, math.radians(-14), 0))
    # 白条 2：引擎盖顶（x 0.80..1.35 斜面）
    make_box("Stripe_White_Engine", (0.58, 0.075, 0.012),
             (1.16, 0.0, 0.878), mat_stripe_w,
             rotation=(0, math.radians(-14), 0))
    # 黑条：左右侧壁（车身半宽 0.55 区间 x -0.55..0.55，避开侧箱后段）
    for side, sy in (("L", 1.0), ("R", -1.0)):
        make_box(f"Stripe_Black_Side_{side}", (0.62, 0.012, 0.10),
                 (-0.28, 0.552 * sy, 0.40), mat_stripe_b)

    # ---- 座舱：深色座舱底（盖住凹陷底面，形成"开口"观感）----
    cockpit_tub = make_box("Cockpit_Tub", (0.52, 0.56, 0.05),
                           (0.15, 0.0, 0.585), mat_trim)

    # ---- 挡风玻璃（v3：弧形放样面 + 上下边框）----
    # 弧形轮廓：基部嵌在座舱前隔板里、顶部探出车身上缘，沿 Y 方向两端微收
    windscreen = loft_profile(
        "Windscreen",
        [(-0.36, 0.58), (-0.26, 0.70), (-0.14, 0.745), (-0.04, 0.70)],
        lambda x: 0.31, mat_glass, depth_steps=5, flat=0.90)
    # 上下边框（细杆沿弧缘）
    make_cylinder_between("Windscreen_Frame_Up",
                          (-0.365, 0.0, 0.575), (-0.045, 0.0, 0.695),
                          0.010, mat_trim, vertices=6)
    make_cylinder_between("Windscreen_Frame_Low",
                          (-0.345, 0.0, 0.605), (-0.055, 0.0, 0.715),
                          0.008, mat_trim, vertices=6)
    # v4：左右侧补两根边框杆（原来只有中央两根），挡风玻璃的 Y 向端缘
    # (半宽 0.31 * flat 0.90 = +-0.279) 之前完全裸边，看着像浮在座舱上。
    # 杆往内收约 7mm 包住玻璃边，6 段圆柱 = 20 tri/根，合计 +40 tri。
    make_cylinder_between("Windscreen_Frame_Side_L",
                          (-0.360, 0.272, 0.583), (-0.045, 0.252, 0.702),
                          0.009, mat_trim, vertices=6)
    make_cylinder_between("Windscreen_Frame_Side_R",
                          (-0.360, -0.272, 0.583), (-0.045, -0.252, 0.702),
                          0.009, mat_trim, vertices=6)

    # ---- 驾驶员：躯干 + 头盔 + 面罩 + 颈部护具 + 双手 + 方向盘 ----
    driver_torso = make_box("Driver_Torso", (0.24, 0.26, 0.18),
                            (0.06, 0.0, 0.64), mat_trim)
    driver_helmet = make_sphere("Driver_Helmet", 0.115, (0.30, 0.0, 0.71),
                                (1.0, 1.10, 1.06), mat_helmet, subdivisions=1)
    # 面罩：加宽包住头盔正面
    driver_visor = make_box("Driver_Visor", (0.035, 0.14, 0.08),
                            (0.175, 0.0, 0.72), mat_visor)
    # 颈部护具：头盔下方的连接颈
    driver_neck = make_box("Driver_Neck", (0.10, 0.13, 0.055),
                           (0.265, 0.0, 0.645), mat_trim)
    # 方向盘（横放薄圆柱）+ 双手握轮缘
    make_cylinder("Steering_Wheel", 0.085, 0.018,
                  (-0.05, 0.0, 0.62), (math.radians(90), 0, 0),
                  mat_trim, vertices=16)
    # v4：原坐标 (0.028, +-0.088, 0.622) 三轴全落在躯干 box 包络
    # (x[-0.06,0.18] / y+-0.13 / z[0.55,0.73]) 内部 —— 手实际渲染不出来。
    # 新坐标取方向盘轮缘的 10 点 / 2 点位：距轮心 (-0.05, 0, 0.62) 的 XZ
    # 距离 = sqrt(0.055^2 + 0.065^2) = 0.0852 ~= 轮半径 0.085，
    # y=+-0.014 让手盒(半深 0.025)骑跨轮盘面(半深 0.009)，呈"握住"。
    # 注：3 点/9 点正侧位 (0.035, +-0.014, 0.62) 仍在躯干内，不可用。
    for side, sy in (("L", 1.0), ("R", -1.0)):
        make_box(f"Driver_Hand_{side}", (0.05, 0.05, 0.045),
                 (-0.105, 0.014 * sy, 0.685), mat_helmet)

    # ---- 车轮 ----
    # 前轮中心 X=-1.05 半径 0.34；后轮中心 X=+1.05 半径 0.50
    # 半宽：轮胎内侧贴住车身，外侧略外露（开轮式赛车）
    # ⚠ 中心/半径/宽度是 race_car.tscn 硬点的推导源，一个字都不能改
    wheels = []
    for side, y in (("L", 0.68), ("R", -0.68)):
        for tag, cx, r, width in (("Front", -1.05, 0.34, 0.26),
                                  ("Rear", 1.05, 0.50, 0.34)):
            # 轮胎：v3 改自定义齿纹网格（齿顶=契约半径）
            tire = make_tire_treaded(f"Tire_{tag}_{side}", r, width,
                                     (cx, y, r), mat_tire)
            wheels.append(tire)
            # 轮辋（浅色盘，形成可见轮圈）
            rimobj = make_cylinder(
                f"Rim_{tag}_{side}", radius=r * 0.60, depth=width * 1.04,
                location=(cx, y, r),
                rotation=(math.radians(90), 0, 0),
                material=mat_rim, vertices=48)
            wheels.append(rimobj)
            # 轮毂中心
            hub = make_cylinder(
                f"Hub_{tag}_{side}", radius=r * 0.20, depth=width * 1.10,
                location=(cx, y, r),
                rotation=(math.radians(90), 0, 0),
                material=mat_rim, vertices=32)
            wheels.append(hub)

    # ---- 轮毂立体化细节 + 辐条：全部挂 Rim 子节点（随轮子一起转）----
    bpy.context.view_layer.update()      # 保证 matrix_world 是最新的
    spokes = []
    for side, y in (("L", 0.68), ("R", -0.68)):
        for tag, cx, r, width in (("Front", -1.05, 0.34, 0.26),
                                  ("Rear", 1.05, 0.50, 0.34)):
            rim_name = f"Rim_{tag}_{side}"
            rimobj = bpy.data.objects.get(rim_name)
            sign = 1.0 if y > 0 else -1.0
            y_out = y + (width * 0.52 + 0.004) * sign     # 辐条：最外侧
            # 每轮 5 根辐条
            for i in range(5):
                a = math.radians(i * 72 + 18)
                loc = (cx + math.cos(a) * r * 0.30,
                       y_out,
                       r + math.sin(a) * r * 0.30)
                sp = make_box(f"Spoke_{tag}_{side}_{i}",
                              (r * 0.58, 0.012, 0.028), loc, mat_rim,
                              rotation=(0, -a, 0))
                parent_keep_world(sp, rimobj)
                spokes.append(sp)
            # 轮辋外环：包住 Rim 边沿，形成立体轮圈
            lip = make_cylinder(f"Rim_Lip_{tag}_{side}",
                                radius=r * 0.63, depth=width * 1.02,
                                location=(cx, y, r),
                                rotation=(math.radians(90), 0, 0),
                                material=mat_rim,
                                vertices=RIM_LIP_SEGMENTS)
            parent_keep_world(lip, rimobj)
            # 中心锁紧螺母：6 棱柱，外露于轮毂外侧
            nut = make_cylinder(f"Hub_Nut_{tag}_{side}",
                                radius=r * 0.10, depth=width * 1.14,
                                location=(cx, y, r),
                                rotation=(math.radians(90), 0, 0),
                                material=mat_susp, vertices=6)
            parent_keep_world(nut, rimobj)
            # 外露刹车盘：略大于轮辋的浅色盘，位于辐条内侧
            disc = make_cylinder(f"Brake_Disc_{tag}_{side}",
                                 radius=r * 0.68, depth=width * 0.35,
                                 location=(cx, y - sign * width * 0.30, r),
                                 rotation=(math.radians(90), 0, 0),
                                 material=mat_brake,
                                 vertices=BRAKE_SEGMENTS)
            parent_keep_world(disc, rimobj)
            # 侧壁装饰点：挂在 Tire_ 子节点下（Tire_/Rim_/Hub_ 三节点一起转）
            tireobj = bpy.data.objects.get(f"Tire_{tag}_{side}")
            for i in range(SIDEWALL_DOTS):
                a = math.radians(90 + i * 120)
                loc = (cx + math.cos(a) * (r - 0.012),
                       y + sign * (width * 0.5 + 0.004),
                       r + math.sin(a) * (r - 0.012))
                dot = make_box(f"Sidewall_Dot_{tag}_{side}_{i}",
                               (0.020, 0.006, 0.020), loc, mat_stripe_w,
                               rotation=(0, -a, 0))
                parent_keep_world(dot, tireobj)

    # ---- 尾翼：主板 + 加高端板 + 上延片 + 4 支柱 + 上襟翼 + 格尼翼 ----
    wing_z = 1.06
    wing_x = 1.68
    wing_span = 1.50
    wing_main = make_box("Wing_Main", (0.50, wing_span, 0.055),
                         (wing_x, 0.0, wing_z), mat_body)
    endplates = []
    for side, y in (("L", 0.735), ("R", -0.735)):
        # 端板加高（v2 0.30 → v3 0.38）+ 上延小翼片
        endplates.append(make_box(f"Wing_Endplate_{side}",
                                  (0.50, 0.035, 0.38),
                                  (wing_x, y, wing_z - 0.04), mat_trim))
        endplates.append(make_box(f"Wing_Endplate_Ext_{side}",
                                  (0.07, 0.030, 0.09),
                                  (wing_x - 0.02, y * 1.02, wing_z + 0.19),
                                  mat_trim))
    # 支柱 2 → 4 根（前后各一对）：上端穿进翼面，下端插入引擎盖
    struts = []
    for sx in (1.60, 1.76):
        for side, y in (("L", 0.17), ("R", -0.17)):
            struts.append(make_box(f"Wing_Strut_{side}_{int((sx - 1.60) * 100)}",
                                   (0.09, 0.06, 0.42),
                                   (sx, y, 0.90), mat_trim))
    # 上襟翼（碳纤维，后缘上翘 10°）+ 格尼翼
    wing_flap = make_box("Wing_Flap", (0.32, 1.44, 0.04),
                         (1.62, 0.0, 1.14), mat_carbon,
                         rotation=(0, math.radians(-10), 0))
    wing_gurney = make_box("Wing_Gurney", (0.03, 1.40, 0.045),
                           (1.78, 0.0, 1.185), mat_carbon)

    # ---- 前翼：3 层翼片 + 垂直端板 + 挂柱 ----
    front_wing = make_box("Front_Wing", (0.28, 1.00, 0.028),
                          (-1.70, 0.0, 0.27), mat_trim)
    front_flap = make_box("Front_Wing_Flap", (0.22, 0.94, 0.024),
                          (-1.62, 0.0, 0.35), mat_trim,
                          rotation=(0, math.radians(-12), 0))
    # 第三层翼片（v3 新增，位置更高更陡）
    front_flap2 = make_box("Front_Wing_Flap2", (0.18, 0.88, 0.022),
                           (-1.55, 0.0, 0.425), mat_trim,
                           rotation=(0, math.radians(-16), 0))
    front_endplates = []
    for side, y in (("L", 0.50), ("R", -0.50)):
        front_endplates.append(make_box(f"Front_Wing_Endplate_{side}",
                                        (0.30, 0.025, 0.14),
                                        (-1.70, y, 0.30), mat_trim))
    front_pylons = []
    for side, y in (("L", 0.12), ("R", -0.12)):
        front_pylons.append(make_box(f"Front_Wing_Pylon_{side}",
                                     (0.10, 0.05, 0.14),
                                     (-1.68, y, 0.30), mat_trim))

    # ---- 侧箱：v3 改前窄后宽流线型放样（前缘半宽 0.16 贴车身，后部 0.20 外凸）----
    sidepods = []
    for side, y in (("L", 0.55), ("R", -0.55)):
        sign = 1.0 if y > 0 else -1.0

        def pod_width(x, _s=sign):
            # 前缘（x≈-0.06）半宽 0.16 贴住车身侧壁；后部（x≈0.5）0.20 外凸
            if x < 0.10:
                return 0.16
            if x < 0.40:
                return 0.16 + (x - 0.10) * 0.133
            return 0.20

        sidepods.append(loft_profile(
            f"SidePod_{side}",
            [(-0.06, 0.30), (0.02, 0.60), (0.30, 0.64),
             (0.50, 0.60), (0.52, 0.36), (0.30, 0.26), (-0.06, 0.28)],
            pod_width, mat_body, depth_steps=5))
        # v4：进气口 box -> 梯形 scoop（12 tri 换 12 tri，净 0）。
        # 后口 x=-0.005 埋进放样体内部，前口留在前缘外 => 嵌入式喇叭口。
        sidepods.append(make_sidepod_scoop(f"SidePod_Inlet_{side}", y, mat_carbon))

    # ---- 空气箱：座舱后上方，进气口朝前 ----
    airbox = make_box("Airbox", (0.32, 0.22, 0.20),
                      (0.86, 0.0, 0.88), mat_body)
    airbox_inlet = make_box("Airbox_Inlet", (0.06, 0.15, 0.13),
                            (0.69, 0.0, 0.88), mat_carbon)

    # ---- 后视镜：细杆 + 镜面 ----
    mirrors = []
    for side, y in (("L", 0.42), ("R", -0.42)):
        mirrors.append(make_cylinder_between(
            f"Mirror_Stalk_{side}",
            (-0.30, y, 0.74), (-0.14, y * 1.33, 0.78), 0.012, mat_trim,
            vertices=6))
        mirrors.append(make_box(f"Mirror_{side}",
                                (0.06, 0.10, 0.045),
                                (-0.12, y * 1.38, 0.78), mat_body))

    # ---- 悬挂：v3 改 A 臂（上下各两根分叉臂）+ 斜拉杆 + 轮轴 ----
    # 车身中段半宽 0.55；轮心 y=±0.68，故轮内侧到车身有约 0.13 的间隙需要连杆填充
    suspension = []
    for side, y in (("L", 0.68), ("R", -0.68)):
        inner_y = 0.44 if y > 0 else -0.44      # 插入车身内部，保证相接
        for tag, cx, r, w in (("Front", -1.05, 0.34, 0.26),
                              ("Rear", 1.05, 0.50, 0.34)):
            hub_y = y
            axle = (cx, hub_y, r)
            # A 臂上臂：车身单点 → 轮上两点（顶视呈 A 形）
            suspension.append(make_cylinder_between(
                f"Susp_{tag}_{side}_AUp_In",
                (cx, inner_y, r + 0.26),
                (cx - 0.15, hub_y, r + 0.14), 0.026, mat_susp))
            suspension.append(make_cylinder_between(
                f"Susp_{tag}_{side}_AUp_Out",
                (cx, inner_y, r + 0.26),
                (cx + 0.15, hub_y, r + 0.14), 0.026, mat_susp))
            # A 臂下臂：车身单点 → 轮上两点
            suspension.append(make_cylinder_between(
                f"Susp_{tag}_{side}_ALow_In",
                (cx, inner_y, r - 0.08),
                (cx - 0.15, hub_y, r - 0.02), 0.026, mat_susp))
            suspension.append(make_cylinder_between(
                f"Susp_{tag}_{side}_ALow_Out",
                (cx, inner_y, r - 0.08),
                (cx + 0.15, hub_y, r - 0.02), 0.026, mat_susp))
            # 斜拉杆（从轮心斜向车身，避免正面看像悬空）
            suspension.append(make_cylinder_between(
                f"Susp_{tag}_{side}_Link",
                (cx + (0.20 if cx > 0 else -0.20), inner_y, r + 0.10),
                axle, 0.026, mat_susp))
            # 轮轴（穿过车身连到轮心）
            suspension.append(make_cylinder_between(
                f"Axle_{tag}_{side}",
                (cx, inner_y, r), (cx, hub_y + (0.04 if y > 0 else -0.04), r),
                0.040, mat_susp))

    return ([body, cockpit_tub, windscreen, driver_torso, driver_helmet,
             driver_visor, driver_neck, wing_main, wing_flap, wing_gurney,
             front_wing, front_flap, front_flap2, airbox, airbox_inlet]
            + endplates + struts + front_endplates + front_pylons
            + sidepods + mirrors + wheels + spokes + suspension)


# --------------------------------------------------------------- 相机灯光
def setup_camera_and_lights():
    """返回 (主视角相机, 后3/4视角相机)。"""
    # 主相机：侧前方 3/4 视角，整车居中满幅
    bpy.ops.object.camera_add(location=(-3.2, -7.4, 2.2))
    cam_main = bpy.context.object
    cam_main.name = "Camera"
    _aim(cam_main, (0.05, 0.0, 0.60))
    cam_main.data.lens = 62
    bpy.context.scene.camera = cam_main

    # 第二相机：后 3/4 视角（核对尾翼/对称性/座舱）
    bpy.ops.object.camera_add(location=(3.4, -6.9, 2.5))
    cam_rear = bpy.context.object
    cam_rear.name = "Camera_Rear"
    _aim(cam_rear, (-0.10, 0.0, 0.55))
    cam_rear.data.lens = 62

    # 三点照明
    bpy.ops.object.light_add(type="AREA", location=(-3.5, -4.0, 5.0))
    key = bpy.context.object
    key.name = "Key"
    key.data.energy = 1400
    key.data.size = 4.0
    key.rotation_euler = (Vector((0, 0, 0.6)) - key.location).to_track_quat("-Z", "Y").to_euler()

    bpy.ops.object.light_add(type="AREA", location=(4.5, 2.0, 3.0))
    fill = bpy.context.object
    fill.name = "Fill"
    fill.data.energy = 500
    fill.data.size = 5.0
    fill.rotation_euler = (Vector((0, 0, 0.6)) - fill.location).to_track_quat("-Z", "Y").to_euler()

    bpy.ops.object.light_add(type="AREA", location=(1.0, 4.5, 4.0))
    rim = bpy.context.object
    rim.name = "Rim"
    rim.data.energy = 700
    rim.data.size = 3.0
    rim.rotation_euler = (Vector((0, 0, 0.6)) - rim.location).to_track_quat("-Z", "Y").to_euler()

    # 世界环境
    world = bpy.data.worlds.new("World")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes["Background"]
    bg.inputs[0].default_value = (0.05, 0.06, 0.08, 1.0)
    bg.inputs[1].default_value = 1.0

    return cam_main, cam_rear


def _aim(cam, target):
    direction = Vector(target) - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def setup_render():
    scene = bpy.context.scene
    scene.render.resolution_x = 1280
    scene.render.resolution_y = 800
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    scene.render.image_settings.file_format = "PNG"

    # 优先 EEVEE（快），失败则退回 Cycles
    try:
        scene.render.engine = "BLENDER_EEVEE_NEXT"
    except TypeError:
        scene.render.engine = "CYCLES"
    if scene.render.engine == "CYCLES":
        scene.cycles.samples = 64
        scene.cycles.use_denoising = True
    else:
        try:
            scene.eevee.taa_render_samples = 64
        except AttributeError:
            pass

    # 地面（export_glb.py 导出前会删掉它）
    bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, 0))
    ground = bpy.context.object
    ground.name = "Ground"
    mat_ground = make_material("Ground", (0.10, 0.10, 0.11),
                               metallic=0.0, roughness=0.9)
    assign_material(ground, mat_ground)


def set_viewport_material_preview():
    """把各视图区的着色方式设为"材质预览"，这样保存后打开 .blend 就能直接看到颜色，
    不必手动去点着色模式（否则默认的"实体"模式一律显示灰模）。"""
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type != "VIEW_3D":
                continue
            for space in area.spaces:
                if space.type != "VIEW_3D":
                    continue
                try:
                    space.shading.type = "MATERIAL"
                    space.shading.color_type = "MATERIAL"
                except (AttributeError, TypeError):
                    pass


def render_to(path, cam):
    scene = bpy.context.scene
    scene.camera = cam
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("RENDERED", path)


def main():
    reset_scene()
    objs = build_car()
    cam_main, cam_rear = setup_camera_and_lights()
    setup_render()
    set_viewport_material_preview()

    # 保存
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("SAVED_BLEND", BLEND_PATH)

    # 两个视角各渲一张
    render_to(RENDER_PATH, cam_main)
    render_to(RENDER_PATH_REAR, cam_rear)

    # 导出前 Apply 所有 Modifier（v3 技术约束；保存后再 apply 一次，
    # 保证 .blend 里已是最终几何，export_glb.py 另带 export_apply=True）
    applied = apply_all_modifiers()
    print("APPLIED_MODIFIERS", applied)

    polys = sum(len(o.data.polygons) for o in bpy.data.objects
                if o.type == "MESH" and o.name != "Ground")
    print("OBJECTS", len([o for o in bpy.data.objects if o.type == "MESH"]))
    print("POLYS", polys)
    print("DONE")


if __name__ == "__main__":
    main()
