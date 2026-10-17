---
goal: 完成选关后的倒计时同步发车与比赛结算闭环
version: 1.0
date_created: 2026-10-17
last_updated: 2026-10-17
owner: Godot Racer 项目
status: 'Planned'
tags: [feature, racing, gameplay, ui, acceptance]
---

# Introduction

![Status: Planned](https://img.shields.io/badge/status-Planned-blue)

本计划供接手 Godot Racer 的开发者直接执行。玩家在主菜单选关后进入赛道，待世界、障碍和 AI 全部装配完成，看到 **3 → 2 → 1 → 出发！**；倒计时结束前玩家车与 AI 均不能发车，到点后两车在同一个后续物理帧获得发车权限。AI 不再等待玩家速度达到 4 km/h。玩家完成目标圈数后显示结算页，提供 **返回主菜单／再玩一局／退出游戏**。默认倒计时 **3.0 秒**，只改一处常量即可改成 5.0 秒。

本文件是**实施计划，不是完成报告**。2026-10-17 的基线为 `0e5430f7a1f5e4adfd25f886c4297550ac48b01d`，本地 HEAD 与实际远端 `refs/heads/main` 相等。该提交的 60 FPS Quick **15/15、进程退出码 0**；这只证明旧发车规则下的快速检查通过，不能当作新倒计时验收。全量 20 项、双帧率长时跑圈、正式独立包尚未完成。

## 1. Requirements & Constraints

| ID | 要求或约束 | 完成判据 |
|---|---|---|
| REQ-001 | 选关后先装配赛道，再显示 3 秒倒计时。 | 任何一关第一次进入和“再玩一局”都显示 `3/2/1/出发！`，没有加载过程占用倒计时时间。 |
| REQ-002 | 倒计时前及倒计时期间禁止玩家和 AI 发车。 | 即使倒计时期间按住 `W`，玩家车和 AI 在“出发！”前均无主动驱动力、无向前位移；允许静止车体因装配产生的微小物理沉降，测试须区分沉降与发车。 |
| REQ-003 | “出发！”由单一入口放开玩家控制并给全部 AI 发车许可。 | AI 不再依赖玩家速度；玩家不按 `W`，AI 也在倒计时结束后发车。开关关闭 AI 时仍有倒计时，且不生成 AI。 |
| REQ-004 | 倒计时不计入本圈用时；完成目标圈数只触发一次结算。 | 赛前显示圈速为空；完成时保存圈数、末圈、最快圈快照，玩家和 AI 停止更新。 |
| REQ-005 | 结算页三个出口为“返回主菜单／再玩一局／退出游戏”。 | 返回主菜单后可重新选关；再玩一局重新装配并倒计时；退出走现有确认框，取消仍停留结算。 |
| REQ-006 | 倒计时可通过 `ESC` 请求退出；取消后从剩余时间继续。 | 确认框显示期间数字不减少；取消后仍冻结比赛，直到正常“出发！”。窗口关闭同样走确认。 |
| CON-001 | 保持 Godot 4.4.1、Jolt、120 Hz 物理、默认 60/可选 120 FPS。 | 不改变 `Engine.time_scale`、车辆控制律、赛道数据、L4/L5 物理验收阈值。 |
| CON-002 | `--check` 与 `--shot` 不等待交互倒计时；真实游玩路径必须经过倒计时。 | 现有自动化能正常退出；`aistart`、`aidiag` 改为验证新发车语义，不能沿用“玩家先动 AI 才动”的旧断言。 |
| CON-003 | 遵守仓库根目录及 `godot-racer/AGENTS.md`。 | 先失败用例后实现；物理验收串行；新改代码文件不超过 1000 行；提交显式路径并核对远端。 |

当前实现的具体切入点：

- `godot-racer/scripts/menu.gd:327-333`：选关按钮设置 `GameState.chosen_level`，切到 `main.tscn`。
- `godot-racer/scenes/main.gd:182-189`：`_ready()` 目前立即调用 `GameState.begin_race()`；改为区分互动模式和自动化模式。
- `godot-racer/scenes/main.gd:189-285`：`_after_world_ready()` 先等赛道、接线、测物理基线、生成 AI；倒计时必须在这些动作完成后启动。**不能在 `_avg_physics_ms()` 前暂停 SceneTree**，该函数在物理帧上 `await`，提前暂停会挂住装配。
- `godot-racer/scenes/main.gd:667-676` 与 `godot-racer/scripts/opponent_spawner.gd:209-217`：旧的“玩家达到 4 km/h 才让 AI 发车”路径，需求变更后必须删除或替换。`main.gd:175-176` 的阈值也应移除；清理相关过时注释。
- `godot-racer/scripts/game_state.gd:21-23,101-175`：现有 `MENU/RACING/PAUSED/FINISHED/EXIT_CONFIRM` 状态及结算、暂停、退出入口。
- `godot-racer/scripts/vehicle.gd:706-728,979-1075`：玩家物理和输入执行；需要一个只控制“赛前能否响应驾驶输入”的门闩，不改既有引擎力、制动、转向公式。
- `godot-racer/scripts/opponent_spawner.gd:195-217`：`arm_opponents()` 已存在，但目前 `_ai_started` 在旧速度检测函数里置位；改为由幂等的统一发车调用置位。
- `godot-racer/scenes/main.gd:284-295`、`godot-racer/scripts/finish_menu.gd:1-50`：结算信号和页面已经接通，须复用并改按钮文案/回归行为，不另建一套结果系统。

## 2. Implementation Steps

### Implementation Phase 1

- GOAL-001: 先固定新行为的失败证据；本阶段不改生产代码。依赖：无。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-001 | 记录 `git rev-parse HEAD`、`git status --short`、`git ls-remote origin refs/heads/main`。已有四组未跟踪素材/审计文件属于用户工作，**不要**一并暂存或删除。 |  |  |
| TASK-002 | 在 `godot-racer/tests/` 新建倒计时场景测试：选关或直接加载互动场景后，等待 `_setup_done`；先断言玩家和 AI 均未发车，再在“出发！”处断言均已解锁。测试先对基线跑红。 |  |  |
| TASK-003 | 更新现有 `--check=aistart` 的期望文本和断言，不再以玩家达到 4 km/h 作为 AI 发车条件；旧版先跑红。检查行数仍为 20，`aistart` 名称保留，避免遗漏既有覆盖。 |  |  |

### Implementation Phase 2

- GOAL-002: 建立明确的加载、倒计时和同步发车状态。依赖：GOAL-001。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-004 | 在 `game_state.gd` 的 `Phase` 增加 `LOADING`、`COUNTDOWN`；新增 `prepare_race()`（清成绩、解除上局暂停、进入 LOADING）和 `enter_countdown()`（只接受 LOADING，进入 COUNTDOWN、暂停树）。保留现有 `begin_race()` 给检查/截图快速路径。 |  |  |
| TASK-005 | 在 `vehicle.gd` 增加 `start_locked: bool`，互动场景装配开始时置 `true`；`_update_drive()`、`_update_steering()` 在锁定时忽略驾驶动作并保持既有怠速制动，禁止油门、刹车、转向和手刹对赛前车辆起作用。不改控制律常量。自动化检查默认不锁，只有新版发车专项显式锁。 |  |  |
| TASK-006 | 在 `main.gd` 的 `_ready()` 通过命令行识别 `--check=`/`--shot`：自动化走原即时路径；普通选关或 `--level=N` 走 `prepare_race()` 与玩家车锁。`_after_world_ready()` 完成 AI 生成后才调用 `enter_countdown()`，创建倒计时 UI，并把 `_setup_done` 保持为“装配完成”的真值。 |  |  |
| TASK-007 | 新建 `godot-racer/scripts/start_countdown.gd`（CanvasLayer，`PROCESS_MODE_ALWAYS`），唯一时长常量 `COUNTDOWN_SECONDS := 3.0`，显示 3、2、1，各 1 秒；`_process(delta)` 只在 `GameState.phase == COUNTDOWN` 时累计，因此退出确认出现时冻结剩余时间。到 0 只触发一次 `finished` 信号；显示“出发！”约 0.5 秒后移除自身，期间不阻塞驾驶输入。 |  |  |
| TASK-008 | `main.gd` 仅编排 `finished`：同步设置玩家 `start_locked=false`、调用 `_opponent_spawner.arm_opponents()` 并切入 `RACING`/解除树暂停，三步在一个回调内、下一物理帧同时生效。`OpponentSpawner.arm_opponents()` 幂等设置 `_ai_started=true`；删除 `maybe_start_opponents()`、`ai_start_speed_kmh` 和 `_process()` 中按玩家速度轮询的分支。所有旧调用点和说明同步改正。 |  |  |

发车输入细节：装配时清理上局残留驾驶动作；玩家在倒计时期间新按下并保持 `W`，因 `start_locked` 和暂停不会提前移动，“出发！”后可直接给油。**不要在“出发！”回调里再次 `release_drive_input()`**，否则需要松开重按，手感会像按键失灵。用专项测试覆盖此情形。

### Implementation Phase 3

- GOAL-003: 保持结算及退出状态与新倒计时一致。依赖：GOAL-002。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-009 | 修改 `GameState.restart_race()`：清成绩、解除暂停并重新加载当前关卡，交由新场景从 LOADING 开始；不得在重载前把比赛直接设为 RACING。`back_to_menu()` 恢复 MENU，清倒计时/结算节点和驾驶输入。 |  |  |
| TASK-010 | `GameState.cancel_exit()` 在返回 COUNTDOWN 时继续让 SceneTree 保持暂停；倒计时 UI 的 ESC 进入现有退出确认，取消后继续剩余秒数。返回 FINISHED 时继续暂停，不能让车辆恢复。 |  |  |
| TASK-011 | 复用 `finish_race()` 的首次完成快照与 `main.gd::_on_race_finished()` 的一次性门闩。把 `finish_menu.gd` 的按钮改成“返回主菜单／再玩一局／退出游戏”；全屏结算层保留冻结的比赛画面，显示目标圈数、末圈和最快圈。ESC 与“返回主菜单”一致。 |  |  |
| TASK-012 | `--check`、`--shot`、无 AI 三种路径分别做场景测试：不得被倒计时弹层卡住；截图自动退出；无 AI 时玩家仍倒计时。为 `aistart`/`aidiag` 注入 main 的同一发车回调，在专项检查中模拟“出发！”而不等真实 3 秒；其它物理检查沿用显式发车方式。 |  |  |

### Implementation Phase 4

- GOAL-004: 以实际流程和原判据收口，然后再考虑发布。依赖：GOAL-003。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-013 | 跑 lint、GDScript 解析、倒计时专项、结算场景测试和 `--check=aistart/aidiag/pause`；所有检查需要有最终 PASS/FAIL 标志与进程退出码 0，不能只看中途日志。 |  |  |
| TASK-014 | 在 60 与 120 FPS 下验证真实菜单进入赛道的倒计时、保持油门、AI 独立发车、完成比赛、三个结算出口及退出取消；逐项保存原始日志和必要截图。 |  |  |
| TASK-015 | 串行运行全量 20 行套件，并按仓库现有判据重跑 L4 玩家三次三圈、L4/L5 AI 各三次冷启动以及 L5 雪地制动定向检查。核心物理、控制律或验收阈值如需修改，先列最小差异和影响，不为刷绿放宽判据。 |  |  |
| TASK-016 | 仅在上述游戏验收通过后，从确定的 Git 提交制作 Windows 包，验证独立目录五关可进入、倒计时/结算可用、退出码和 SHA256；干净 Windows 机器仍列外部待验收。显式路径提交、推送并核对本地与实际远端 SHA。 |  |  |

## 3. Alternatives

- **ALT-001**: AI 保持“玩家先动才动”。不选；与本次明确要求冲突，且 AI 发车时间会受玩家准备时间影响。
- **ALT-002**: 在 `Main._ready()` 一进入就 `SceneTree.paused=true`。不选；赛道装配和 `_avg_physics_ms()` 要等待 `physics_frame`，会挂住加载。装配期间用玩家输入门闩，装配完成后才暂停树倒计时。
- **ALT-003**: 新建独立结算场景。暂不选；现有 `finish_menu.gd` 已有状态快照和三个出口。全屏 CanvasLayer 可达到“结算页面”体验，并保留冻结的比赛现场，改动更小。
- **ALT-004**: 在 `OpponentSpawner` 内放自己的 3 秒 Timer。不选；会形成 AI 和玩家两套时钟，难保证同步，也使倒计时 UI 与实际发车漂移。

## 4. Dependencies

- **DEP-001**: Godot 4.4.1 标准版、Jolt、现有 Windows 导出模板；本功能开发不需要新增外部依赖或 3D 素材。
- **DEP-002**: `GameState` autoload、`main.tscn`、`vehicle.gd`、`opponent_spawner.gd`、`finish_menu.gd` 和现有测试启动器。
- **DEP-003**: 仓库 `AGENTS.md` 与 `godot-racer/AGENTS.md` 的物理验收、文件边界和 Git 纪律。

## 5. Files

- **FILE-001**: `godot-racer/scripts/game_state.gd`：LOADING/COUNTDOWN、状态过渡、重开与退出取消。
- **FILE-002**: `godot-racer/scenes/main.gd`：互动/自动化入口判定、装配后倒计时、唯一发车回调；保持编排职责。
- **FILE-003**: `godot-racer/scripts/start_countdown.gd`（新增，含 `.uid`）：倒计时画面与 3 秒计时。
- **FILE-004**: `godot-racer/scripts/vehicle.gd`：赛前驾驶输入门闩，仅防赛前运动，不动动力公式。
- **FILE-005**: `godot-racer/scripts/opponent_spawner.gd`：幂等同步发车，移除玩家车速轮询。
- **FILE-006**: `godot-racer/scripts/checks/ai.gd`：`aistart`/`aidiag` 新语义与统一发车回调。
- **FILE-007**: `godot-racer/scripts/finish_menu.gd`：结算三个按钮文案与全屏表现。
- **FILE-008**: `godot-racer/tests/` 下倒计时/结算场景测试；`godot-racer/tests/release_flow_scene_test.gd` 按新重开流程更新。
- **FILE-009**: `godot-racer/docs/testing.md`、根 `README.md`、`dist-assets/README-玩家版.txt`：实施通过后只更新玩法事实与验收状态；不要先写完成。

## 6. Testing

| ID | 测试 | 必须观察到 |
|---|---|---|
| TEST-001 | 任一关选关进入，装配期间按住 W。 | `LOADING` 中无主动驱动力；装配完才出现数字 3。 |
| TEST-002 | 倒计时 3 秒，60/120 FPS 各一次。 | 3/2/1 各约 1 秒，帧率不改变总时长；AI 与玩家在倒计时前无主动位移。 |
| TEST-003 | 玩家倒计时期间按住 W。 | “出发！”前仍静止；GO 后玩家在下一物理帧可加速，不需松开重按。 |
| TEST-004 | 玩家完全不按键、AI 开启。 | GO 后 AI 自行发车；不再等待玩家达到 4 km/h。 |
| TEST-005 | AI 开关关闭。 | 倒计时照常、无 AI 节点、玩家 GO 后可驾驶。 |
| TEST-006 | 倒计时 ESC、退出取消、窗口关闭取消。 | 确认框期间剩余秒数冻结；取消回原秒数，比赛仍暂停。 |
| TEST-007 | 达到目标圈数并重复发送完成信号。 | 仅一个结算页、快照不变、玩家/AI/计时停住；末圈和最快圈来自车辆记录。 |
| TEST-008 | 结算三个按钮和 ESC。 | 返回主菜单可重新选关；再玩一局清圈数并重新倒计时；退出确认取消仍在结算。 |
| TEST-009 | `--check`、`--shot`、Quick 和全量套件。 | 自动化不会等待 3 秒交互或挂住；新 `aistart` 真正测新语义；Quick 15/15、全量 20/20、最终退出码 0。 |

建议执行入口（在仓库根目录）：

```powershell
pwsh -File '.\04-Godot启动器\lint-gdscript.ps1'
pwsh -File '.\04-Godot启动器\parse-check.ps1'
pwsh -File '.\04-Godot启动器\run-check.ps1' -Check aistart -Level 3 -RenderFps 60
pwsh -File '.\04-Godot启动器\run-check.ps1' -Check aidiag -RenderFps 60
pwsh -File '.\04-Godot启动器\run-all-checks.ps1' -Quick -RenderFps 60
pwsh -File '.\04-Godot启动器\run-all-checks.ps1' -RenderFps 60
```

`-Level` 为 **0 起**：L4 用 `-Level 3`，L5 用 `-Level 4`。每项都查最终标记、原始日志和进程退出码；Godot 进程或日志未完结时不得报通过。物理检查串行，不并发启动多台验收 Godot。

## 7. Risks & Assumptions

- **RISK-001**: 暂停过早会让世界构建/物理基线采样卡在 `await physics_frame`；必须先完成 `_after_world_ready()` 的装配，再暂停倒计时。
- **RISK-002**: 原 `aistart` 和 `aidiag` 明确写着“玩家先动 AI 才动”；新需求要求同步改这些测试与日志语义，不能拿旧检查的绿色结果冒充新需求通过。
- **RISK-003**: `begin_race()` 当前释放驾驶输入；如果 GO 时原样调用，会让倒计时中按住的 W 失效。需分离“清旧输入”和“GO 放行”。
- **RISK-004**: `cancel_exit()` 当前只让 `PAUSED/FINISHED` 保持树暂停；新增 `COUNTDOWN` 时必须补上，否则取消确认会提前解冻赛道。
- **RISK-005**: `restart_race()` 当前在 reload 前直接 `begin_race()`；不改会跳过新倒计时。
- **ASSUMPTION-001**: 本计划默认 3 秒。用户提出“3 秒或 5 秒”，尚未要求固定 5 秒；只在 `COUNTDOWN_SECONDS` 一处切换。
- **ASSUMPTION-002**: “结算页面”实现为覆盖全屏的现有 CanvasLayer，底层赛道冻结；如果以后要独立 `.tscn` 场景，可在功能通过后另行替换，不影响状态与成绩真值。
- **ASSUMPTION-003**: 另有未跟踪 Blender 文件、环境素材目录和审计 HTML；它们不是本功能的必要改动，不自动删除或提交。`dist/` 里可能残留上次中断构建的快照，不代表已有可交付包。

## 8. Related Specifications / Further Reading

- [开发契约](../godot-racer/AGENTS.md)
- [当前测试说明](../godot-racer/docs/testing.md)
- [AI 发车与赛道设计](../godot-racer/docs/ai-opponent-design.md)
- [结算场景测试](../godot-racer/tests/release_flow_scene_test.gd)
- [原 Windows 首版导出记录](../godot-racer/docs/release-export.md)

接手时先读本文件和上述开发契约，核对 HEAD 与 Git 状态，然后从 **TASK-001** 开始。新需求完成前，不要把现有 15/15 Quick 或旧 `aistart` 结果写成“倒计时已通过”，也不要先做最终发布包。
