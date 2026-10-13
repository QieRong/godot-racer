# -*- coding: utf-8 -*-
"""SPLIT-CHECKS-AI-003 抽取器（先跑"干跑"确认边界，再落地）。

职责：从 scenes/main.gd（HEAD 态，工作区与 HEAD 一致）逐行抽出批次③ 的
9 个 AI_* 常量 + 5 个 _check_* 函数（含文档块），施加**文档化的机械变换**，
拼成 scripts/checks/ai.gd。

为什么要脚本而不是手抄：bench 批的教训是"手抄会转录漂移"。逐行搬运 + 事后
diff 复核（split-checks-ai-textverify.py）才能把漂移压到零。

机械变换（全部在这里列出，textverify 逐个核对）：
  T1  func _check_opponents()  -> func run_opponents()
  T2  func _check_ai_diag()    -> func run_ai_diag()
  T3  func _check_avoid()      -> func run_avoid()
  T4  func _check_obstacles()  -> func run_obstacles()
  T5  func _check_ai_start()   -> func run_ai_start()
  T6  get_node_or_null("Track")           -> _track
  T7  get_node_or_null("Obstacles")       -> _obstacle_field
  T8  get_world_3d().direct_space_state   -> _world_3d.direct_space_state
  T9  await get_tree().physics_frame      -> await _physics_frame.call()
  T10 await _sample_physics_ms(           -> await _sample_physics_ms.call(
其余字符**逐字节原样**（含 tab 缩进、print 文案、注释）。
"""
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAIN = os.path.join(ROOT, "godot-racer", "scenes", "main.gd")
OUT = os.path.join(ROOT, "godot-racer", "scripts", "checks", "ai.gd")

with io.open(MAIN, "r", encoding="utf-8", newline="") as f:
    raw = f.read()
lines = raw.replace("\r\n", "\n").split("\n")   # 1-based 由 idx+1 表示


def L(n):
    return lines[n - 1]


def blk(a, b):
    """取 1-based 闭区间 [a,b]。"""
    return lines[a - 1:b]


# ---------------------------------------------------------------- 边界断言
# 断言用**去引号的安全片段**，避免中英文引号形态差异造成假红。
expect = {
    635: "## aidiag 里",
    691: "const AI_BEND_GUARD_SEG := 3.0",
    1142: "## AI 对手验收：要求每台对手都能",
    1149: "func _check_opponents() -> void:",
    1216: "printerr(\"[自检] 对手验收 ✘ 见上方 ✘ 行\")",
    1315: "## AI 行为诊断：",
    1327: "func _check_ai_diag() -> void:",
    1688: "printerr(\"[自检] AI 目标速度判定 ✘ 见上方 ✘ 行",
    1829: "## AI 避让玩家验收：",
    1836: "func _check_avoid() -> void:",
    1926: "## 障碍物验收。三个必须成立的事实：",
    1931: "func _check_obstacles() -> void:",
    2054: "## 并排发车验收：",
    2059: "func _check_ai_start() -> void:",
    2115: "printerr(\"[自检] 并排发车验收 ✘ 见上方 ✘ 行\")",
}
bad = []
for n, want in sorted(expect.items()):
    if want not in L(n):
        bad.append("L%d 期望含 %r 实得 %r" % (n, want, L(n)))
if bad:
    print("!! 边界断言失败（行号漂移了）：")
    for b in bad:
        print("   " + b)
    sys.exit(2)

# 校验空隙：文档块上方应是 2 个空行（保持分隔约定）
for anchor in (1142, 1315, 1829):
    if not (L(anchor - 1).strip() == "" and L(anchor - 2).strip() == ""):
        bad.append("L%d 上方不是 2 个空行" % anchor)
# 校验各行块尾部下一个非空行
def next_nonblank(after):
    i = after
    while i <= len(lines) and lines[i - 1].strip() == "":
        i += 1
    return i

print("边界确认 OK。删除总量：")
CONSTS = blk(635, 691)
OPP = blk(1142, 1216)
DIAG = blk(1315, 1688)
TRIO = blk(1829, 2115)
for name, b in (("CONSTS", CONSTS), ("OPP", OPP), ("DIAG", DIAG), ("TRIO", TRIO)):
    print("  %-7s %4d 行  (%s .. %s)" % (name, len(b), b[0][:26], b[-1][:26]))
print("  合计删除 = %d 行" % (len(CONSTS) + len(OPP) + len(DIAG) + len(TRIO)))
print("  下一个非空行检查：OPP尾->L%d  DIAG尾->L%d  TRIO尾->L%d" % (
    next_nonblank(1217), next_nonblank(1689), next_nonblank(2116)))

