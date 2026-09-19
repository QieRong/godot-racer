# -*- coding: utf-8 -*-
"""
export_glb.py -- 从 racecar-3d.blend 导出给 Godot 用的 race_car.glb

运行：
    blender.exe --background --factory-startup racecar-3d.blend --python export_glb.py

这个脚本替你做掉三件容易踩坑的事：
  1. 删除渲染用的 Ground 地面平面（否则它会跟着赛车一起进 Godot，
     既看不见又可能干扰 VehicleWheel3D 的悬挂射线检测）
  2. 保持每个车轮为独立节点（Tire_* / Rim_* / Hub_*），
     VehicleWheel3D 只做物理，轮子的视觉转动需要独立节点才能 rotate
  3. 用 +Y up 导出（glTF 约定 Y-up，Blender 是 Z-up），
     导入 Godot 后车头应指向 -Z

导出后自检：打印节点清单和包围盒，方便核对尺寸与朝向。
"""
import os

import bpy

OUT_DIR = os.path.dirname(os.path.abspath(__file__))   # 自定位：与本脚本同目录
GLB_PATH = os.path.join(OUT_DIR, "race_car.glb")

# Godot 侧期望：车头朝 -Z、Y 向上。Blender 的 -Y 经 Y-up 转换后成为 -Z，
# 所以模型在 Blender 里车头朝 -Y 即正确（我们的模型正是如此）。
EXPORT_Y_UP = True


def remove_render_only_objects():
    """删掉只给渲染用的辅助对象，避免混进游戏资源。"""
    removed = []
    for name in ("Ground",):
        obj = bpy.data.objects.get(name)
        if obj is not None:
            bpy.data.objects.remove(obj, do_unlink=True)
            removed.append(name)
    return removed


def report():
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    print("MESH_COUNT", len(meshes))

    # 轮胎节点是否独立，是轮子能否视觉转动的关键
    tires = sorted(o.name for o in meshes if o.name.startswith("Tire_"))
    print("TIRE_NODES", tires)

    # 整车包围盒：Blender 坐标（Z 向上）
    xs = []
    ys = []
    zs = []
    for o in meshes:
        for corner in o.bound_box:
            world = o.matrix_world @ __import__("mathutils").Vector(corner)
            xs.append(world.x)
            ys.append(world.y)
            zs.append(world.z)
    if xs:
        print("BBOX_X %.3f .. %.3f  (车长 %.3f)" % (min(xs), max(xs), max(xs) - min(xs)))
        print("BBOX_Y %.3f .. %.3f  (车宽 %.3f)" % (min(ys), max(ys), max(ys) - min(ys)))
        print("BBOX_Z %.3f .. %.3f  (车高 %.3f)" % (min(zs), max(zs), max(zs) - min(zs)))
        print("NOTE 车头位于 X=%.3f 一侧（Blender 中车头朝 -Y 时，Godot 里即朝 -Z）" % min(xs))


def main():
    removed = remove_render_only_objects()
    print("REMOVED", removed)

    kwargs = dict(
        filepath=GLB_PATH,
        export_format="GLB",
        use_selection=False,
        export_apply=True,
        export_yup=EXPORT_Y_UP,
        export_cameras=False,
        export_lights=False,
        export_extras=False,
        export_skins=False,
        export_morph=False,
    )

    try:
        bpy.ops.export_scene.gltf(**kwargs)
    except TypeError as exc:
        # 不同 Blender 小版本参数名可能略有差异，退化为最小参数集
        print("FULL_KWARGS_FAILED", exc)
        bpy.ops.export_scene.gltf(filepath=GLB_PATH, export_format="GLB")

    if os.path.exists(GLB_PATH):
        print("EXPORTED", GLB_PATH, os.path.getsize(GLB_PATH), "bytes")
    else:
        print("EXPORT_FAILED")

    report()


if __name__ == "__main__":
    main()
