# ENG-2026-10-19-01 · 完整修复计划（v1.0 · 2026-10-19 · 工程负责人 程基岩）

> **状态：D1–D4 已由用户拍板（2026-10-19 17:08）；执行用 diff 清单已另出 `round4-implementation-diff-20261019.md`，待用户确认后实施。**
> 本任务为只读+出计划：未写任何代码文件、未做任何 git 写操作（仅 `git rev-parse/status/log` 只读核验）、未启动任何验收。计划中所有「已实现」结论均经实读代码复核并附 `文件:行`。
> 基线复核：HEAD = `0cb669d`；工作区仅 2 个 `.import` 被编辑器重导入改动（`godot-racer/assets/audio/rain_loop.ogg.import`、`godot-racer/models/race_car.glb.import`），无代码改动。
> 汇编：主理人 游承峰（一致性核对通过；行数以实读为准：main.gd 886 行，AGENTS.md 中 784 行为 2026-10-18 旧值）。

---

## 0. 结论速览

| 用户诉求 | 结论 | 依据 |
|---|---|---|
| ① 3 秒倒计时 + 同步发车 + 统一计时 | 倒计时与同步发车**已实现**（保留）；「起步时间」是**真缺口**，正解 = 统一计时原点（修订 R6，需用户拍板） | §1.1 / §2.1 |
| ② AI 进游戏即在赛道 + 同时发车 | **已实现**；真缺口 = 无机器断言守「倒计时期间 AI 在场未发车」（补断言） | §1.2 / §2.6 |
| ③ 起点龙门架 | 资源**已确认在库**（`models/environment/desert_ruin_gate.glb`）；插入属**绿地新建**（可选脚本 `scenery_spawner.gd` 未入库） | §1.3 / §4 |

需用户拍板 4 项（§6-D）：**R6 规则修订**、冻结带重冻结机时、龙门架模型与摆放口径确认、AC-13 双帧率排期。

---

## 1. 问题分析（逐条带证据）

### 1.1 「起步时间」——真缺口（用户诉求核心）

**现状行为（截图实证：总时间 00:09.423 在走、本圈 --:--.---、「起步 --:--.---"）**
- HUD「起步」行 = `race_total_time() − current_lap_time()`，在本圈第一次走动的那一帧取一次差值后冻结；本圈未走动时显示占位 `--:--.---`（`scripts/hud.gd:59-62` 变量、`:235-261` `_build_launch_label()`、`:347-353` `_process` 取值块、`:99` 挂载调用）。该行由 commit `d1fee26 fix(hud): 补「起步」分段行` 应用户早前反馈新增。
- **根因 = 双计时口径**：总时间从 GO 起算（R15，`scripts/game_state.gd:158` `start_race()` 盖 `race_start_ms`、`:166-169` `race_total_time()`），本圈从**第一次压线**起算（R6，`scripts/vehicle.gd:508-515` `_on_lap_crossed()` 首次压线重置 `_lap_start_ms`）。出生点在白线后方（`scripts/vehicle.gd:276-277`：`back = 线厚半 + 车半长 + 0.08`；主理人实测 2.77m，公式已核未独立复算数值），GO→首次压线那段即「起步」段。
- 用户要求「彻底移除」。**正解 = 统一计时原点**：圈钟也从 GO 起算，首圈含起跑爬行。统一后 `总时间 ≡ 各圈之和`（末圈完赛与 `race_finished` 同帧发出，`vehicle.gd:525-527`），「起步」恒为 0，该行失去存在理由可删。
- ⚠ 这**修订已批准规则 R6**（策划案 §5.3 明言圈速口径「有意分离」、R15 明言「与 R6 有意分离」）→ 列为需用户拍板决策点（§6-D1），并给出保守备选。

**跨模块陷阱（计划必须含，已实读确认）**
- `scripts/race_position.gd:124-126`：玩家进度公式 `crossings = laps_done + (current_lap_time() > 0 ? 1 : 0)`。原点统一后 GO 即 `>0` → 玩家进度瞬间多出整整一圈 → 名次错乱。
- **该陷阱有现存测试把守**：`tests/race_position_scene_test.gd:63` 断言「名次 2 / 2」——若只改 vehicle.gd 不改 race_position.gd，玩家进度会翻倍到 ≈2×赛道长并反超 AI，此断言当场翻红。即「半成品状态」会被机器抓到，但 vehicle.gd 与 race_position.gd **必须同一提交**（§5 提交边界）。

### 1.2 AI 出现时机——已实现，缺回归断言

**已实现（复核通过）**
- AI 在**装配期**生成：`scenes/main.gd:316-322` `_opponent_spawner.spawn_opponents(...)`，早于 `:345` `GameState.enter_countdown()` → 倒计时期间 AI 已在场。
- 摆位与玩家并排齐头、同在白线后方：`scripts/ai_opponent.gd:317-339` `_place_beside(player)`（横向偏移夹在路面内，`:326-329`）。
- `armed=false` 时 `_physics_process` 早退不给油（`scripts/ai_opponent.gd:417-420`）+ 倒计时树暂停双重冻结。
- GO 同步发车唯一入口：`scenes/main.gd:369-375` `_on_race_go()`（三步同帧：玩家解锁 + `arm_opponents()` + `GameState.start_race()`）；`scripts/opponent_spawner.gd:213-219` `arm_opponents()` 幂等；旧「玩家速度 ≥4km/h 才发车」规则已退役（留档于 `opponent_spawner.gd:6-12`、`main.gd:326-334`、`:857-860`）。
- 五关 `data/levels/level_1..5.tres` 全部 `ai_opponents = 1`（实读确认）；路宽 14/16/12/10/8 m。
- 相位机与倒计时模块：`scripts/game_state.gd:27`（含 LOADING/COUNTDOWN）、`:140-146` `enter_countdown()`、`:154-160` `start_race()`（**刻意不 release 输入**——E6，注释 `:151-153`）；`scripts/start_countdown.gd:25` `COUNTDOWN_SECONDS := 3.0`、`:21` `finished` 信号、`:36` `PROCESS_MODE_ALWAYS`。
- 互动路径装配顺序：`scenes/main.gd:200-214`（`prepare_race()` + `start_locked=true`，LOADING 不暂停树防装配死锁）→ `:229-347` `_after_world_ready()`（赛道就绪 → 障碍 → 各模块接线 → 生成 AI → 互动分支挂 race_position、连 AI/玩家完赛信号 → `enter_countdown()` → `_mount_countdown()`）。

