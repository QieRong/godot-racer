# -*- coding: utf-8 -*-
"""
build_racecar_3d.py  --  Blender 脚本（无头运行）

    blender.exe --background --factory-startup --python build_racecar_3d.py

按 2D 线稿的几何生成一辆 3D 赛车：
    * 车身（Nose / Cockpit / EngineCover / Floor / SidePod）用侧视轮廓放样成体
    * 车轮 4 只（前小后大），胎面 + 轮辋 + 轮毂分材质
    * 尾翼（主板 + 两侧端板 + 支柱）
    * 材质：车身红金属漆 / 轮胎橡胶黑 / 轮辋银 / 玻璃座舱
    * 相机 + 三灯照明 + Cycles/EEVEE 渲染出预览图
    * 保存 .blend

坐标约定：X = 车长（车头 -X），Y = 车宽，Z = 车高
"""
import math
import os
import sys

import bpy
import bmesh
from mathutils import Vector

OUT_DIR = os.path.dirname(os.path.abspath(__file__))   # 自定位：与本脚本同目录
BLEND_PATH = os.path.join(OUT_DIR, "racecar-3d.blend")
RENDER_PATH = os.path.join(OUT_DIR, "racecar-3d-render.png")

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
    for ring, rev in ((verts[0], True), (verts[-1], False)):
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


def make_cylinder_between(name, p0, p1, radius, material, vertices=16):
    """在两点之间生成一根圆柱（用作悬挂摇臂 / 拉杆）。"""
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