# ---------------------------------------------------------------- 机械变换
SUBS = [
    ("func _check_opponents() -> void:", "func run_opponents() -> void:"),
    ("func _check_ai_diag() -> void:", "func run_ai_diag() -> void:"),
    ("func _check_avoid() -> void:", "func run_avoid() -> void:"),
    ("func _check_obstacles() -> void:", "func run_obstacles() -> void:"),
    ("func _check_ai_start() -> void:", "func run_ai_start() -> void:"),
    ('get_node_or_null("Track")', "_track"),
    ('get_node_or_null("Obstacles")', "_obstacle_field"),
    ("get_world_3d().direct_space_state", "_world_3d.direct_space_state"),
    ("await get_tree().physics_frame", "await _physics_frame.call()"),
    ("await _sample_physics_ms(", "await _sample_physics_ms.call("),
]

counts = {}
def tf(text):
    for a, b in SUBS:
        n = text.count(a)
        if n:
            counts[a] = counts.get(a, 0) + n
            text = text.replace(a, b)
    return text


CONSTS_T = tf("\n".join(CONSTS))
OPP_T = tf("\n".join(OPP))
DIAG_T = tf("\n".join(DIAG))
TRIO_T = tf("\n".join(TRIO))

print("\n替换计数（逐条）：")
for a, _ in SUBS:
    print("  %-40s %d" % (a, counts.get(a, 0)))

# 残留自检：变换后不该再有裸 get_node / get_tree / get_world_3d
for pat in ("get_node", "get_tree", "get_world_3d", "_check_opponents", "_check_ai_diag",
            "_check_avoid", "_check_obstacles", "_check_ai_start"):
    blob = CONSTS_T + OPP_T + DIAG_T + TRIO_T
    c = blob.count(pat)
    if c:
        print("  !! 变换后残留 %s x%d" % (pat, c))

print("\nawait 统计（模块正文）：")
blob = CONSTS_T + OPP_T + DIAG_T + TRIO_T
print("  await 总数            =", blob.count("await "))
print("  await _physics_frame.call() =", blob.count("await _physics_frame.call()"))
print("  await _sample_physics_ms.call( =", blob.count("await _sample_physics_ms.call("))