**真缺口**：`tests/countdown_scene_test.gd` 现有 19 条断言（AC-01~05/10/11/16）只在 **GO 之后**查 AI 数量/armed；**没有任何断言守住「倒计时期间 AI 已在场且未发车」**（实读全篇确认）。若有人改回「加载即 arm」，现有测试抓不到（倒计时期间树暂停，AI 速度照样是 0，只有 `armed` 标志能区分）。

### 1.3 龙门架——资源已确认，插入是绿地

**资源（实读确认）**
- `godot-racer/models/environment/desert_ruin_gate.glb`（39,052 字节）+ `.import` 侧车已入库（HEAD `0cb669d`「入库环境资产包 models/environment」）+ 6 张内嵌纹理 PNG。
- 同目录安装指南 `godot_racer_assets_install_guide.md:25` 登记：216 三角形、包围盒 **4.80 × 4.44 × 1.36 m**（未独立解析 glb 复核，以安装指南登记值为准，实施时以 Godot 导入后的 AABB 实测校准）。
- `:32` **纯网格无碰撞体**（车会穿过）→ 门下通车不撞，但立柱必须摆出路肩；`:35` Y-up、米制、模型底部约 y=0；`:38` 建议放第 18 渲染层（与 Ground 一致，小地图相机不绘制）。
- 资产包可选脚本 `scripts/scenery_spawner.gd` **未入库**（实读确认不存在）→ 插入属绿地新建。

**插入依据（实读确认）**
- `scripts/track_generator.gd:528-552` `_build_start_line()` 暴露 `start_line_center`（含高程的三维曲线采样点）、`start_line_forward`、`start_line_depth`（@export 默认 1.6）；白线网格在 `pos.y + road_lift + 0.01`（`:544`，`road_lift` @export 默认 0.02，`:19`）。
- 跨径 4.80m < 路宽（8~16m）→ 须按路宽缩放（§4.3 公式）。
- 发车点位于白线后方（`vehicle.gd:276-279`）→ 龙门架跨线而立、车从门下出发，符合「起点龙门架」直觉。

### 1.4 附证：仓库当前比任务简报更新（不影响本计划，但解释了现场）

Phase 02/03 已落地（commit `f773cf7` 等）：`scripts/race_position.gd`（名次排序 + HUD RankLabel + AI 完赛提示 + P1-C 完赛摘车辆碰撞 `:88-90`）、`scenes/main.gd:339-344/:378-416`（完赛记账、扩展快照 `position/field_size/outcome/entrants`）、HUD 总时间行（`hud.gd:220-232`）。「起步」行是叠在其上的更新一层。本计划不动这些既有成果。

**另发现两处既存文档漂移**（早于本任务，建议顺手修，§2.7）：`README.md:25` 与 `godot-racer/docs/portfolio-design.md:26` 仍写「AI 在玩家起步（4 km/h）后才出发」——该规则 2026-10-18 已退役。另 `godot-racer/docs/testing.md:143` 的 `aistart` 行（「玩家起步后 0.19 s 同步发动」）同为旧规则表述，实施 D 步骤时一并校正（主理人汇编时补充）。

### 1.5 用户质询四因素核对（2026-10-19 17:00 追加）

用户提出四点担心，逐条核对结论：**前三点的防护机制现行代码已成立（附证据），第四点（验收影响）本计划已覆盖，此处补全 20 项影响矩阵与 aistart 逐条断言核对**。

**① 状态机：COUNTDOWN 状态已存在，且输入/AI 双重锁死**
- 相位机含 COUNTDOWN：`scripts/game_state.gd:27` `enum Phase { MENU, LOADING, COUNTDOWN, RACING, PAUSED, FINISHED, EXIT_CONFIRM }`（2026-10-18 Phase 01 新增，早于本任务）。
- 倒计时期间**树暂停**：`game_state.gd:140-146` `enter_countdown()` → `get_tree().paused = true` → 玩家与 AI 的物理帧全部停发（同步发车的物理前提，策划案 R1/R5）。
- 玩家输入锁：`vehicle.gd` 的 `start_locked` 标志，互动路径装配期即置真，`_update_drive()`/`_update_steering()` 在锁定时忽略驾驶动作（Phase 01 TASK-005；由 `countdown_scene_test.gd` AC-01 断言）。
- AI 控制器锁：`ai_opponent.gd:417-420` `if track == null or not armed:` → 未发车不给油、不给方向（只留防溜车刹车）。**树暂停 + armed=false 是双重独立冻结**——即使将来有人误删树暂停，armed 仍兜底。
- 倒计时 UI `PROCESS_MODE_ALWAYS`（`start_countdown.gd:36`）暂停中照走；ESC → EXIT_CONFIRM 冻结倒计时（`game_state.gd:239-248`，取消回 COUNTDOWN 且保持暂停，R3/E7）。
- GO 不吞键（E6）：`start_race()` 刻意不 `release_drive_input()`（`game_state.gd:151-153`），倒计时里按住 W 到「出发！」直接给油。
- **结论：「倒计时没结束车就窜出去」在当前代码有双重机制阻止且均有测试把守；本计划不改这套机制。**