# ------------------------------------------------------------------- 建模
def build_car():
    # ---- 材质 ----
    mat_body = make_material("CarPaint_Red", (0.62, 0.045, 0.035),
                             metallic=0.55, roughness=0.28)
    mat_tire = make_material("Tire_Rubber", (0.022, 0.022, 0.024),
                             metallic=0.0, roughness=0.85)
    mat_rim = make_material("Rim_Silver", (0.78, 0.78, 0.80),
                            metallic=0.95, roughness=0.18)
    mat_glass = make_material("Cockpit_Glass", (0.35, 0.55, 0.75),
                              metallic=0.1, roughness=0.08, alpha=0.45)
    mat_trim = make_material("Trim_Dark", (0.05, 0.05, 0.055),
                             metallic=0.3, roughness=0.45)

    # ---- 车身侧视轮廓（X 前后, Z 高度；单位近似米）----
    # 由 2D 线稿换算：车长 3.6m，车头在 -1.8
    body_profile = [
        (-1.80, 0.30),   # 车头尖端
        (-1.72, 0.44),
        (-1.40, 0.50),
        (-1.02, 0.52),
        (-0.72, 0.62),
        (-0.40, 0.74),   # 前轮拱顶
        (-0.10, 0.72),
        (0.18, 0.80),    # 座舱前
        (0.46, 0.78),
        (0.72, 0.86),
        (1.06, 0.96),    # 引擎盖顶
        (1.34, 0.94),
        (1.56, 0.80),
        (1.66, 0.58),
        (1.80, 0.52),    # 车尾
        (1.80, 0.26),
        (0.60, 0.20),    # 底盘
        (-0.60, 0.20),
        (-1.30, 0.24),
    ]

    def body_width(x):
        """车身半宽：车头收窄、中段最宽、车尾略收。"""
        if x < -1.3:
            return 0.20
        if x < -0.7:
            return 0.20 + (x + 1.3) * 0.55
        if x < 0.9:
            return 0.53
        return 0.53 - (x - 0.9) * 0.18

    body = loft_profile("Body", body_profile, body_width, mat_body,
                        depth_steps=9)

    # ---- 座舱（驾驶舱凹陷 + 挡风玻璃）----
    cockpit_profile = [
        (0.20, 0.74), (0.34, 0.68), (0.52, 0.66),
        (0.60, 0.74), (0.52, 0.82), (0.30, 0.82),
    ]
    cockpit = loft_profile("Cockpit", cockpit_profile,
                           lambda x: 0.42, mat_trim, depth_steps=5)

    # ---- 车轮 ----
    # 前轮中心 X=-1.05 半径 0.34；后轮中心 X=+1.05 半径 0.50
    # 半宽：轮胎内侧贴住车身，外侧略外露（开轮式赛车）
    wheels = []
    for side, y in (("L", 0.68), ("R", -0.68)):
        for tag, cx, r, width in (("Front", -1.05, 0.34, 0.26),
                                  ("Rear", 1.05, 0.50, 0.34)):
            tire = make_cylinder(
                f"Tire_{tag}_{side}", radius=r, depth=width,
                location=(cx, y, r),
                rotation=(math.radians(90), 0, 0),
                material=mat_tire, vertices=64, bevel=0.035)
            wheels.append(tire)
            # 轮辋（略宽的浅色盘，形成可见轮圈）
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

    # ---- 尾翼：主板 + 端板 + 支柱 ----
    # 尺寸恢复正常后重新排布：翼展 1.50（端板在最外沿），支柱穿入翼面内部
    wing_z = 1.06
    wing_x = 1.68
    wing_span = 1.50
    wing_main = make_box("Wing_Main", (0.50, wing_span, 0.055),
                         (wing_x, 0.0, wing_z), mat_body)
    endplates = []
    for side, y in (("L", 0.735), ("R", -0.735)):
        endplates.append(make_box(f"Wing_Endplate_{side}",
                                  (0.50, 0.035, 0.28),
                                  (wing_x, y, wing_z - 0.02), mat_trim))
    # 支柱：上端穿进翼面（翼面 z 范围 1.0325~1.0875），下端插入引擎盖
    struts = []
    for side, y in (("L", 0.17), ("R", -0.17)):
        struts.append(make_box(f"Wing_Strut_{side}",
                               (0.12, 0.06, 0.42),
                               (1.64, y, 0.90), mat_trim))

    # ---- 前翼 / 车头小翼 ----
    nose_wing = make_box("Nose_Wing", (0.30, 0.95, 0.05),
                         (-1.66, 0.0, 0.36), mat_trim)

    # ---- 悬挂：把每个车轮接到车身，消除"轮子悬空"----
    # 车身中段半宽 0.53；轮心 y=±0.68，故轮内侧到车身有约 0.15 的间隙需要连杆填充
    mat_susp = make_material("Suspension_Steel", (0.42, 0.43, 0.46),
                             metallic=0.9, roughness=0.35)
    suspension = []
    for side, y in (("L", 0.68), ("R", -0.68)):
        inner_y = 0.44 if y > 0 else -0.44      # 插入车身内部，保证相接
        for tag, cx, r, w in (("Front", -1.05, 0.34, 0.26),
                              ("Rear", 1.05, 0.50, 0.34)):
            hub_y = y
            axle = (cx, hub_y, r)
            # 上下叉臂 + 一根斜拉杆：三点支撑，视觉上成"悬挂"
            for dz, arm_r in ((0.52 * r + r * 0.30, 0.030),
                              (-0.52 * r - r * 0.30, 0.030)):
                suspension.append(make_cylinder_between(
                    f"Susp_{tag}_{side}_{'Up' if dz > 0 else 'Low'}",
                    (cx, inner_y, r + dz * 0.55),
                    (cx, hub_y + (0.02 if y > 0 else -0.02), r + dz),
                    arm_r, mat_susp))
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

    return ([body, cockpit, wing_main, nose_wing]
            + endplates + struts + wheels + suspension)


# --------------------------------------------------------------- 相机灯光
def setup_camera_and_lights():
    # 相机：侧前方 3/4 视角，整车居中满幅
    bpy.ops.object.camera_add(location=(-3.0, -7.2, 2.1))
    cam = bpy.context.object
    cam.name = "Camera"
    target = Vector((0.10, 0.0, 0.62))
    direction = target - cam.location
    cam.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    cam.data.lens = 65
    bpy.context.scene.camera = cam

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

    # 地面
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


def main():
    reset_scene()
    objs = build_car()
    setup_camera_and_lights()
    setup_render()
    set_viewport_material_preview()

    # 保存
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("SAVED_BLEND", BLEND_PATH)

    # 渲染
    bpy.context.scene.render.filepath = RENDER_PATH
    bpy.ops.render.render(write_still=True)
    print("RENDERED", RENDER_PATH)

    tris = sum(len(o.data.polygons) for o in bpy.data.objects
               if o.type == "MESH" and o.name != "Ground")
    print("OBJECTS", len([o for o in bpy.data.objects if o.type == "MESH"]))
    print("POLYS", tris)
    print("DONE")


if __name__ == "__main__":
    main()