# ---------------------------------------------------------------- 写出模块
HEADER = u'''extends RefCounted
## AI 验收族（`--check=opponents` / `aidiag` / `avoid` / `obstacles` / `aistart`）：
## 对手跑圈能力、AI 行为诊断（抢跑/不动/自救 + 任务 15「AI 能否跑到最高限速附近」）、
## 避让玩家路障、障碍物位置与碰撞与通行缝隙、并排发车（玩家不动对手不动）。
## main.gd 的 `match _check:` 分发口经
## `await _checks_ai.run_opponents()` / `run_ai_diag()` / `run_avoid()` /
## `run_obstacles()` / `run_ai_start()` 进入本模块。
##
## 2026-10-13 SPLIT-CHECKS-AI-003：从 scenes/main.gd 整块拆出，**纯迁移、
## 行为零变化** —— 逻辑、print 文案（`[自检]` 前缀、逐 2.5s 的 aidiag 采样行、
## ✔/✘ 判定行、%占位顺序全部照搬，A/B 要逐行比对日志）、注释全部照搬，
## 没有第二份实现。
## 迁了什么：
##   · 5 个函数：`_check_opponents` → 公开入口 `run_opponents`、`_check_ai_diag`
##     → `run_ai_diag`、`_check_avoid` → `run_avoid`、`_check_obstacles` →
##     `run_obstacles`、`_check_ai_start` → `run_ai_start`（本族没有内部辅助函数，
##     5 个入口一一对应、可 audit）；
##   · 9 个常量：`AI_RECOVER_WARN_SEC` / `AI_TARGET_MIN_KMH` /
##     `AI_TARGET_PINNED_PCT` / `AI_TARGET_PINNED_KMH` / `AI_TARGET_RED_MAX_KMH` /
##     `AI_TARGET_NEAR_PHYS_FRAC` / `AI_TARGET_NEAR_CAP_PCT` /
##     `AI_TARGET_NEAR_CAP_FRAC` / `AI_BEND_GUARD_SEG`（全仓只有 `run_ai_diag`
##     读它们 —— 已 grep 实证；check-docs.ps1 未登记、非 ADR-001 永久居民，
##     随族迁移。**不在此复制闸门登记的三 CASES 常量**）；
##   · 本族原实现就没有模块级状态（全是函数内局部量），迁移后零新增状态
##     （下面 10 个 var 全是注入 + 只读代理，见"外部注入"段）。
##
## ⚠ 四处关键决策（逐条定死，以后别悄悄改回去）：
##
##   ① **车 / 赛道 / 障碍场 / 物理世界经 setup() 注入，模块不 get_node**：
##      迁移前族内用 `get_node_or_null("Track")` 取静态兄弟节点（4 处）、
##      `get_node_or_null("Obstacles")` 取障碍容器（1 处）、`get_world_3d()`
##      取射线用的物理世界（1 处），全部改为注入 + **保留原 null 检查**
##      （§2.4：禁反向持有场景；layout / bench / opponent_spawner 同款约定）。
##      ⚠ `get_node_or_null("Obstacles")` 拿到的就是 main 的 `_obstacle_field`
##      本体（它是 add_child 进树、name = "Obstacles" 的同一个节点），注入同一实例
##      即零语义差。
##
##   ② **physics_frame 经 Callable 注入**：迁移前帧循环里是
##      `await get_tree().physics_frame`；模块是 RefCounted、不在场景树上，没有
##      get_tree()，由 main 把 `_shot_physics_frame`（返回 physics_frame 信号本体）
##      以 Callable 递进来。模块里 `await _physics_frame.call()` 与迁移前
##      `await get_tree().physics_frame` 是**同一个 Signal**，协程恢复时机不变
##      （screenshot_mode / bench 同款决策，2026-10-13 实证）。
##
##   ③ **`_sample_physics_ms` 采样器经 Callable 注入、不搬进模块**：
##      `run_opponents` 要两处 `await _sample_physics_ms(...)`，而同一个采样器
##      也被 main 的 `_after_world_ready` 用（经 `_avg_physics_ms` 测对手基线）。
##      采样口径属 main ⇒ 搬走会让 setup 路径反过来 main→模块（正是
##      opponent_spawner 实证过的"多一层协程 = physics_frame 恢复时机差 1 物理帧"
##      那个陷阱）。注入 Callable 后协程层次与迁移前**完全一致**：
##        `_check_tick`(main) → `run_opponents`(模块) → `_sample_physics_ms`(main)
##        == 迁移前的 `_check_tick` → `_check_opponents` → `_sample_physics_ms`。
##      Callable 只是调用方式，不新增协程层。
##
##   ④ **await 数 = 8，一拍不加**：6 处帧循环的 physics_frame（见②）+ 2 处
##      `await _sample_physics_ms.call(...)`（见③）。main.gd 分发口那 5 个
##      `await _checks_ai.run_*()` 留在 main 自己那层协程 —— 协程深度与迁移前一致
##      （opponent_spawner 实证：多一层协程 = 25856 行日志发散）。由
##      split-checks-ai-structcheck.ps1 把「8」与两种形态钉死。
##
## ⚠ 为什么 `_opponents` / `_ai_started` 做成**只读 getter 代理**（真身在
##   `_opponent_spawner`）：迁出的 5 个族里它们共 20+ 个读点；保留同名代理
##   可以让派生的函数体**逐字节零 diff**，也不可能出现"两边各存一份数组"的漂移
##   （与 main.gd 的同名代理同一约定，见 opponent_spawner.gd 文件头决策 ①）。
##
## ⚠ 为什么 `_opponent_spawner` / `_autopilot` 注入的是 **main 持有的实例本身**
##   而不是 preload 第二份：对手数组 / armed 状态在 spawner 实例上、drive_recover
##   的状态在 autopilot 实例上；第二份会拿到空状态，A/B 与取证全部失真
##   （screenshot_mode 注入 _autopilot/_engine_audio 实例同款约定）。
##
## ⚠ GameState.current_level() / Engine / Input / Time / Performance 直接读全局
##   单例（layout / bench 同款先例）：它们不是场景节点，直连不违反"禁反向持有场景"；
##   且迁移前本族就在 main.gd 里直连，注入只会多一层间接、零行为收益。
##
## ⚠ 为什么没有 class_name（与九个先例模块同一约定）：验收闸门在**无编辑器**环境
##   跑 Godot，全局类缓存（.godot/global_script_class_cache.cfg）只有编辑器会重建；
##   2026-10-12 实测新增 class_name 后 `--check-only` 与游戏运行双双报
##   `Identifier not declared`。消费方一律
##   `const ChecksAi := preload("res://scripts/checks/ai.gd")`。

# ---------------------------------------------------------------- 外部注入
## 玩家车（main.gd 的 _car = $RaceCar）。字段名沿用 main 的成员名 → 族内代码零 diff。
var _car: VehicleBody3D = null
## 赛道（迁移前是 _check_* 里 get_node_or_null("Track") 的静态兄弟节点）。由 setup() 注入。
var _track: Node = null
## 障碍物场（main.gd 的 _obstacle_field；无障碍关卡为 null）。由 setup() 注入。
var _obstacle_field: Node3D = null
## 对手生成模块**实例本身**（main.gd 的 _opponent_spawner）：_opponents / ai_started
## 的真身都在它身上（SPLIT-OPPONENT-001）。字段名沿用 main 的成员名 → 族内代码零 diff。
var _opponent_spawner = null
## 验收自动驾驶模块**实例本身**（main.gd 的 _autopilot）：drive_recover 的恢复状态
## 在它身上，不能 preload 第二份。字段名沿用 main 的成员名 → 族内代码零 diff。
var _autopilot = null
## 本关物理世界（main.gd 的 get_world_3d()）：run_obstacles 的射线探针要
## direct_space_state。注入 World3D 而不是趁手的节点 —— 模块仍不认识场景树，
## 且 `.direct_space_state` 仍在**原来的那一行**取（不预取快照，时序零变化）。
var _world_3d: World3D = null
## physics_frame 信号提供者（main.gd 的 _shot_physics_frame）。由 setup() 注入；
## 模块里 `await _physics_frame.call()` 取代 `await get_tree().physics_frame`，
## 是同一个 Signal，协程恢复时机不变（文件头决策 ②④）。
var _physics_frame: Callable = Callable()
## checks 族共用物理采样器（main.gd 的 _sample_physics_ms）。由 setup() 注入；
## 模块里 `await _sample_physics_ms.call(frames, settle)` 取代直接调用 ——
## 协程层次不变，SIG 口径唯一（文件头决策 ③④）。
var _sample_physics_ms: Callable = Callable()

# ---------------------------------------------------------------- 只读代理（真身在 _opponent_spawner）
## 本关的 AI 对手（ai_opponents 台）。空数组 = 本关没有对手。
## ⚠ 只读代理：真身在 _opponent_spawner.opponents（SPLIT-OPPONENT-001）。保留同名
## 可以让派生的族内代码零 diff，也杜绝"两边各存一份数组"的漂移；写入只在模块里。
var _opponents: Array:
	get:
		return _opponent_spawner.opponents
## 对手是否已经随玩家起跑（只读代理，真身在 _opponent_spawner）。
var _ai_started: bool:
	get:
		return _opponent_spawner.ai_started
## 位姿/恢复纯函数（static func pose_facing 等无状态可直调，§2.4 约定）。
const Autopilot := preload("res://scripts/autopilot.gd")


## 注入外部引用（main.gd 在 _after_world_ready 里障碍物与自动驾驶都接好之后调用一次）。
##
## ⚠ 为什么必须在 `_build_obstacles` **之后**：run_obstacles 与 AI 摆车道都要
## 查询障碍场，早注入只会拿到 null。
func setup(car: VehicleBody3D, track: Node, obstacle_field: Node3D,
		opponent_spawner, autopilot, world_3d: World3D,
		physics_frame: Callable, sample_physics_ms: Callable) -> void:
	_car = car
	_track = track
	_obstacle_field = obstacle_field
	_opponent_spawner = opponent_spawner
	_autopilot = autopilot
	_world_3d = world_3d
	_physics_frame = physics_frame
	_sample_physics_ms = sample_physics_ms

'''

body = []
body.append("# ======================== AI 判据常量（迁自 main.gd 顶部常量区）========================")
body.append(CONSTS_T)
body.append("")
body.append("")
body.append(OPP_T)
body.append("")
body.append("")
body.append(DIAG_T)
body.append("")
body.append("")
body.append(TRIO_T)

module = HEADER + "\n".join(body) + "\n"
module = module.replace("\r\n", "\n")

if "--write" in sys.argv:
    if not os.path.isdir(os.path.dirname(OUT)):
        os.makedirs(os.path.dirname(OUT))
    with io.open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(module)
    print("\n已写出 %s（%d 行）" % (OUT, module.count("\n")))
else:
    print("\n（干跑，未写盘；加 --write 落地）  预计模块 %d 行" % module.count("\n"))