**② AI 生成时机：已不在「触发点」，但也不该照建议挪进 `_ready()`**
- 旧「触发点」规则（轮询玩家速度 ≥4 km/h 才发车，`maybe_start_opponents`）**2026-10-18 已删除**（`opponent_spawner.gd:6-12` 留档；`main.gd:326-334/:857-860` 注释留档）。
- 现生成时机 = 装配期 `_after_world_ready()`：`main.gd:316-322` `spawn_opponents(...)`，早于 `:345` `enter_countdown()` → **倒计时数字「3」出现时 AI 已在起跑格**（策划案 E8 明言此意图）。
- 为什么不能挪进 `_ready()`：AI 摆位依赖两样 `_ready()` 时还不存在的东西——① 赛道几何（Track 异步构建，装配要 `await track.await_world_ready`）；② 玩家实际出生位姿（`ai_opponent.gd:317-339` `_place_beside(player)` 直接读玩家位姿横向错开，刻意不复制第二份白线偏移计算）。早于这两者生成只会得到摆不下的 AI 或空引用。
- 用户要的效果（「一进场就存在」）已由现设计满足：进场 → 装配（含 AI 上格）→ 倒计时 → GO。真缺口只是没有机器断言守「倒计时期间 AI 在场且未发车」，由 §2.6-A ④-C 补上。

**③ 验收影响：20 项清单逐项核对（不新增/不减少任何项）**
`current_lap_time()` 全仓消费方实读只有 3 处：`hud.gd:331/:350`（显示）、`race_position.gd:125`（进度公式）、测试 stub——**没有任何 check 脚本读它**；圈速证据来自 `lap_completed` 信号与日志（`vehicle.gd:524`）。

| 验收项（runner 20 项） | 暴露面 | 结论 |
|---|---|---|
| lap / stress | 圈速计时；**不调 `_on_race_go`**（`checks/lap.gd:345/:357` 仅注释） | 首发压线分支原样保留 → 证据零变化 |
| aistart / aidiag | 经注入 Callable 调 `_on_race_go`（`checks/ai.gd:845`、`:384` 附近） | 新步骤被 `start_race()` 返回值门控（见 ④）→ 路径逐字节不变 |
| opponents×2 / avoid / phys | 直接 `arm_opponents()`，不走 GO（`checks/ai.gd:283`、`ai_field.gd:119`、`env_phys.gd:295`） | 不暴露 |
| minimap | 新龙门架节点渲染层（第 18 层）不进小地图相机（第 17 层，§4.4） | 不暴露（复跑留证） |
| 其余 11 项（docs / readme / enclosure / wallslide / obstacles / pause / flip / layout / reverse / weather / friction） | 不涉及计时原点 | 不暴露（复跑留证） |
| tests/ 场景测试 | countdown_scene_test（扩充）、race_position_test（stub+新断言）、race_position_scene_test（陷阱把守，必须保持绿）、finish_results_test（总时间行） | 先红后绿（§2.6/§5） |
| 冻结输入带（aidiag 底座） | `vehicle.gd`/`main.gd` 在 `initial_state_contract` 源码哈希绑定内（`main.gd:650-652`） | **必须重新校准+冻结**（§5-8/D2），阈值一个不改 |

**runner 项数不变（Quick 15 / 全量 20），不新增验收项，不放宽任何判据。**

**④ aistart 专项：逐条断言核对，确认不命中**
`run_ai_start()`（`checks/ai.gd:813-890`，判据串「并排发车验收 ✔」）断言全集：① 出发前对手 `armed=false` 且车速 ≤1 km/h（`:830`）；② 两车中心距（仅打印）；③ 触发 `_race_go.call()`（`:845`）；④ 同帧全部 `armed=true` + 玩家 `start_locked=false`（`:847-866`）；⑤ 玩家零输入时对手 8 秒内自达 15 km/h、末速 ≥10 km/h（`:867-890`）。**没有任何一条读圈速/`current_lap_time`/`start_line_crossed`/玩家圈状态**——新改动的第四步（锚定圈钟）对这些断言零输入。
进一步，本计划把第四步**门控在互动路径**：`_on_race_go` 改为 `if GameState.start_race(): _car.begin_lap_timing(...)`——`start_race()` 仅在 COUNTDOWN→RACING 时返回真；aistart/aidiag 跑自动化路径（相位在 `begin_race()` 时已是 RACING，`game_state.gd:113-120`）→ 返回假 → 圈钟保持「首次压线」旧口径。**验收路径因此逐字节不变，aistart 只在「同一个发车入口多走一次无害调用」的意义上被触及**；复跑 `--check=aistart -Level 3 -RenderFps 60` 留证（§5-7）。

---

## 2. 具体修改方案

### 2.1 vehicle.gd：统一计时原点最小改法（约 +30 行；该文件 1413 行属登记在册超限，修复性提交不阻塞，AGENTS §1-8）

1) 计圈状态区（`:95-103` 旁）新增公开标志：
```gdscript
var start_line_crossed := false   # 已压过起点线。GO 锚定圈钟后，首发压线只标记；
                                  # race_position.gd 进度公式读它 —— 勿改语义（见该文件 L124）。
```
2) `current_lap_time()`（`:555-558`）旁新增 GO 锚定方法：
```gdscript
## 由 main 的唯一发车回调 _on_race_go() 调用：圈钟与总时间同一时刻起算
##（R6 修订：本圈也从「出发！」起算，首圈含起跑爬行 → 总时间 ≡ 各圈之和）。
## go_ms 传 GameState.race_start_ms（<=0 时自盖时间戳，仅为自动化路径兜底）。
## 幂等：_lap_running 已为真则直接返回（重复 GO 不重新起表）。
func begin_lap_timing(go_ms := -1) -> void:
	if _lap_running:
		return
	_lap_running = true
	_lap_start_ms = (go_ms / 1000.0) if go_ms > 0 else (Time.get_ticks_msec() / 1000.0)
	print("[计圈] 圈钟已由「出发！」锚定（首圈含起跑段，与总时间同原点）")
```
3) `_on_lap_crossed()`（`:508-527`）首发压线分支改写：
```gdscript
func _on_lap_crossed() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if not _lap_running:
		# 自动化路径（--check / --shot，无 GO 事件）：首发压线即起表 —— 旧口径原样保留，
		# 既有圈速证据（--check=lap/stress 全部日志）零变化。
		_lap_running = true
		_lap_start_ms = now
		start_line_crossed = true
		print("[计圈] 开始计时（第一次压线）pos=%s 速度=%.1f km/h" % [...])   # 原文案保留
		return
	if not start_line_crossed:
		# 互动路径：圈钟已由「出发！」锚定 → 首发压线只标记，不完圈、不重新起表
		start_line_crossed = true
		print("[计圈] 首发压线已标记（圈速自「出发！」起算，含起跑段）pos=%s 速度=%.1f km/h" % [...])
		return
	var lap := now - _lap_start_ms
	# ……以下原样不动：lap_last / laps_done+=1 / lap_best / _lap_start_ms=now /
	#     print / lap_completed.emit / race_finished.emit
```
4) 重置点补 flag：`_reset_lap_state()`（`:149-166`）与 `_release_lap_suppression()`（`:169-177`）各加 `start_line_crossed = false`（防御性；重开实际走整场景重载）。

