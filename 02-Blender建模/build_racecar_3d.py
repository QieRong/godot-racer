# -*- coding: utf-8 -*-
"""
build_racecar_3d.py  --  Blender 脚本（无头运行）  [v7 头盔精度 + 面罩全宽]

    "E:/blender/blender.exe" -b --factory-startup --python build_racecar_3d.py

v7-visor（2026-10-14）头盔精度 + 面罩「盖满全宽」
  ① 头盔 subdivisions 1→2：**20 tri → 80 tri**。旧注释「subdivisions=1 →
     80 面」是错的 —— Blender 4.3.2 实测 0/1→20、2→80、3→320（见
     godot-logs/probe_ico_subdiv.py）。20 面 icosahedron 的内切比 0.795，
     正面就是一块内凹 24mm 的大平面，这才是「面罩像插在宝石上」的真因；
     80 面后网格最前点只内凹 5.6mm，头是圆的。
  ② 面罩 **平面盒 → 弧形壳体**（新增 make_visor_lens）。用户原设想
     「盒加宽到 0.20~0.22、0 tri」经实测推翻：面罩所在深度（x=0.195）上
     头盔截面全宽只有 **103mm**（半轴 0.1265 * sqrt(1-0.913²) = 51.7mm），
     盒做到 0.22 宽时端角会悬在脸前 **70.7mm**（v6 的 0.14 已经悬 31.7mm）
     —— 正是 v5/v6 修了 31 处的「连接处虚空」。故改为跟着头盔椭球弯的
     壳体：最外一圈 k=0.88 埋进头盔 13.8mm（过闸门 min_pen=0.010），
     中心区 k=1.05 凸出 ~6mm 才看得见。
     实测（godot-logs/probe_visor_gate.py）：pen=0.0160（余量 60%），
     视觉宽度 55% → **83%**（195mm → **210mm**，落在派单要求的 0.20~0.22
     区间内），悬空端 31.7mm → **0**（壳体贴曲面，端部不再外伸）。
  ③ 面数 5716 → **5824**（头盔 +60、面罩 12→60 tri；预算 6000，余量 176）。

v6-visor（2026-10-14）用户拍板「面罩做成更像风镜」：Driver_Visor 厚
    0.035→0.045、中心 x 0.200→0.195（**后表面恒在 x=0.2175 不变**，故
    pen 恒 0.0157，闸门不受影响），仅前表面前推 10mm ⇒ 正中外露量
    2.5mm→12.5mm。盒恒 12 tri ⇒ **Δtri=0**，总面数仍 5716。

v6（2026-10-14）v5 构建后 JOINT_GATE 65 条里剩 23 条 FAIL，本轮全部归零。
    面数 5696 -> 5716（+20，见下；预算 6000，余量 284）。物理相关几何与
    节点契约零变化。

  ★ 闸门三个测量坑补全（测不准比没闸门更危险）：
    坑3 采样密度：per_edge=5 固定采样让 0.53m 长的尾翼支柱只有 4 个内点
        （间距 11cm），整段跳过翼面 5.5cm 厚的穿透带 → Wing_Strut->
        Wing_Main 误报 pen=0。改为按几何尺度自适应（细件 8mm/大件 30mm）。
    性能  BVH 缓存提到模块级（Body 被查 20+ 次）；只对距对方表面 <50mm
        的采样点做奇偶射线内外判断；pen 报告封顶 50mm（闸门阈值 10mm，
        封顶不影响判定）。
    阈值  薄板母体的咬合深度上限 = 板厚的一半（点到闭合面最近距离不可能
        超过半厚），板厚 0.024 的襟翼类接头阈值放宽到 0.009（JOINT_CHECKS
        支持三条目 (child, host, min_pen)）。

  ★ 根因修复——车身侧壁"碗状凹陷"：封盖是 22 边形整块 n-gon，Blender
    三角化拉出的跨轮廓长弦把侧壁切进内部，名义 |y|=0.473 的侧壁实测只有
    0.28~0.40。这是侧条纹（d=0.075/0.091）和一堆"贴壁件"悬空的共同根源。
    loft_profile 新增 cap_grid=True：轮廓按 x 拆上下两链、按 x 配对成竖条
    quad，每条都是平面且 |y| 严格 = flat*width_fn(x)，body_skin_y(x) 恢复
    **精确式**。Body 封盖 20→60 tri（+20，全车 +20）。Windscreen/SidePod
    封盖本就是平面/无弦切问题，显式 cap_grid=False 保持不变。

  逐条修复（v5 遗留 23 FAIL → 0）：
    Wing_Main→4×Wing_Strut     坑3 采样密度（几何本来就对，pen 实为 0.0275）
    Wing_Endplate→Wing_Main     坑4 面内网格采样（细件 15 点/三角形、n=4/5
                               双重心格错层）；几何本来合格，实测咬合 25.5mm
                               （端板内表面插进翼面 32.5mm、翼面板厚 55mm →
                               理论上限 27.5mm，与实测一致）
    Wing_Endplate_Ext→Endplate 上延片改骑在端板顶缘正上方（y 同心、z 1.243），
                               嵌入 17.5mm；原位只咬 5mm 且被端板顶缘吃掉
    Front_Wing_Flap→Front_Wing z 0.35→0.304（主翼板厚 0.028 → 咬合上限
                               0.014，前下角必须插到板厚中线以下）
    Front_Wing_Flap2→Flap      z 0.425→0.334（襟翼下沉后顶缘只有 0.3134）
    Front_Wing_Flap→Pylon      采样密度 + 阈值 0.009（板厚上限 0.012）
    Windscreen_Frame_Up        杆往玻璃里推 5mm、后端抬 4mm（原整根贴外缘）
    Driver_Visor               x 0.190→0.200（0.190 实测 pen=0.0058 差 4.2mm；
                               探针扫描 0.195→0.0108 / 0.200→0.0157，取 0.200
                               兼顾咬合与"前缘仍外露"；见第 939 行注释）
    Stripe_White_Nose/Engine   厚 0.012→0.024、嵌深 12mm——0.012 薄片物理上
                               不可能"嵌 10mm 且外露可见"
    Stripe_Black_Side_L/R      根因=碗状封盖；修复后贴 x∈[-0.40,-0.06] 单一
                               平直段（表皮恒 0.473），长 0.50→0.34，厚 0.030
    Spoke→Rim                  厚 0.012→0.020、中心内收 2mm（原只搭 2mm；
                               辐条必须露在实心轮辋盘外才可见，只能加厚换咬合）
    Sidewall_Dot→Tire          厚 0.006→0.016、中心内收 3mm（原整块浮在外
                               面 1mm）；阈值 0.008（饰点类）
  ⚠ 已知未修（延续 v5 用户决定）：C-09 悬挂 16 根杆件（内端 inner_y=0.44
        超出实际表皮 0.310/0.383，外端取轮心 y=0.68 整根埋进胎体），
        Susp_* 相关接头**尚未纳入** JOINT_CHECKS，待下轮单独处理。

v5（2026-10-13）修「连接处虚空」——用户二次打回「后视镜/尾翼虚空链接」后的
全车 126 件连接处审计（godot-logs/car-joint-audit-2026-10-13.md）结果落地。
    **面数零变化（5696 tri，预算 6000）** —— 全部是坐标/尺寸推导修正，
    box 恒 12 tri、cylinder 段数不变。物理相关几何与节点契约零变化。

  C-01 后视镜杆根：(-0.30,y,0.74) → (-0.40,y,body_top_z(-0.40)-0.040=0.68)
        原 z=0.74 是照 x=-0.40 站台的甲板高度抄的，却用在甲板只有 0.60 的
        x=-0.30 → 杆根悬空 8.13cm；现在插入座舱前隔板 40mm
  C-02/03 尾翼 4 根支柱：size_z/center_z 由常数改为**按各自 x 跨度内最矮
        甲板反算**。原来底面恒在 z=0.69，而后对（sx=1.76，甲板 0.545→0.50）
        整根悬空 14~19cm、前对（sx=1.60）只有前下角咬住 10mm、后下角翘 7.5cm
  C-04 尾翼襟翼：z 1.14 → 1.120（-10° 旋转把前下角抬到 1.0925，高过主板
        顶面 1.0875 → 5mm 发丝缝）；格尼翼同步 -0.020
  C-05 前翼：端板 size_z 0.14→0.24 / z 0.30→0.35（覆盖到 z=0.47，够到第二
        襟翼）；两片襟翼展向 0.94/0.88 → 1.00（尖端插进端板 12.5mm）
  C-06 侧箱归位：**loft_profile 新增 y_center 形参**（v4 放样体被硬编码在
        Y=0，SidePod_L 与 SidePod_R 生成了完全相同的几何，都叠在车中线上，
        车从来没长出过侧箱；进气口却按 y=±0.55 生成，飘在 0.352m 外）
  C-07 条纹：侧黑条 0.552 → body_skin_y(x)=0.473（loft 的 flat=0.86 让实际
        表皮只有名义半宽的 86%，原值飘在车外 7.9cm）；两条白条限制在同一段
        单调斜面内并按该段实际斜率重设倾角（原来跨折点、尾端翘 69/108mm）
  C-10 车手颈部：x 0.265 → 0.200（脱开方向是 X 前后，不是 Z 上下）
  C-11 车手面罩：x 0.175 → 0.195（咬合 7mm → 27mm）
  ★ 新增**连接处闸门**：body_top_z(x) / body_skin_y(x) 两个推导函数 +
        assert_joint() + JOINT_CHECKS 定向接头表，构建末尾统一跑，
        任何一条 FAIL 直接 sys.exit(1)，坏几何不会流到 export/Godot。
  ⚠ 已知未修（本轮用户选择不做）：C-09 悬挂 16 根杆件（内端 inner_y=0.44
        超出实际表皮 0.310/0.383，外端取轮心 y=0.68 整根埋进胎体），
        Susp_* 相关接头**尚未纳入** JOINT_CHECKS，待下轮单独处理。

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
import sys

import bpy
import bmesh
from mathutils import Vector
from mathutils.bvhtree import BVHTree

OUT_DIR = os.path.dirname(os.path.abspath(__file__))   # 自定位：与本脚本同目录
BLEND_PATH = os.path.join(OUT_DIR, "racecar-3d.blend")
RENDER_PATH = os.path.join(OUT_DIR, "racecar-3d-render.png")
RENDER_PATH_REAR = os.path.join(OUT_DIR, "racecar-3d-render-rear.png")
RENDER_PATH_COCKPIT = os.path.join(OUT_DIR, "racecar-3d-render-cockpit.png")

# ------------------------------------------------------------ 面数预算参数（v3）
# GLB 三角面预算 6000；这些段数是"超出时优先砍"的旋钮，按细节优先级排序：
# 刹车盘 < 侧壁点 < 后视镜 < 轮辋外环 < 辐条数（不动）
BRAKE_SEGMENTS = 16      # 刹车盘圆周段数
RIM_LIP_SEGMENTS = 24    # 轮辋外环圆周段数
SIDEWALL_DOTS = 3        # 每轮侧壁装饰点数量
TIRE_SEGMENTS = 48       # 轮胎圆周段数（齿纹密度）

# ------------------------------------------------- 驾驶员头部几何（v7 提出为常量）
# v7 教训同 §车身放样：面罩/颈部一律由这三个常量**推导**，禁止在附件里重写
# 坐标。v6 的 31 处不合格全是"手写常数与母体放样体不符"这同一个错误。
# 头盔椭球半轴 = HELMET_R * HELMET_SCALE（x 前后 / y 左右 / z 上下）。
HELMET_R = 0.115
HELMET_SCALE = (1.0, 1.10, 1.06)          # 半轴 = (0.115, 0.1265, 0.1219)
HELMET_CENTER = (0.30, 0.0, 0.71)

# 弧形面罩壳体参数（v7；见 make_visor_lens docstring 的几何推导）
# 提到模块级是为了让 godot-logs/probe_visor_gate.py 能直接扫参数选型。
VISOR_PHI_DEG = 66.0     # 水平展向半角（决定"看起来的宽度"）
VISOR_PSI_DEG = 25.0     # 竖直半角（开口高度）
VISOR_NU = 10            # 展向网格数（面数 = NU*NV*2）
VISOR_NV = 3             # 竖向网格数
VISOR_K_RIM = 0.88       # 最外一圈半径系数（<1 = 埋进头盔，闸门咬合来源）
VISOR_K_TOP = 1.05       # 中心区半径系数（>1 = 凸出头盔，可见性来源）


# ------------------------------------------- 车身放样轮廓（v5：提到模块级）
# v5 起把 body_profile / body_width 提到模块级，因为「连接处闸门」要用它们
# 推导附件坐标。核心教训（v4 的三个 bug 全是这么来的）：
#   * 附件坐标必须**从母体推导**，不能拍脑袋写常数；
#   * loft 的 flat=0.86 会把最外层收到 0.86*hw —— 车身**实际**外表面是
#     body_skin_y(x) = 0.86 * body_width(x)，不是 body_width(x)。
BODY_PROFILE_UPPER = [
    (-1.80, 0.26), (-1.70, 0.38), (-1.45, 0.44), (-1.05, 0.46),
    (-0.72, 0.60), (-0.40, 0.72), (-0.30, 0.60), (0.10, 0.56),
    (0.55, 0.56), (0.68, 0.66), (0.80, 0.80), (1.05, 0.88),
    (1.35, 0.84), (1.58, 0.68), (1.70, 0.56), (1.80, 0.50),
]


def body_top_z(x):
    """车身上缘 z（由 body_profile 上缘线性插值）。

    任何要落在车身**上表面**的附件（尾翼支柱、条纹、后视镜杆…）都必须用它
    取高度。v4 的 Mirror_Stalk 把 x=-0.40 站台的甲板高度 0.72 抄到 x=-0.30
    （那里甲板只有 0.60）→ 杆根悬空 8.1cm。
    """
    up = BODY_PROFILE_UPPER
    if x <= up[0][0]:
        return up[0][1]
    if x >= up[-1][0]:
        return up[-1][1]
    for (x0, z0), (x1, z1) in zip(up, up[1:]):
        if x0 <= x <= x1:
            return z0 + (x - x0) / (x1 - x0) * (z1 - z0)
    return up[-1][1]


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


def body_skin_y(x):
    """车身放样体**实际**外表面的 |y|（v6 起为精确式）。

    loft_profile 的 flat=0.86 让最外层收到 0.86*hw。⚠ v5 及以前这**不是**
    精确式：封盖是一整块 n-gon，Blender 三角化拉出的跨轮廓长弦把侧壁
    "切"进内部 —— 名义 0.473 的侧壁实测只有 0.28~0.40（碗状凹陷），
    v4 侧条纹（0.552）和悬挂内端都栽在这里。
    v6 起封盖改为按 x 配对的竖条网格（见 loft_profile/cap_grid），
    侧面表皮 |y| 严格 = 0.86 * body_width(x)，本函数恢复精确。
    注意它只在**轮廓 x 段内**线性；跨段（如 x<-0.55）会有台阶，
    贴壁饰条的 x 跨度不要跨段（侧条纹因此限在 x -0.40..-0.06 平直段）。
    """
    return 0.86 * body_width(x)


# 完整侧视闭合轮廓（上缘：车头→车尾；下缘：车尾→车头）
# 座舱区（x -0.40..0.68）上缘凹陷成开口式座舱；鼻锥更低尖、引擎盖收窄后翘、
# 车尾收窄。总长 3.6m（-1.80..1.80）。
BODY_PROFILE = BODY_PROFILE_UPPER + [
    ( 1.80, 0.24), ( 1.20, 0.18), ( 0.40, 0.16), (-0.60, 0.16),
    (-1.20, 0.20), (-1.55, 0.24),
]


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
def _split_profile_chains(profile_xz):
    """把闭合侧视轮廓拆成上下两条 x 单调链（各自从 x 最小点到 x 最大点）。

    返回 (idx_a, idx_b)——profile 顶点索引链；拆不开（链不是 x 单调、
    或某条链不足 2 点）返回 None，调用方回退 n-gon 封盖。
    注意 x 最大点可能有两个顶点（如车尾上下各一个），i_max 取第一个，
    下链由另一侧绕回，天然不含重复 x。
    """
    n = len(profile_xz)
    i_min = min(range(n), key=lambda i: profile_xz[i][0])
    i_max = min(range(n), key=lambda i: (-profile_xz[i][0], i))
    idx_a = [(i_min + k) % n for k in range((i_max - i_min) % n + 1)]
    idx_b = [i_min] + [(i_max + k) % n
                       for k in range(1, (i_min - i_max) % n)][::-1]
    if len(idx_a) < 2 or len(idx_b) < 2:
        return None
    for idx in (idx_a, idx_b):
        xs = [profile_xz[i][0] for i in idx]
        if any(b <= a for a, b in zip(xs, xs[1:])):
            return None
    return idx_a, idx_b


def loft_profile(name, profile_xz, width_fn, material, depth_steps=9,
                 flat=0.86, edge_bevel=0.0, y_center=0.0, cap_grid=True):
    """把侧视轮廓 (x, z) 沿 Y 轴放样成实体。

    flat 越大侧壁越平（越像车）；两端各收一层形成圆角过渡。

    y_center（v5 新增）：放样体在 Y 方向的中心偏移，默认 0（向后兼容）。
        ⚠ v4 及以前放样体被硬编码在 Y=0（ring.append((px, y * hw, pz))），
          于是 loft_profile("SidePod_L") 与 ("SidePod_R") 生成了**完全相同**
          的几何——两个"侧箱"都叠在车中线上，车从来没长出过侧箱，
          而 SidePod_Inlet_L/R（按 y=±0.55 生成）孤零零飘在两侧 0.35m 外。
          任何需要偏离中线的放样体都必须显式传 y_center。

    cap_grid（v6 新增）：两端封盖的三角化方式。
        False = 整个轮廓一圈 n-gon（旧法）。⚠ n-gon 由 Blender 自行三角化，
        会拉出**跨越轮廓的长弦**——车身侧面表皮因此被"切"进内部：名义
        |y|=0.473 的侧壁实测只有 0.28~0.40（碗状凹陷），任何要贴侧壁的
        饰条都必然悬空（v5 侧条纹 d=0.075 的根因）。
        True  = 轮廓按 x 拆成上下两条链，上下**按 x 配对**成一排竖条 quad。
        每条 quad 的两个上点与两个下点 x 相同 → width_fn 相同 → |y| 相同
        → 每条都是平面，侧面表皮 |y| 严格 = flat * width_fn(x)，
        body_skin_y(x) 从此是**精确式**而不是近似式。
        代价：Body 封盖 20 tri -> 60 tri（+20）；小轮廓物不划算，传 False。
    """
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)

    n = len(profile_xz)
    chains = _split_profile_chains(profile_xz) if cap_grid else None
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
            ring.append((px, y_center + y * hw, pz))
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
    if chains is None:
        for ring, rev in ((verts[0], True), ((verts[-1]), False)):
            try:
                bm.faces.new(tuple(reversed(ring)) if rev else tuple(ring))
            except ValueError:
                pass
    else:
        idx_a, idx_b = chains
        # 下链按上链的 x 重采样（下链 x 单调，线性插值 z）
        chain_b = [profile_xz[i] for i in idx_b]
        zb = []
        k = 0
        for i in idx_a:
            x = profile_xz[i][0]
            while k < len(chain_b) - 2 and chain_b[k + 1][0] < x:
                k += 1
            (x0, z0), (x1, z1) = chain_b[k], chain_b[k + 1]
            t = 0.0 if x1 == x0 else (x - x0) / (x1 - x0)
            zb.append(z0 + t * (z1 - z0))
        for ring in (verts[0], verts[-1]):
            row_a = [ring[i] for i in idx_a]
            # 下链重采样点：x 与上点相同 -> width_fn 相同 -> y 与上点相同
            row_b = [bm.verts.new((row_a[j].co.x, row_a[j].co.y, zb[j]))
                     for j in range(len(row_a))]
            for j in range(len(row_a) - 1):
                try:
                    bm.faces.new((row_a[j], row_a[j + 1],
                                  row_b[j + 1], row_b[j]))
                except ValueError:
                    pass

    # v6：封盖改网格后统一重算法线，保证闭合体法线一致朝外
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
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
    """低面数球（驾驶员头盔）。

    ⚠ v7 更正：旧注释「subdivisions=1 → 80 面」是错的。Blender 4.3.2 实测
    （godot-logs/probe_ico_subdiv.py）：subdiv 0/1 → **20 tri**，2 → **80 tri**，
    3 → 320 tri。也就是说 v6 的头盔只有 20 面 —— 正面是一块内凹 ~24mm 的
    大平面，这才是「面罩像插在宝石上」的真因。v7 头盔改用 subdivisions=2。
    """
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions,
                                          radius=radius, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    assign_material(obj, material)
    return obj


def make_visor_lens(name, center, semi, phi_deg, psi_deg, nu, nv,
                    k_rim, k_top, material):
    """弧形面罩壳体：跟着头盔椭球前脸弯，最外一圈内嵌、中间外凸。

    ★ 为什么不能用平面盒（v7 实测推翻 v6 的假设，见下）
      头盔椭球半轴 (0.115, 0.1265, 0.1219)，面罩中平面在 x=0.195：
        u = (0.30 - 0.195) / 0.115 = 0.913
        该处截面半宽 = 0.1265 * sqrt(1 - u^2) = **0.0517（全宽 103mm）**
      也就是说：面罩所在的深度上，头只有 103mm 宽，而头盔名义全宽 253mm。
      v6 的 y=0.14（半宽 70mm）端角已经悬在脸前 31.7mm；按用户 v7 设想
      加宽到 y=0.22（半宽 110mm），端角会悬在脸前 **70.7mm** —— 这正是
      v5/v6 修了 31 处的「连接处虚空」原样复发。**平面盒在物理上做不到
      「既贴脸又盖满全宽」**，所以面罩必须是跟着曲面弯的壳体。

    形状（全部由头盔的 center/semi 推导，禁止手写常数）
      * 以头盔中心为原点，按方位角 phi（水平，绕到两侧）+ 仰角 psi（竖直）
        取椭球方向 dir = (-cos(phi)cos(psi), sin(phi)cos(psi), sin(psi))，
        顶点 = center + k * (semi.x*dir.x, semi.y*dir.y, semi.z*dir.z)
      * 半径系数 k：中心区 k_top（>1，凸出头盔表面才看得见），最外一圈
        k_rim（<1，埋进头盔 (1-k_rim)*R ≈ 14mm，满足 JOINT_MIN_PEN=0.010）
      * k 在 |u|<=1-2/nu、|v|<=1-2/nv 的平台区取 k_top，到最外一圈线性
        降到 k_rim —— 壳体在平台边缘与最外圈之间**穿过**头盔表面，视觉上
        就是「风镜从头盔里长出来」的那一圈硬边。

    面数 = nu * nv * 2（四边形网格）。法线统一朝外（背离头盔中心）。
    """
    c = Vector(center)
    phi_max = math.radians(phi_deg)
    psi_max = math.radians(psi_deg)
    pu = 1.0 - 2.0 / nu
    pv = 1.0 - 2.0 / nv

    def vert_at(u, v):
        fu = min(1.0, (1.0 - abs(u)) / max(1e-6, 1.0 - pu))
        fv = min(1.0, (1.0 - abs(v)) / max(1e-6, 1.0 - pv))
        k = k_rim + (k_top - k_rim) * fu * fv
        phi = u * phi_max
        psi = v * psi_max
        cp, sp = math.cos(phi), math.sin(phi)
        cq, sq = math.cos(psi), math.sin(psi)
        return (c[0] + k * semi[0] * (-cp * cq),
                c[1] + k * semi[1] * (sp * cq),
                c[2] + k * semi[2] * sq)

    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)

    bm = bmesh.new()
    grid = []
    for j in range(nv + 1):
        row = []
        v = -1.0 + 2.0 * j / nv
        for i in range(nu + 1):
            u = -1.0 + 2.0 * i / nu
            row.append(bm.verts.new(vert_at(u, v)))
        grid.append(row)
    for j in range(nv):
        for i in range(nu):
            bm.faces.new((grid[j][i], grid[j][i + 1],
                          grid[j + 1][i + 1], grid[j + 1][i]))
    bm.normal_update()
    # 法线统一朝外（背离头盔中心），否则 GLB 里背面剔除会把面罩剔掉
    dots = sum(f.normal.dot((f.calc_center_median() - c).normalized())
               for f in bm.faces)
    if dots < 0:
        bmesh.ops.reverse_faces(bm, faces=list(bm.faces))
    bm.to_mesh(mesh)
    bm.free()
    mesh.update()
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


# ------------------------------------------------- 连接处闸门（v5 新增）
# 为什么要有这道闸门：v4 交付后用户二次打回「后视镜/尾翼虚空连接」。审计
# （godot-logs/car-joint-audit-2026-10-13.md）查出 82 条定向接头里 31 条不合格，
# 其中 28 条是同一根因：附件坐标是拍脑袋写的常数，不是从母体放样体推导的。
# 光靠"改完再看渲染"永远堵不住，必须让脚本自己报错。
#
# ⚠⚠ 两个已踩过的坑，改这个函数前必读：
#   坑1  BVHTree.FromObject(obj, depsgraph) 返回的是物体**局部空间**的树
#        （Blender 4.3.2 实测），拿世界坐标查会得到米级假值
#        （Spoke/Rim 报 0.9664，真值 0.0020）。必须自己用世界坐标顶点
#        BVHTree.FromPolygons 建树。
#   坑2  只测顶点会漏判「细杆穿大盒」——Box 只有 8 顶点 + 1 面心，支柱从
#        翼面正中穿过时双方没有任何采样点落在对方内部。必须在**边上取内点**
#        做密集采样，才能采到穿透带里的点。
#   坑3（v6） 固定 per_edge=5 的边采样太稀：尾翼支柱 0.53m 长只有 4 个内点
#        （间距 11cm），而翼面板只有 5.5cm 厚 —— 采样点整段跳过穿透带，
#        Wing_Strut->Wing_Main 误报 pen=0。采样间距必须按**几何尺度**自适应
#        （细件 8mm / 大件 30mm），否则"细杆穿薄板"这类接头永远测不准。
#   坑4（v6） 面心每面只给 1 个点：端板与翼面 x 跨度完全重合时，端板 8 个
#        顶点全贴在翼面的 x 边界上、6 个面心全在翼面厚度带之外 —— 顶点/边/
#        面心三路采样全部打空，pen 卡在 0.0025。小件（<=64 顶点）的面内
#        必须按重心网格采样（每三角形 15 点）。
JOINT_MIN_PEN = 0.010      # 最小咬合深度（米）；小于此值判 FAIL
JOINT_PEN_CAP = 0.050      # 咬合深度报告上限（闸门只判 >= min_pen，够用）
JOINT_FAILS = []
_RAY_DIR = Vector((0.5773, 0.5773, 0.5773)).normalized()
_BVH_CACHE = {}            # v6：模块级缓存 —— 65 条接头里 Body 被查 20+ 次


def _world_bvh(obj, cache=None):
    """世界空间 BVH（见坑1）。cache 避免重复建树。"""
    cache = _BVH_CACHE if cache is None else cache
    if obj.name in cache:
        return cache[obj.name]
    me = obj.data
    me.calc_loop_triangles()
    mw = obj.matrix_world
    verts = [tuple(mw @ v.co) for v in me.vertices]
    tris = [tuple(lt.vertices) for lt in me.loop_triangles]
    cache[obj.name] = (BVHTree.FromPolygons(verts, tris), verts)
    return cache[obj.name]


def _is_inside(bvh, pt):
    """奇偶计数：点是否在闭合网格内部。"""
    p = Vector(pt)
    n = 0
    for _ in range(48):
        hit = bvh.ray_cast(p, _RAY_DIR, 60.0)
        if hit[0] is None:
            break
        n += 1
        p = hit[0] + _RAY_DIR * 1e-5
    return n % 2 == 1


def _dense_samples(obj, wverts, max_edges=48):
    """顶点 + 面心 + **边上的内点**（见坑2/坑3）+ **面内重心网格**（见坑4）。

    采样间距自适应：小件（<=64 顶点，盒/柱/杆）8mm + 面内 15 点/三角形；
    大件（放样体，几百顶点）30mm、不画面内网格，否则 Body 一件就上万
    采样点拖死闸门。
    """
    me = obj.data
    mw = obj.matrix_world
    small = len(me.vertices) <= 64
    spacing = 0.008 if small else 0.030
    pts = list(wverts) + [tuple(mw @ f.center) for f in me.polygons]
    edges = list(me.edges)
    if len(edges) > max_edges:
        edges = edges[::max(1, len(edges) // max_edges)]
    for e in edges:
        a, b = Vector(me.vertices[e.vertices[0]].co), Vector(me.vertices[e.vertices[1]].co)
        length = (b - a).length
        n = max(2, min(int(length / spacing) + 1, 40))
        for k in range(1, n):
            pts.append(tuple(mw @ (a + (b - a) * (k / float(n)))))
    if small:
        me.calc_loop_triangles()
        for lt in me.loop_triangles:
            a, b, c = (Vector(me.vertices[i].co) for i in lt.vertices)
            # 双重心格（坑4 续）：单一 n 的格点层位会与薄母体的厚度带**共振**
            # ——端板面格 n=4 的 z 层位 0.83+0.095k 恰好跨过翼面 55mm 厚度带，
            # 15 个点一个都不落进去。n=4 与 n=5 两套层位错开，共振即消除。
            for n in (4, 5):
                for i in range(n + 1):
                    for j in range(n + 1 - i):
                        k = n - i - j
                        pts.append(tuple(mw @ ((a * i + b * j + c * k) / n)))
    return pts


def _probe_joint(child, host):
    """返回 (d, pen, jointed)。

    d       : 双向采样点到对方表面的最小距离
    pen     : 落在对方内部的采样点里，到对方表面的最大距离（咬合深度，
              报告上限 JOINT_PEN_CAP；闸门只判 pen >= min_pen，封顶不影响结论）
    jointed : 是否有互相插入

    v6 性能：只对「距对方表面 < JOINT_PEN_CAP」的采样点做昂贵的内外判断
    （奇偶射线），远点直接跳过 —— 深埋点距表面一定近，不会漏。
    """
    cbvh, cv = _world_bvh(child)
    hbvh, hv = _world_bvh(host)
    d = float("inf")
    pen = 0.0
    jointed = False
    for pts, bvh_in in ((_dense_samples(child, cv), hbvh),
                        (_dense_samples(host, hv), cbvh)):
        for p in pts:
            r = bvh_in.find_nearest(Vector(p))
            if r[0] is None:
                continue
            if r[3] < d:
                d = r[3]
            if r[3] >= JOINT_PEN_CAP:
                continue          # 远点不可能给出有效咬合深度，省掉射线
            if _is_inside(bvh_in, p):
                jointed = True
                pen = max(pen, min(r[3], JOINT_PEN_CAP))
    return (0.0 if d == float("inf") else d), pen, jointed


def assert_joint(child_name, host_name, min_pen=JOINT_MIN_PEN):
    """测一条「子件 -> 应附着的母体」接头，不合格就记账并 print FAIL。"""
    child = bpy.data.objects.get(child_name)
    host = bpy.data.objects.get(host_name)
    if child is None or host is None:
        JOINT_FAILS.append((child_name, host_name))
        print("JOINT_FAIL %-24s -> %-22s (object missing)" % (child_name, host_name))
        return False
    d, pen, jointed = _probe_joint(child, host)
    ok = jointed and pen >= min_pen
    if not ok:
        JOINT_FAILS.append((child_name, host_name))
        print("JOINT_FAIL %-24s -> %-22s d=%.4f pen=%.4f (min_pen=%.3f)"
              % (child_name, host_name, d, pen, min_pen))
    else:
        print("JOINT_OK   %-24s -> %-22s d=%.4f pen=%.4f"
              % (child_name, host_name, d, pen))
    return ok


# 定向接头表：子件 -> 应附着的母体。
# 来自 godot-logs/car-joint-audit-2026-10-13.md §3。
# 条目可以是 (child, host) 用默认 JOINT_MIN_PEN，或 (child, host, min_pen)。
# ⚠ 薄板母体的咬合深度上限 = 板厚的一半（一个点距闭合面最近不可能超过
#   半厚），所以「襟翼片 -> 襟翼片」这类接头必须用 **小于板厚一半** 的阈值，
#   否则物理上不可能通过。0.024 板 -> 上限 0.012 -> 阈值 0.009。
JOINT_CHECKS = [
    ("Mirror_Stalk_L", "Body"), ("Mirror_Stalk_R", "Body"),
    ("Mirror_L", "Mirror_Stalk_L"), ("Mirror_R", "Mirror_Stalk_R"),
    ("Wing_Main", "Wing_Strut_L_0"), ("Wing_Main", "Wing_Strut_L_15"),
    ("Wing_Main", "Wing_Strut_R_0"), ("Wing_Main", "Wing_Strut_R_15"),
    ("Wing_Strut_L_0", "Body"), ("Wing_Strut_L_15", "Body"),
    ("Wing_Strut_R_0", "Body"), ("Wing_Strut_R_15", "Body"),
    ("Wing_Flap", "Wing_Main"),
    ("Wing_Gurney", "Wing_Flap"),
    ("Wing_Endplate_L", "Wing_Main"), ("Wing_Endplate_R", "Wing_Main"),
    ("Wing_Endplate_Ext_L", "Wing_Endplate_L"),
    ("Wing_Endplate_Ext_R", "Wing_Endplate_R"),
    ("Front_Wing", "Body"),
    ("Front_Wing_Flap", "Front_Wing"),
    ("Front_Wing_Flap", "Front_Wing_Pylon_L", 0.009),
    ("Front_Wing_Flap2", "Front_Wing_Flap", 0.009),
    ("Front_Wing_Flap2", "Body"),
    ("Front_Wing_Flap2", "Front_Wing_Endplate_L"),
    ("Front_Wing_Endplate_L", "Front_Wing"), ("Front_Wing_Endplate_R", "Front_Wing"),
    ("Front_Wing_Pylon_L", "Body"), ("Front_Wing_Pylon_R", "Body"),
    ("Front_Wing_Pylon_L", "Front_Wing"),
    ("Airbox", "Body"), ("Airbox_Inlet", "Airbox"),
    ("SidePod_L", "Body"), ("SidePod_R", "Body"),
    ("SidePod_Inlet_L", "SidePod_L"), ("SidePod_Inlet_R", "SidePod_R"),
    ("Cockpit_Tub", "Body"), ("Windscreen", "Body"),
    ("Windscreen_Frame_Up", "Windscreen"), ("Windscreen_Frame_Low", "Windscreen"),
    ("Windscreen_Frame_Side_L", "Windscreen"), ("Windscreen_Frame_Side_R", "Windscreen"),
    ("Driver_Torso", "Cockpit_Tub"), ("Driver_Torso", "Body"),
    ("Driver_Helmet", "Driver_Neck"), ("Driver_Neck", "Driver_Torso"),
    ("Driver_Visor", "Driver_Helmet"), ("Steering_Wheel", "Cockpit_Tub"),
    ("Driver_Hand_L", "Steering_Wheel"), ("Driver_Hand_R", "Steering_Wheel"),
    ("Stripe_White_Nose", "Body"), ("Stripe_White_Engine", "Body"),
    ("Stripe_Black_Side_L", "Body"), ("Stripe_Black_Side_R", "Body"),
    ("Spoke_Front_L_0", "Rim_Front_L"), ("Spoke_Rear_L_0", "Rim_Rear_L"),
    ("Rim_Lip_Front_L", "Rim_Front_L"), ("Rim_Lip_Rear_L", "Rim_Rear_L"),
    ("Hub_Nut_Front_L", "Hub_Front_L"), ("Hub_Nut_Rear_L", "Hub_Rear_L"),
    ("Brake_Disc_Front_L", "Rim_Front_L"), ("Brake_Disc_Rear_L", "Rim_Rear_L"),
    ("Sidewall_Dot_Front_L_0", "Tire_Front_L", 0.008),
    ("Sidewall_Dot_Rear_L_0", "Tire_Rear_L", 0.008),
    ("Axle_Front_L", "Hub_Front_L"), ("Axle_Rear_L", "Hub_Rear_L"),
]


def run_joint_gate():
    """构建末尾统一跑定向接头表；返回失败数。"""
    bpy.context.view_layer.update()
    for entry in JOINT_CHECKS:
        assert_joint(*entry)
    print("JOINT_GATE checks=%d failures=%d" % (len(JOINT_CHECKS), len(JOINT_FAILS)))
    return len(JOINT_FAILS)


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
    # v5：body_profile / body_width 已提到模块级（见文件头），
    #     因为连接处闸门的 body_top_z / body_skin_y 要用同一份数据推导附件坐标。
    body_profile = BODY_PROFILE

    body = loft_profile("Body", body_profile, body_width, mat_body,
                        depth_steps=9)

    # ---- 赛车条纹（v3：白/黑两条，贴面薄片，微突出防 z-fighting）----
    # v5 C-07：白条原来按 -14° 一个常数倾角横跨整段鼻锥/引擎盖，可车身上缘是
    # **折线**（鼻锥 0.26→0.38→0.44→0.46，引擎盖 0.80→0.88→0.84→0.68），
    # 一块平直薄片跨不过折点：鼻锥白条只在 x≈-1.55 处擦到 1mm，尾端翘起 69mm；
    # 引擎盖白条前端埋进 21mm、尾端翘起 108mm。
    # 修法：把条纹限制在**同一段单调斜面**内，倾角取该段实际斜率。
    # v6：厚度 0.012 -> 0.024。0.012 薄片物理上不可能同时"嵌进 ≥10mm 且
    # 外露可见"（嵌 10mm 就整体没顶了）——这是闸门 pen=0.0084/0.0086 差
    # 一口气的根因。0.024 后嵌 12mm、外露 12mm，闸门与观感同时满足。
    # 白条 1：鼻锥后段斜面（x -1.45..-1.05，甲板 0.44→0.46，斜率 +2.9°）
    #   中心 z = 甲板(0.45) - 嵌深(0.012) + 半厚(0.012) = 0.450
    make_box("Stripe_White_Nose", (0.40, 0.055, 0.024),
             (-1.25, 0.0, 0.450), mat_stripe_w,
             rotation=(0, math.radians(-3), 0))
    # 白条 2：引擎盖后段斜面（x 1.05..1.35，甲板 0.88→0.84，斜率 -7.6°）
    #   中心 z = 甲板(0.86) - 0.012 + 0.012 = 0.860
    make_box("Stripe_White_Engine", (0.30, 0.075, 0.024),
             (1.20, 0.0, 0.860), mat_stripe_w,
             rotation=(0, math.radians(8), 0))
    # 黑条：左右侧壁。
    # v5 C-07：v4 的 0.552 是按 body_width() 的**名义**半宽 0.55 写的，
    # 但 loft 的 flat=0.86 让实际表皮只有 0.86*0.55 = 0.473。
    # v6：封盖改竖条网格后 body_skin_y(x) 恢复精确（见 body_skin_y 注释），
    # 但它随 body_width 分段折线变化 —— x<-0.55 段表皮从 0.473 缩到 0.427，
    # 平直薄片跨段必悬空。所以 x 跨度收到**单一平直段** x∈[-0.40,-0.06]
    # （body_width 恒 0.55 → 表皮恒 0.473 的竖直平面），既避开归位后的
    # 侧箱（x≥-0.06），又一整条严丝合缝。
    # y：表皮 0.473，嵌入 12mm、外露 18mm → y 跨 [0.461,0.491]，中心 0.476。
    for side, sy in (("L", 1.0), ("R", -1.0)):
        make_box(f"Stripe_Black_Side_{side}", (0.34, 0.030, 0.10),
                 (-0.23, 0.476 * sy, 0.40), mat_stripe_b)

    # ---- 座舱：深色座舱底（盖住凹陷底面，形成"开口"观感）----
    cockpit_tub = make_box("Cockpit_Tub", (0.52, 0.56, 0.05),
                           (0.15, 0.0, 0.585), mat_trim)

    # ---- 挡风玻璃（v3：弧形放样面 + 上下边框）----
    # 弧形轮廓：基部嵌在座舱前隔板里、顶部探出车身上缘，沿 Y 方向两端微收
    # v6：宽度恒定 → 封盖本就是平面（无弦切问题），显式关 cap_grid 省 tri。
    # Frame_Up 原来整根贴在玻璃下缘**外侧**（起点还探出玻璃 x 范围 5mm），
    # 只在中间擦到 7mm —— 闸门 pen=0.0071。沿法向往玻璃里推 5mm、后端再抬
    # 4mm 补偿玻璃楔形收窄 → 嵌入 12~16mm、外露 5~8mm，仍是可见饰条。
    windscreen = loft_profile(
        "Windscreen",
        [(-0.36, 0.58), (-0.26, 0.70), (-0.14, 0.745), (-0.04, 0.70)],
        lambda x: 0.31, mat_glass, depth_steps=5, flat=0.90,
        cap_grid=False)
    # 上下边框（细杆沿弧缘）
    make_cylinder_between("Windscreen_Frame_Up",
                          (-0.365, 0.0, 0.580), (-0.045, 0.0, 0.704),
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
    # v7：subdivisions 1→2（20 tri → 80 tri）。v6 的 20 面头盔正面是一块
    #   内凹 ~24mm 的大平面（icosahedron 内切比 0.795），面罩贴上去就像
    #   「插在宝石上」。80 面后网格面心只内凹 ~1.7mm，头是圆的。
    #   Δtri = +60（5716 → 5776，预算 6000）。
    # ⚠ 头盔几何是面罩/颈部的**唯一真相源**：半径与缩放提出为常量，
    #   面罩壳体由它推导，禁止在附件里重写一套坐标。
    driver_helmet = make_sphere("Driver_Helmet", HELMET_R, tuple(HELMET_CENTER),
                                HELMET_SCALE, mat_helmet, subdivisions=2)
    # 面罩：v7 起改为**弧形壳体**（make_visor_lens），不再是平面盒。
    #   平面盒加宽到 0.20~0.22 会让端角悬在脸前 50~70mm（推导见
    #   make_visor_lens 的 docstring），所以"盖满全宽"只能靠曲面实现。
    #   参数取值的依据（全部实测，见 godot-logs/probe_visor_gate.log）：
    # 最终取值由 godot-logs/probe_visor_gate.py 扫参实测确定（见该文件日志）：
    #   VISOR_PHI_DEG / NU 决定视觉宽度（越宽越费面数），K_RIM 决定闸门咬合，
    #   K_TOP 决定外凸可见量。改任一个都要重跑探针与 JOINT_GATE。
    driver_visor = make_visor_lens(
        "Driver_Visor",
        (HELMET_CENTER[0], 0.0, HELMET_CENTER[2] + 0.010),
        (HELMET_R * HELMET_SCALE[0], HELMET_R * HELMET_SCALE[1],
         HELMET_R * HELMET_SCALE[2]),
        VISOR_PHI_DEG, VISOR_PSI_DEG, VISOR_NU, VISOR_NV,
        VISOR_K_RIM, VISOR_K_TOP, mat_visor)
    # 颈部护具：头盔下方的连接颈
    # v5 C-10：v4 的 x=0.265 使颈盒落在 x∈[0.215,0.315]，而躯干后表面只到
    # x=0.18 → 悬空 3.5cm（实测 d=0.0350 DETACHED）。
    # 注意脱开方向是 **X（前后）** 不是 Z（上下），所以要往前挪而不是往上抬。
    driver_neck = make_box("Driver_Neck", (0.10, 0.13, 0.055),
                           (0.200, 0.0, 0.645), mat_trim)
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
            # v6：辐条原 y_out = y+(0.52w+0.004)，厚 0.012 → 与轮辋外面
            # （0.52w）只搭 2mm —— pen=0.002 的根因。辐条必须露在实心轮辋
            # 盘面**外侧**才可见，所以只能靠加厚换咬合：厚 0.020、中心
            # 内收 2mm → 嵌入 12mm、外露 8mm，闸门与观感同时满足。0 tri。
            y_out = y + (width * 0.52 - 0.002) * sign     # 辐条：最外侧
            # 每轮 5 根辐条
            for i in range(5):
                a = math.radians(i * 72 + 18)
                loc = (cx + math.cos(a) * r * 0.30,
                       y_out,
                       r + math.sin(a) * r * 0.30)
                sp = make_box(f"Spoke_{tag}_{side}_{i}",
                              (r * 0.58, 0.020, 0.028), loc, mat_rim,
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
            # v6：原 (厚 0.006, 外偏 +0.004) 整块浮在胎侧外面 1mm（pen=0）。
            # 厚 0.016、中心内收 3mm → 嵌入 11mm、外露 5mm（配平块观感）。
            tireobj = bpy.data.objects.get(f"Tire_{tag}_{side}")
            for i in range(SIDEWALL_DOTS):
                a = math.radians(90 + i * 120)
                loc = (cx + math.cos(a) * (r - 0.012),
                       y + sign * (width * 0.5 - 0.003),
                       r + math.sin(a) * (r - 0.012))
                dot = make_box(f"Sidewall_Dot_{tag}_{side}_{i}",
                               (0.020, 0.016, 0.020), loc, mat_stripe_w,
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
        # v6：上延片原 (y*1.02, wing_z+0.19=1.25) —— y 方向只咬合 5mm 且
        # 底角离端板顶缘只有 5mm，最近表面距离被顶缘吃掉 → pen=0.005。
        # 改成骑在端板**顶缘正上方**：y 与端板同心（咬合 17.5mm 由半厚差给足）、
        # z 1.243 使底面埋进端板 12mm、顶部外露 78mm 仍是可见小翼。
        endplates.append(make_box(f"Wing_Endplate_Ext_{side}",
                                  (0.07, 0.030, 0.09),
                                  (wing_x - 0.02, y, 1.243),
                                  mat_trim))
    # 支柱 2 → 4 根（前后各一对）：上端穿进翼面，下端插入车身
    # v5 C-02/C-03：v4 把 4 根支柱的 size_z/center_z 写死成同一个常数
    # （0.42 / 0.90 → 底面恒在 z=0.69），但车尾甲板从 x=1.58 的 0.68 一路
    # 掉到 x=1.80 的 0.50，于是：
    #   * 后一对（sx=1.76，甲板 0.545→0.50）底面悬空 0.145~0.19m，实测离
    #     车身 0.1025m —— 尾翼后半段**完全没有落地**；
    #   * 前一对（sx=1.60，甲板 0.697→0.615）只有前下角咬住 10mm，后下角
    #     离甲板 7.5cm —— 楔形咬合，就是用户看到的"尾翼虚空"。
    # 现在每根支柱按**自己 x 跨度内最矮的甲板**反算底面，保证整条底面进体。
    struts = []
    _strut_top = 1.110                    # 上端保持插进翼面（Wing_Main 底 1.0325）
    for sx in (1.60, 1.76):
        # 取支柱 x 跨度 [sx-0.045, sx+0.045] 内的最低甲板，再往下插 35mm
        _low = min(body_top_z(sx - 0.045), body_top_z(sx + 0.045))
        _bottom = _low - 0.035
        _size_z = _strut_top - _bottom
        for side, y in (("L", 0.17), ("R", -0.17)):
            struts.append(make_box(f"Wing_Strut_{side}_{int((sx - 1.60) * 100)}",
                                   (0.09, 0.06, _size_z),
                                   (sx, y, (_strut_top + _bottom) / 2.0), mat_trim))
    # 上襟翼（碳纤维，后缘上翘 10°）+ 格尼翼
    # v5 C-04：v4 襟翼中心 z=1.14，经 -10° 旋转后**最低点（前下角）落在
    # z=1.0925**，而 Wing_Main 顶面在 1.0875 → 整片底面离主板 5mm 的发丝缝
    # （实测 d=0.0050 FLOATING）。下沉 0.020 → 前下角 1.0725，插入主板 15mm。
    # 注意不能只下沉 0.005（那样只是"贴到"、咬合深度 0，闸门仍会 FAIL）。
    wing_flap = make_box("Wing_Flap", (0.32, 1.44, 0.04),
                         (1.62, 0.0, 1.120), mat_carbon,
                         rotation=(0, math.radians(-10), 0))
    # 格尼翼跟随襟翼一起下沉，保持两者咬合
    wing_gurney = make_box("Wing_Gurney", (0.03, 1.40, 0.045),
                           (1.78, 0.0, 1.165), mat_carbon)

    # ---- 前翼：3 层翼片 + 垂直端板 + 挂柱 ----
    front_wing = make_box("Front_Wing", (0.28, 1.00, 0.028),
                          (-1.70, 0.0, 0.27), mat_trim)
    # v5 C-05：端板 z 只覆盖 [0.23, 0.37]，够不到第二襟翼（0.39~0.46）；
    # 且两片襟翼半展 0.47/0.44 < 端板内表面 0.4875，横向也差 4.75cm。
    # 修法 0 tri：端板加高到 z∈[0.23,0.47]，两片襟翼展向加长到与主翼同宽 1.00，
    # 使尖端插进端板 12.5mm。
    # v6 C-04（复检）：主翼顶 0.284，襟翼经 -12° 旋转后**最低角 z=0.3154**
    # —— v5 只下沉到"贴上"还有 31mm 缝（实测 d=0.0314）。几何约束：
    # 主翼板厚 0.028 → 任何咬合深度上限 0.014，要 pen≥0.010 就必须让襟翼
    # 前下角插到主翼**板厚中线以下**。下沉 0.046 → 前下角 0.2694，插进
    # 板内 13.4mm（距上下表面各 ≥13mm）。
    front_flap = make_box("Front_Wing_Flap", (0.22, 1.00, 0.024),
                          (-1.62, 0.0, 0.304), mat_trim,
                          rotation=(0, math.radians(-12), 0))
    # 第三层翼片（v3 新增，位置更高更陡）
    # v6：襟翼下沉后其顶缘斜线在 x=-1.6335 处只有 0.3134，Flap2 前下角
    # (0.3896) 还悬着 76mm。下沉到 0.334 → 前下角 0.2986，插进襟翼板内
    # ~14mm（襟翼板厚 0.024 → 咬合上限 0.012，阈值相应放宽到 0.009）。
    front_flap2 = make_box("Front_Wing_Flap2", (0.18, 1.00, 0.022),
                           (-1.55, 0.0, 0.334), mat_trim,
                           rotation=(0, math.radians(-16), 0))
    front_endplates = []
    for side, y in (("L", 0.50), ("R", -0.50)):
        front_endplates.append(make_box(f"Front_Wing_Endplate_{side}",
                                        (0.30, 0.025, 0.24),
                                        (-1.70, y, 0.35), mat_trim))
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

        # v5 C-06/S1：传 y_center=y，把侧箱从车中线挪到两侧。
        # v4 两个侧箱都叠在 y=0（loft 没有 y 偏移参数），进气口却按 y=±0.55
        # 生成 → 进气口离侧箱 0.352m、离车身 0.0455m，两侧各挂一块孤立的黑盒子。
        sidepods.append(loft_profile(
            f"SidePod_{side}",
            [(-0.06, 0.30), (0.02, 0.60), (0.30, 0.64),
             (0.50, 0.60), (0.52, 0.36), (0.30, 0.26), (-0.06, 0.28)],
            pod_width, mat_body, depth_steps=5, y_center=y,
            cap_grid=False))     # 小轮廓 n-gon 封盖无弦切问题，省 tri
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
    # v5 C-01：v4 的杆根 (-0.30, y, 0.74) 是**抄错站台**——z=0.74 照的是
    # x=-0.40 处座舱前隔板顶（body_top_z(-0.40)=0.72），却用在 x=-0.30，
    # 那里甲板已经降到 0.60，于是杆根悬在甲板上方 0.14m（实测离车身 0.0813m）。
    # 新杆根取 x=-0.40（甲板 0.72）并下沉到 0.68 → **插入甲板 40mm**。
    # 高度一律走 body_top_z(x) 推导，不再写死。
    _stalk_root_z = body_top_z(-0.40) - 0.040          # = 0.72 - 0.040 = 0.680
    for side, y in (("L", 0.42), ("R", -0.42)):
        mirrors.append(make_cylinder_between(
            f"Mirror_Stalk_{side}",
            (-0.40, y, _stalk_root_z), (-0.14, y * 1.33, 0.78), 0.012, mat_trim,
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
    """返回 (主视角相机, 后3/4视角相机, 座舱特写相机)。"""
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

    # 第三相机：座舱特写（v5 加，机位沿用 godot-logs/cockpit_closeup.py）
    # 用来核对：双手是否真握在方向盘上、后视镜杆根是否长在车身里、挡风玻璃边框
    bpy.ops.object.camera_add(location=(-0.9, -1.05, 1.6))
    cam_ckp = bpy.context.object
    cam_ckp.name = "Camera_Cockpit"
    _aim(cam_ckp, (-0.05, 0.0, 0.64))
    cam_ckp.data.lens = 55

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

    return cam_main, cam_rear, cam_ckp


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
    cam_main, cam_rear, cam_ckp = setup_camera_and_lights()

    # ★ 连接处闸门：附件是不是真的长在母体上（JOINT_CHECKS，见文件头）
    run_joint_gate()

    setup_render()
    set_viewport_material_preview()

    # 保存
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    print("SAVED_BLEND", BLEND_PATH)

    # 三个视角各渲一张（主 / 后3/4 / 座舱特写）
    render_to(RENDER_PATH, cam_main)
    render_to(RENDER_PATH_REAR, cam_rear)
    render_to(RENDER_PATH_COCKPIT, cam_ckp)

    # 导出前 Apply 所有 Modifier（v3 技术约束；保存后再 apply 一次，
    # 保证 .blend 里已是最终几何，export_glb.py 另带 export_apply=True）
    applied = apply_all_modifiers()
    print("APPLIED_MODIFIERS", applied)

    polys = sum(len(o.data.polygons) for o in bpy.data.objects
                if o.type == "MESH" and o.name != "Ground")
    print("OBJECTS", len([o for o in bpy.data.objects if o.type == "MESH"]))
    print("POLYS", polys)

    # 连接处闸门不绿 -> 非零退出，别让坏几何流到 export/Godot
    if JOINT_FAILS:
        print("JOINT_GATE_FAILED %d" % len(JOINT_FAILS))
        for a, b in JOINT_FAILS:
            print("  FAILED_JOINT %s -> %s" % (a, b))
        sys.exit(1)
    print("DONE")


if __name__ == "__main__":
    main()