**设计要点**
- 自动化路径行为**逐字节不变**（首发压线分支的赋值与打印与现状一致）→ `--check=lap/stress/opponents` 的圈速证据不受影响；实读确认 `scripts/checks/lap.gd` 既不调 `_on_race_go` 也不调 `arm_opponents`（`:345/:357` 仅注释），`scripts/checks/ai.gd:283` 的 opponents 族直接 `arm_opponents()`，均不走 GO。
- 不改任何控制律常量、不改 `_check_start_line_crossing` 几何判定、不改复位/隔离逻辑（E13/R12 不罚时不赠圈保持）。
- 语义变化（需用户知悉）：互动路径 GO 后「本圈」立即从 0 起走（含站立不动的时间）；倒计时/LOADING 期间树暂停或 `_lap_running=false`，HUD 仍显示 `--:--.---`（E8 口径不变）。

### 2.2 race_position.gd：进度公式联动（±8 行；陷阱修复，必须与 2.1 同提交）

`scripts/race_position.gd:124-126` →
```gdscript
var crossings := int(_player.get("laps_done"))
# 2026-10-19：GO 锚定圈钟后 current_lap_time() 从出发起就 >0，不能再当压线判据
#（否则玩家进度瞬间多出整整一圈、名次错乱）—— 改读 vehicle 的压线标志。
if bool(_player.get("start_line_crossed")):
	crossings += 1
```
`get()` 缺失时返回 null → `bool(null)` = false，安全降级；AI 侧公式（`ai_opponent.gd:917`）不动。

### 2.3 main.gd：`_on_race_go` 单一入口扩展（约 +2 行；现 886 行 → ~890）

```gdscript
func _on_race_go() -> void:
	_car.start_locked = false
	# ③ 先盖总时间原点（R15）。start_race() 仅在 COUNTDOWN→RACING 时返回真：
	#    互动路径返回真 → 接着锚定圈钟；自动化路径（aistart/aidiag，相位在 begin_race()
	#    时已是 RACING）返回假 → 圈钟保持「首次压线」旧口径，验收路径逐字节不变。
	if GameState.start_race():
		_car.begin_lap_timing(GameState.race_start_ms)    # 圈钟与总时间同一时刻（R6 修订，本次新增）
	_opponent_spawner.arm_opponents()
	_check_evidence.event("GO", ...)                  # 原样
	print(...)                                        # 原样
```
顺序理由：① `begin_lap_timing` 读 `start_race()` 刚盖的 `race_start_ms`，两个时钟**同一时刻**（而非两次 `Time.get_ticks_msec()` 相差 ≤1ms）；② 门控 `start_race()` 返回值 = 只有走过倒计时的互动路径才锚定新圈钟，aistart/aidiag/opponents/phys 全部不走 COUNTDOWN，圈钟语义零变化（§1.5-③④）；③ 四步仍在同一回调内 → 下一个物理帧同时生效，「同步」定义（策划案 §5.2）保持可断言。E6 保持：新步骤不碰输入状态。

### 2.4 hud.gd：删「起步」行（约 −45 行；现 491 行）+ chase_camera.gd 注释同步

删除：`:59-62`（`_launch_split` 变量及注释块）、`:99`（`_ready()` 里的 `_build_launch_label()` 调用）、`:235-261`（`_build_launch_label()` 函数整体）、`:347-353`（`_process` 取值块）。总时间行（`:220-232`）与圈速行不动。
`scripts/chase_camera.gd:212-214`：更新 HUD 左列清单注释（去掉「起步 358」，列底变为总时间 318~352）；**提示条位置 398 不动**（不叠字，最小改动）。

### 2.5 AI 侧结论：**零改动**（附证据，回应「评估要求」）

- AI 圈数计「压线次数」：`scripts/ai_opponent.gd:905-914`（首发压线 = 发车不计圈），进度 `_progress = crossings × 赛道长 + 弧长`（`:917`）——与玩家计时原点无任何耦合。
- AI 圈速**无任何展示**：`lap_completed(laps_done)` 信号（`:28/:912`）**无消费方**（实读全仓：HUD 只连玩家车的同名信号，`hud.gd:101-102`，且签名不同）；结算页对手行只含圈数与完赛状态（`tests/finish_results_test.gd:156-162` 断言口径）。
- 完赛顺序只取决于压线帧（`race_position.gd:175-182` `_precedes` 用 `finish_frame`）——墙钟只用于成绩展示（`record_finish` 里 `GameState.race_total_time()`，`race_position.gd:86`），不改排序。
- **结论：AI 计数不改、零可见影响；不为对称扩大爆炸半径。**（反证条件：若将来要给 AI 加圈速展示，才需单独立项——本计划不含。）

### 2.6 测试改动（TDD：先红后绿）

**A. `tests/countdown_scene_test.gd`（+约 60 行，插在 ④-B 之后、⑤ 之前）**
- ④-C 回归守护（对「改回加载即 arm」必红）：倒计时期间 `_opponents.size() >= 1`；`ai.armed == false`；AI 与玩家距离 < 6.0m（并排在起跑区）；双方车速 < 5 km/h（弱健全性，树暂停已由 `paused` 断言覆盖）。
- ⑤ 之后新增「统一原点」断言：
  - GO 后 `car.current_lap_time() > 0` 且 `car.get("laps_done") == 0` 且 `car.get("start_line_crossed") == false`（**对 HEAD 必红**：现状 GO 不锚定，本圈计时为 0）；
  - 陷阱守护：`_race_position.player_progress() < track.road_length()`（未压线时进度 = 出生弧长 ≈ 赛道长−2.77；**若只改 vehicle 不改 race_position，此条必红**——实测把守者其实是 `race_position_scene_test.gd:63`，这里双保险）；
  - 保持 W 按住轮询首发压线：`start_line_crossed` 翻真后，断言 `laps_done == 0`（首发不完圈）、圈钟**未重置**（翻转前后两采样 `t_after > t_before` 且 `t_after − t_before < 1.0s`）、HUD 本圈标签非占位（**对 HEAD 必红**：无此标志，轮询超时）。

**B. `tests/race_position_test.gd`（±15 行）**
- `PlayerStub`（`:16-21`）加 `var start_line_crossed := false`；`:82` 的 `p2.lap_running = true`（模拟首发压线）改为 `p2.start_line_crossed = true` —— 仅是 stub 契约更新，**断言集一条不减**（`:79-103` 四条边界断言原样）。
- 新增一条（**对 HEAD 必红**）：圈钟在跑但未压线（`lap_running=true, start_line_crossed=false`）→ `player_progress()` 恰等于弧长、不含 +1 圈 —— 旧公式下翻红。

**C. 不改**：`finish_results_test.gd`、`race_position_scene_test.gd`、`release_flow_scene_test.gd`、`release_settings_test.gd`（实读确认无一条依赖被删的「起步」行或被改的进度语义；`release_flow_scene_test.gd:60-69` 按脚本过滤计数 finish_menu，不受新节点影响）。

### 2.7 文档同步（提交 D；文本闸门误伤规避见 §5-12）

- `plan/racing-system-design-20261018.md`：加 v1.2 修订记录；R6 行改为「圈速亦从『出发！』起算（首圈含起跑段）」；R15 行删「与 R6 有意分离」改为「同原点」；AC-05 行同步。（plan/ 不在闸门扫描范围。）
- `godot-racer/docs/portfolio-design.md:11`（两个口径刻意分开 → 统一原点、总时间 ≡ 各圈之和、「起步」行移除）、`:26`（4 km/h 旧规则 → 倒计时同步发车，**既存漂移顺手修**）。
- `README.md:25`（「AI 赛车在玩家起步后才出发」→「3 秒倒计时结束后同时出发」；**既存漂移顺手修**）。
- `godot-racer/docs/testing.md`：新增本轮小节（先红后绿证据 + commit 绑定，照 AGENTS §15 模板）；**顺带校正 `:143` 的 `aistart` 旧规则表述**（主理人汇编时补充）。
- **误伤规避**：全文不新写「全部 N 项」措辞（check-docs 正则 `全部\s*(\d+)\s*项` 会核对 20/15，一个数字都不新引入）；不删任何文件故无「已删路径反引号」风险（check-readme 路径正则只查存在的路径）；新文档若提 `scripts/start_gantry.gd` / `models/environment/desert_ruin_gate.glb` 反引号路径，实施后二者真实存在。
- 不改 `godot-racer/AGENTS.md`（§16 高影响；无必要——模块约定已通用成文）。

---

## 3. 涉及模块清单

| 文件 | 函数/位置 | 改动性质 | 行数量级 |
|---|---|---|---|
| `godot-racer/scripts/vehicle.gd` | `start_line_crossed`（新，`:95-103` 区）；`begin_lap_timing()`（新，`:555` 区）；`_on_lap_crossed()`（改，`:508-527`）；`_reset_lap_state()`/`_release_lap_suppression()`（各 +1 行重置） | 行为修改（互动路径圈钟原点） | +30（1413→~1443，登记在册超限不阻塞） |
| `godot-racer/scripts/race_position.gd` | `_raw_player_progress()`（改，`:124-126`） | 契约联动（陷阱修复） | ±8（191→~199） |
| `godot-racer/scenes/main.gd` | `_on_race_go()`（+4 行门控块，`:369-375`）；`_after_world_ready()`（+4 行挂龙门架，`:322` 后）；文件头 preload/var（+4 行） | 编排（单一入口扩展 + 新模块接线） | +12（886→~898，≤1000 ✓） |
| `godot-racer/scripts/hud.gd` | 删 `_launch_split`/`_build_launch_label()`/`_ready` 调用/`_process` 块（`:59-62/:99/:235-261/:347-353`） | 删除（UI 行移除） | −45（491→~446） |
| `godot-racer/scripts/chase_camera.gd` | `:212-214` 注释 | 注释同步 | ±2 |
| `godot-racer/scripts/start_gantry.gd`（**新增**）+ `start_gantry.gd.uid`（**手写**） | 见 §4 | 绿地新建（纯视觉模块） | ~130（≤1000 ✓） |
| `godot-racer/scripts/game_state.gd` | **不改**（`race_start_ms`/`start_race()` 已就位） | — | 0 |
| `godot-racer/tests/countdown_scene_test.gd` | ④-C + 统一原点断言 | 测试扩充（先红） | +60 |
| `godot-racer/tests/race_position_test.gd` | PlayerStub + 新断言 | 测试契约更新（先红） | ±15 |
| 文档 4 份 | 见 §2.7 | 同步 | — |

新模块遵守仓库约定（AGENTS §2.4）：无 `class_name`（消费方 `const StartGantry := preload("res://scripts/start_gantry.gd")`）；`setup()` 一次性注入 track；不 `get_node`、不持有 main；模块内 `await` 数 = 0；headless 不生成 `.uid` → **手写**（照 `start_countdown.gd.uid` 先例，拟 `uid://startgantry01`）。

---

## 4. 龙门架资源插入方案

### 4.1 新模块 `scripts/start_gantry.gd`（Node3D，~130 行）

```
extends Node3D
## 起点龙门架（2026-10-19 用户反馈）。纯视觉：desert_ruin_gate.glb 无碰撞体，
## 车从门下穿过不撞；立柱按路宽缩放放到路面之外（路肩带），不占路。
## 约定：无 class_name / setup() 注入 track / 不 get_node / 无 await。
const GATE_SCENE := "res://models/environment/desert_ruin_gate.glb"
const GATE_SPAN_X := 4.80          # 安装指南登记包围盒 X（米）= 原始跨径
const GATE_SHOULDER_M := 0.6       # 立柱落点 = 路宽/2 + 0.6（护栏在路宽/2 + 1.2）
const GATE_RENDER_LAYER := 1 << 17 # 第 18 层（与 Ground 一致；小地图相机只画第 17 层 → 不绘制）
var _track: Node3D = null
func setup(track: Node3D) -> void: _track = track
func _ready() -> void: _build()     # setup 未注入/track 为空/资源加载失败 → push_warning 后静默跳过（不得炸验收）
func _build() -> void:
	var lc = _track.get("start_line_center"); var lf = _track.get("start_line_forward")
	if not (lc is Vector3) or not (lf is Vector3): push_warning(...); return
	var fwd := (lf as Vector3); fwd.y = 0.0; if fwd.length() < 0.01: return; fwd = fwd.normalized()
	var side := Vector3(fwd.z, 0.0, -fwd.x)              # 与 _place_beside/_build_start_line 同向约定
	var road_w := float(_track.get("road_width"))         # @export，已由 level_config.apply_to_track 落入
	var lift := float(_track.get("road_lift"))            # @export 0.02；缺失按 0.0
	var span := road_w + 2.0 * GATE_SHOULDER_M            # 目标跨径（立柱中心距）
	var sx := span / GATE_SPAN_X                          # X 向缩放；Y/Z 不缩（高 4.44m 净空充足、深 1.36m 跨线）
	var packed: PackedScene = load(GATE_SCENE); if packed == null: push_warning(...); return
	var gate: Node3D = packed.instantiate()
	gate.name = "StartGantry"
	gate.transform = Transform3D(Basis(side * sx, Vector3.UP, fwd), (lc as Vector3) + Vector3.UP * lift)
	for m in gate.find_children("*", "MeshInstance3D", true, false): m.layers = GATE_RENDER_LAYER
	add_child(gate)
	print("[龙门架] 起点龙门架已就位：路宽 %.1f → 跨径 %.2f（缩放 ×%.2f），基座高程 %.2f" % [...])
```

### 4.2 main.gd 接线时序（`_after_world_ready()` 内）

位置：AI 生成块（`:316-322`）之后、`_parse_check_args()`（`:323`）**之前**——赛道已就绪（函数头部 `await track.await_world_ready`）、`start_line_*`/`road_width`/`road_lift` 均已由 `build_world()` 落定；倒计时挂载（`:345-346`）之前。**互动与自动化路径都挂**（纯视觉、零碰撞、零代码读它）：`--shot` 截图因此能验龙门架；headless 验收只多一个网格实例，无物理/行为影响（风险与缓解见 §6-R5）。

```gdscript
_start_gantry.setup(track)
add_child(_start_gantry)
```

### 4.3 缩放 / Transform / 高程公式

- 跨径目标 `span = road_width + 2 × 0.6` → 立柱中心落在 **路面之外、护栏内侧**的路肩带（护栏在 `road_width/2 + 1.2`，`track_generator.gd:27/:369`）。L1：±7.6m；L5（最窄 8m）：±4.6m——车通过时不穿立柱。
- `scale_x = span / 4.80`（L1 ×3.17、L5 ×2.42）。⚠ 代价：立柱随 X 拉伸变粗（程序化资产，视觉可接受）；**若截图显示 L1 拉伸过丑，加 `minf(scale_x, 2.0)` 上限让宽路关卡立柱稍靠近路缘**——这是唯一的调优旋钮，属视觉决策不碰逻辑。
- 朝向：`Basis(side, UP, fwd)`（右手正交：`side × UP = fwd` 已代算验证）——局部 X（跨径 4.80）→ 世界侧向，局部 Z（深 1.36）→ 赛道前进方向，龙门架**跨线而立**，与 1.6m 线宽基本重合。
- 高程：基座 `y = start_line_center.y + road_lift`（白线网格在 `+road_lift+0.01`，`track_generator.gd:544`）——贴路面，不悬空；`start_line_center` 含高度剖面（曲线三维采样），山地关自动跟随。
- 备选摆放（需用户确认，§6-D3）：若要「门在线后 X 米、车从门下出发再压线」，把 origin 改为 `lc − fwd × X` 即可，一个常量。

### 4.4 行为约束

- **纯视觉无碰撞**：不建 StaticBody3D/CollisionShape3D（安装指南 `:32`：本包全部无碰撞体；真实障碍继续归 `obstacle_field.gd`）。空气墙/护栏判定不受影响（`--check=enclosure` 射线只打碰撞体）。
- **小地图不画**：小地图相机 `cull_mask = MAP_LAYER`（第 17 层，`minimap.gd:19/:103`），龙门架放第 18 层双重保证；主相机默认全层绘制 → 游戏与截图中可见。
- **HUD/小地图点位逻辑不受影响**：均按名字反查（`Opponents`/`Obstacles`/`CarMarker`），新节点名 `StartGantry` 无冲突（实读 `hud.gd:377/:403`）。
- **不碰 `.tscn`**：运行时 `add_child`，遵守「能不碰 main.tscn 就不碰」（AGENTS §22.3 编辑器吃注释教训）。

### 4.5 截图验证法（实施阶段执行）

```powershell
pwsh -File 04-Godot启动器\shoot.ps1 -Level 0 -Drive -Frames 90  -Out ..\screenshots\round4-gantry-l1.png   # 宽路 14m（缩放最大）
pwsh -File 04-Godot启动器\shoot.ps1 -Level 4 -Drive -Frames 90  -Out ..\screenshots\round4-gantry-l5.png   # 窄路 8m（立柱贴路肩）
pwsh -File 04-Godot启动器\shoot.ps1 -Level 3 -Drive -Frames 400 -Out ..\screenshots\round4-gantry-l4-through.png  # 穿门瞬间
```
核对：门跨线而立、立柱在路面外、基座不悬空、L1/L5 拉伸观感、穿门不撞。HUD 新左列（无「起步」行、总时间在走）由用户试玩确认（`--shot` 路径不走倒计时，机器截图覆盖不到互动 HUD；测试侧只断言标签存在与占位口径）。

---

## 5. 验证步骤（TDD 先红后绿；全部在仓库根 `D:/桌面/DSH-Work/data-analysis` 执行）

**提交边界（每步独立可回退；A 必须原子）**
- **A 统一计时原点**：vehicle.gd + race_position.gd + main.gd(`_on_race_go`) + countdown_scene_test.gd + race_position_test.gd。（⚠ vehicle 与 race_position 拆开必红 `race_position_scene_test.gd:63`——故意为之，证明联动必要。）
- **B 删「起步」行**：hud.gd + chase_camera.gd 注释。
- **C 龙门架**：start_gantry.gd(+.uid) + main.gd 挂载。
- **D 文档**：§2.7 四份。

**分步**
1. **先红（对 HEAD `0cb669d`）**：改测试（A 的两个文件）→ 跑 `countdown_scene_test` / `race_position_test` → 新断言红、旧断言绿 → 归档 `godot-logs/round4-countdown-red.log`、`round4-position-red.log`。（④-C 回归守护在 HEAD 上是绿的——它守护的「已知坏状态」是旧规则「加载即 arm」，由设计文档留档证明可复现。）
2. **实现 A** → 两个测试转绿（归档 `-green`）；`race_position_scene_test` / `finish_results_test` / `release_flow_scene_test` 复跑保持绿。
3. **实现 B** → `finish_results_test`（总时间行）+ 全部 tests/ QA 门复跑。
4. **实现 C** → `parse-check` + `--check=minimap`（新节点不进小地图）+ 截图三张（§4.5）。
5. **实现 D** → 文本闸门复跑（§5-12）。
6. **静态链**（每个代码提交后）：`pwsh -File 04-Godot启动器/lint-gdscript.ps1` → `pwsh -File 04-Godot启动器/parse-check.ps1`。
7. **专项**：`run-rel-final-test.ps1 -Script res://tests/<name>.gd -LogName round4-<name>` 逐个跑 tests/ 全部门（SceneTree 测试入口，照 `finish_results_test.gd:27-29` 先例）；`--check=aistart -Level 3 -RenderFps 60`（走 GO 入口，验新第四步不破坏并排发车语义）。
8. **冻结带重冻结（机时项，§6-D2）**：A/C 改了 main.gd/vehicle.gd → `data/checks/frozen/scenario.json` 的 `initial_state_contract.{main,vehicle,game_state,autopilot}_source_hash` 绑定失效（实读确认这些键存在），`tape-preflight.ps1` 会以退出码 8 秒级失败。流程：`-AiTapeMode calibrate` 生成候选 → `ai-tape-freeze.py` 冻结 → `--check=aidiag -Level 0 -RenderFps 60` 复验。**阈值一个未改**（60%/50%/110 km/h/不得超速；设计文档 §11.2）。
9. **套件**：`run-all-checks.ps1 -Quick -RenderFps 60`（15 项）→ 全量 20 项（60 FPS）。项数不变（硬约束）。
10. **双帧率 AC-13**（用户排期，§6-D4）：60/120 ×（lap×3 + opponents L4×3 + opponents L5×3），判据与 60 FPS 完全相同。本改动不碰自动化发车路径与控制律，**边际价值低于上一轮**——可降级为「60/120 各一次 lap + opponents L5」的折中方案，请用户定。
11. **lap 双稳态**：A/B 前先「同代码两跑」定模式（AGENTS §4.3）；本改动自动化路径逐字节不变，预期模式不变——若变，先查环境再查代码。
12. **文本闸门**：`check-docs.ps1` + `check-readme.ps1` 复跑全绿（误伤规避：不新写「全部 N 项」；无删文件故无路径误伤；新反引号路径实施后真实存在）。
13. **验收记录**：按 AGENTS §15 绑 commit + 工作区状态贴结果；单次通过不得宣布「试玩缺陷已修复」——「总时间与本圈对得上、无起步行」需用户试玩截屏确认后方可称修复。

---

## 6. 风险与缓解 + 需用户拍板决策点

### R1 规则修订风险（R6 变更的产品语义）
统一原点后：首圈圈速含起跑爬行（≈2~4s）；GO 后站着不动也会计入本圈。这是「总时间 ≡ 各圈之和」的代价，符合用户「彻底移除起步时间」的表述，但**它改了已批准规则**。缓解：保守备选见 D1；文档明确新语义；验收判据（圈速阈值在 `--check=lap`，自动化路径不变）不受影响。

### R2 冻结带重冻结机时
calibrate 生成 + freeze + aidiag 复验；且 aidiag 有历史抖动（`docs/testing.md:225-251`：同工作区 7 跑 4 绿 3 红，两种红法均非本任务引入）。缓解：预算 3~4 次 aidiag 复跑；**不得改任何阈值**；若复跑全红且 A/B 证明非本任务引入，按 testing.md 既有结论单独立项，不并入本任务。

### R3 龙门架模型与口径不确定（已标注）
- 「desert_ruin_gate.glb 即用户所指？」——安装指南标 L4 用途、沙漠废墟风；若用户指的是另一种门（如 `chevron_sign.glb`），只改 `GATE_SCENE` 一个常量（见 D3）。
- 三角数/包围盒取安装指南登记值（未独立解析 glb）；立柱厚度未知 → X 拉伸后的观感须截图核对（§4.5）。
- 跨线 vs 线后摆放（D3）。

### R4 名次/进度回归面
race_position 的玩家进度公式被改；已有 4 层测试把守（race_position_test 4 条边界 + race_position_scene_test 名次断言 + 新增 2 条 + countdown 陷阱守护）。缓解：A 步骤原子提交；半成品状态必红（这是特性不是缺陷）。

### R5 新节点对自动化路径的影响面
龙门架挂进所有路径（含 --check/--shot）。已核：无碰撞（物理零影响）、不进小地图层、名字不冲突、按脚本过滤的节点计数不受影响（release_flow_scene_test 实读）。残余风险：若有没读到的检查枚举场景子节点——全量 20 项套件就是闸门，红了再查（预期全绿）。

### R6 文档漂移
顺手修 README:25 / portfolio:26 / testing.md:143 三处既存过期表述（4 km/h 规则）；改后两道文本闸门复跑（§5-12）。

### D1【需拍板】R6 规则修订：**统一计时原点（推荐）vs 仅删行保留 R6（保守）**
- 推荐：圈钟也从 GO 起算，删「起步」行。总时间 ≡ 各圈之和，数字永久对得上；代价 = 修订已批准 R6 + 首圈含起跑段的产品语义变化。
- 保守：仅删「起步」行、R6 不动。零规则变更；但「总时间 41.652 vs 本圈 37.108 对不上」的老抱怨会复发（那正是 `d1fee26` 加这一行的原因）。
- **计划默认按「推荐」编写；用户选保守则 §2.1/2.2/2.6-A 全部作废，只执行 §2.4 删行 + §2.6 的 ④-C 守护 + 龙门架部分。**

### D2【需拍板】冻结带重冻结机时
需用户在实施窗口安排：1 次 calibrate + 1 次 freeze + 3~4 次 aidiag 复跑（约 20~40 分钟量级，未实测）。

### D3【需拍板】龙门架确认
① `desert_ruin_gate.glb` 是否即用户所指模型？② 摆放口径：跨线而立（默认）还是线后 X 米（车从门下出发再压线）？③ 立柱落点：路肩带内（默认，路缘 +0.6m）还是护栏外？

### D4【需拍板】AC-13 双帧率回归排期
完整版（60/120 × lap×3 + opponents L4×3 + L5×3，约 2h 机时，设计文档 D2）还是降级版（各一次关键项）？本改动不碰自动化路径，建议降级+留记录。

---

## 附：本任务的实读复核记录（证据来源）

- 必读三份：`godot-racer/AGENTS.md`（全文）、`plan/racing-system-design-20261018.md`（全文）、`plan/feature-race-start-results-1.md`（全文）。
- 代码实读：`game_state.gd`（全文）、`start_countdown.gd`（全文）、`main.gd`（全文 886 行）、`race_position.gd`（全文）、`hud.gd`（全文）、`vehicle.gd`（重点段 40-180/250-330/460-580）、`ai_opponent.gd`（240-360/870-940）、`opponent_spawner.gd`（130-219+文件头）、`track_generator.gd`（15-79/245-295/500-580/650-670）、`chase_camera.gd`（175-226）、`checks/ai.gd`（335-395 + GO 调用点）、`checks/lap.gd`（320-375）、`minimap.gd`（层常量区）。
- 测试实读：`countdown_scene_test.gd`（全文）、`race_position_test.gd`（全文）、`race_position_scene_test.gd`（全文）、`finish_results_test.gd`（1-165 + 断言区）、`release_flow_scene_test.gd`（40-90）。
- 资源/配置实读：`models/environment/`（目录列举 + 安装指南全文 + `.import` 侧车在库）、`data/levels/level_1..5.tres`（ai_opponents/road_width）、`data/checks/frozen/scenario.json`（绑定哈希键）、`04-Godot启动器/`（run-all-checks 20 项清单、tape-preflight 契约、check-docs/check-readme 扫描规则）、`godot-racer/docs/testing.md`（计数与 aidiag 抖动段）、`docs/portfolio-design.md`、根 `README.md`、`docs/architecture/`（仅有 ADR-001；无 architecture.md / control-manifest.md / engine-reference/**——已按 AGENTS.md 契约执行）。
- git 只读：HEAD `0cb669d`、工作区 2 个 `.import` 改动、最近 6 条提交（`d1fee26` = 「起步」行来源）。
- 未独立复核（已标注）：glb 三角数/包围盒（取安装指南登记值）、出生点 2.77m（取主理人实测，公式已核）、aidiag/全套件机时（未实测，给出量级估计）。

---

**Handoff 说明**：以上为完整计划全文。决策记录见 §7；执行用 diff 清单见 `round4-implementation-diff-20261019.md`（待用户确认）；确认后按 TDD 纪律出具交接文案，新对话实施。

---

## 7. 决策记录（2026-10-19 17:08 用户拍板）

| # | 决策点 | 用户裁定 | 对计划的影响 |
|---|---|---|---|
| D1 | 计时原点 | **选 A：统一原点，修订 R6**。「总时间 ≡ 各圈之和」是硬性要求；首圈含起跑爬行符合真实赛车静止起步逻辑 | §2.1/2.2/2.3/2.6-A 按原案执行 |
| D2 | 冻结带重冻结 | **批准**：1 次 calibrate + 1 次 freeze + 3~4 次 aidiag 复跑（20~40 分钟） | §5-8 不变 |
| D3 | 龙门架 | **确认 `desert_ruin_gate.glb`；跨线而立；立柱放路肩带内，硬性要求：足够净距不撞车 + 碰撞体正确不穿模** | **§4 升级**：原「纯视觉无碰撞」作废 → 带碰撞设计（见下） |
| D4 | AC-13 | **降级**：先跑关键项各一次（lap×1 + opponents L4×1 + L5×1）；完整 18 次留发布前最终验收（可后台挂跑不阻塞） | §5-10 改为降级版 |

**D3 升级细节（diff 清单 C 节落地）**：每根立柱一个 `BoxShape3D`（`StaticBody3D`，场地层 1，车 mask=3 都会撞），盒体与视觉立柱**同址同厚**——视觉比碰撞大会「车头陷网格才被挡」（穿模），碰撞比视觉大会「空气挡车」，同厚是唯一解；横梁在高处（模型高 4.44m）不建碰撞。缩放公式 `s = (road_w + 2c) / (S_m − 2·t_m)`（S_m=4.80 模型跨径、t_m=实测立柱厚、c=0.2m 净距）保证**立柱内侧面离路面边缘 ≥0.2m**，正常驾驶不可能碰到。

**D3 两处已向用户言明的偏差**：① 宽路关卡（L1/L2）立柱外侧面会越过护栏线约 0.5~0.9m（模型腿厚 × 宽路缩放系数所致）——真实龙门架的腿本就常在护栏外，硬性净距由公式保证，观感由截图核对；② 立柱厚度取模型实测值（`MeshInstance3D` AABB），单网格模型测不到时走兜底值 0.5m 并在日志声明，以截图核对为准。
