---
goal: 让验收自动驾驶（`--check=lap` 与 `shoot.ps1 -Drive` 控制的玩家车）在障碍关卡上按**共享**选道逻辑行驶，消除玩家车「撞障碍 → 复位 → 又回原位置 → 再撞」的循环
version: 1.0
date_created: 2026-10-08
last_updated: 2026-10-08
owner: racer-dev
status: 'In progress'
tags: [bug, ai, acceptance, test-harness, obstacle]
---

# 验收自动驾驶的障碍避让

![Status: In progress](https://img.shields.io/badge/status-In%20progress-yellow)

本计划修复一个**被验收覆盖漏洞藏了很久**的缺陷：`--check=lap` 与 `shoot.ps1 -Drive`
控制的**玩家车自动驾驶**（`main.gd::_drive_track()`）**完全没有障碍感知** —— 它死盯
「中心线前方 45m」并给全油门。而 `obstacle_field.gd` 的静态障碍横向位置被
`_pick_lateral()` 挤到**中心线 ±0.125m 以内**，也就是说：**在 L4 荒漠上，
自动驾驶是「瞄准每一块石头」在开。**

> 触发原因：项目所有者观察到的「测试模式下玩家车撞障碍 → 重置 → 又回到原位置 → 再次撞障碍」。
> 本轮先做取证，确认它属于**玩家车**这条链路，与 `ai_opponent.gd` 无关。

## 1. Requirements & Constraints

- **REQ-001**：验收自动驾驶在有静态/动态障碍的关卡上必须选一条**经过验证可通行**的车道，而不是无条件瞄中心线。
- **REQ-002**：选道必须复用**已有唯一真相源** `obstacle_field.pick_clear_lane()`，不得在 `main.gd` 里另写一套近似公式（AGENTS.md §2.3 / §5.3）。
- **REQ-003**：找不到安全车道时**减速等待优先于硬挤**（AGENTS.md §8.2）。
- **REQ-004**：修复后 `--check=lap -Level 3`（第 4 关荒漠）必须完成 ≥2 圈且 **卡住事件 = 0**。
- **REQ-005**：`--check=lap` 在**无障碍关卡**（L1 默认）上的行为不得改变。
- **CON-001**：不改 `LevelConfig` 字段、不改 `.tres`、不改赛道几何。
- **CON-002**：不改 `racing_line.gd` 的核心公式。
- **CON-003**：不得放宽任何既有判据来变绿（AGENTS.md §4.2 规则 / §18 Never）。
- **CON-004**：静态障碍仍必须是**单个** `StaticBody3D`（性能红线）。
- **CON-005**：任何时刻必须保留 ≥ 车宽 + 0.5m 的通行缝隙。
- **GUD-001**：TDD：先让 `lap -Level 3` 红，再改实现，再绿。
- **GUD-002**：涉及位置/姿态的结论必须**数值 + 实机截图**两个都给（AGENTS.md §10）。
- **PAT-001**：AI 侧已有的调用范式（`ai_opponent.gd::_effective_lane()`）就是本修复的模板。

## 2. Implementation Steps

### Implementation Phase 1 —— 取证（已完成）

- GOAL-001: 证明「玩家车反复撞障碍」的根因，而不是猜。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-001 | 读 `_pick_lateral()`：算出 L4 静态石头横向 ∈ **[0, 0.125] m**（`safe_max = ai_left − car_half − PASS_EXTRA = 1.5 − 0.875 − 0.5`），石头半宽 0.95m → **整块横跨中心线** | ✅ | 2026-10-08 |
| TASK-002 | 读 `_drive_track()`：确认它只做「朝 `centerline_point(arc+45)` 打方向 + 按死油门」，**零障碍感知** | ✅ | 2026-10-08 |
| TASK-003 | 确认玩家车有**两套互不知情的恢复**：`vehicle.gd::_check_recovery()→reset_to_track()`（落点 = 最近中心线点）与 `main.gd::_drive_recover()`（落点 = `_drive_best_track_arc()`） | ✅ | 2026-10-08 |
| TASK-004 | 复现：`run-check.ps1 -Check lap -Level 3` → 360s 内 **卡住 45 次、复位 13 次**，只跑完 2 圈 | ✅ | 2026-10-08 |
| TASK-005 | 确认循环形态：卡住 #8/#9/#10 全在**同一个点** `(190.83, -0.06, -193.73)`，每次被重置到弧长 ≈1500，开 58m 又撞回来 | ✅ | 2026-10-08 |
| TASK-005b | 加 `_probe_blocker()`（真实车体盒 + `cast_motion` 六向 + 射线指名）取证：**六向 8m 全空**、`obstacle_field` 卡住点前后 51m **无任何障碍** —— 推翻"被石头挡住" | ✅ | 2026-10-08 |
| TASK-005c | 由取证反查出**真正的第二个根因**：四轮 `force=0.0 brake=2.5` = `engine_brake`，即**没有油门输入**。`_drive_recover()` 的掉头分支按下 `brake_reverse` 后**没有任何地方释放**，与 `accelerate` 同时按住 → `Input.get_axis` 恒为 0 → `_driving=false` → **车永久给不上油** | ✅ | 2026-10-08 |
| TASK-005d | 量化该 latch 的影响：原始日志 `repro-l4-lap-lap.log` 里 45 次卡住中 **16 次在 latch 之前**（真实撞障碍）、**29 次在 latch 之后**（油门锁死） | ✅ | 2026-10-08 |

### Implementation Phase 2 —— 红 → 绿

- GOAL-002: 让验收自动驾驶按共享选道逻辑行驶，使 `lap -Level 3` 转绿。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-006 | 确认红：`pwsh -File .\run-check.ps1 -Check lap -Level 3` 必须红（卡住事件 > 0） | | |
| TASK-007 | 改 `main.gd::_drive_track()`：用 `_obstacle_field.pick_clear_lane()` 选道，瞄「中心线前方 `ahead` 米 + 该车道横向偏移」 | | |
| TASK-008 | `pick_clear_lane` 返回 `found=false` 时：保持车道并**收油**（减速等待），不硬挤 | | |
| TASK-009 | 无障碍关卡短路（`obstacles.is_empty()` → 直接用中心线），保证 REQ-005 | | |
| TASK-010 | 绿：`lap -Level 3` 卡住事件 = 0、≥2 圈 | | |

### Implementation Phase 3 —— 回归与证据

- GOAL-003: 证明修复没弄坏别的东西，并留下可复核的证据。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-011 | `lap -Level 3` 连跑 3 次全绿（单次通过不算数） | | |
| TASK-012 | 回归：`lint-gdscript` / `parse-check` / `lap`（默认关卡）/ `enclosure` | | |
| TASK-013 | 截图证据：`shoot.ps1 -Level 3 -Drive` 拍「自动驾驶绕开石头」而不是停在石头前 | | |
| TASK-014 | 同步文档：`docs/testing.md` 的已知缺陷一节 + `docs/engineering-notes.md` 新增一条 | | |
| TASK-015 | 提交 + 推送 GitHub（`origin/main`） | | |

### Implementation Phase 4 —— 覆盖漏洞（需项目所有者拍板后再做）

- GOAL-004: 这个缺陷能藏这么久，是因为 `run-all-checks` 的 `lap` 跑的是**默认关卡（L1，无障碍）**。

| Task | Description | Completed | Date |
|------|-------------|---------|------|
| TASK-016 | 提议把「有障碍关卡的 `lap`」纳入门禁；纳入前必须先 3 次全绿 | | |
| TASK-017 | 纳入后同步 `run-all-checks.ps1` 项数、README、`docs/testing.md`（19→20 类计数） | | |

## 3. Alternatives

- **ALT-001**：改 `_pick_lateral()`，让石头不要全挤在中心线上。
  **不选**：这是**关卡设计/手感**变更，会改变人类玩家的难度与体验，属 AGENTS.md §18「Ask/Review first」，不是技术修复。
- **ALT-002**：只改 `reset_to_track()` / `_drive_recover()` 的落点，让它避开障碍。
  **不选（本轮）**：这是治症状。车**仍然会**撞上去（因为它瞄的就是中心线），只是被弹到别处 —— 循环会变成「撞 → 弹走 → 撞别的」。落点问题另开一轮（见 RISK-003）。
- **ALT-003**：在 `main.gd` 里给自动驾驶新写一套避障。
  **不选**：直接违反 AGENTS.md §2.3（`racing_line.gd`/`track_layout.gd` 是唯一真相源）与 §5.3；本项目最大的教训就是「两条路径各写一遍然后漂移」。

## 4. Dependencies

- **DEP-001**：`scripts/obstacle_field.gd::pick_clear_lane(prefer_lane, arc, horizon, car_half, lane_limit) -> {found, lane}`（已存在，AI 在用）。
- **DEP-002**：`main.gd` 的 `_obstacle_field` 成员（`main.gd:43`，已存在）。
- **DEP-003**：`track.call("nearest_on_centerline")` / `centerline_point` / `road_half_width`（已存在）。

## 5. Files

- **FILE-001**：`godot-racer/scenes/main.gd` —— 只改 `_drive_track()`（约 991 行）与其调用点的签名。
- **FILE-002**：`godot-racer/docs/testing.md` —— 已知缺陷状态 + 结果表。
- **FILE-003**：`godot-racer/docs/engineering-notes.md` —— 新增一条踩坑记录。
- **FILE-004**：（Phase 4）`04-Godot启动器/run-all-checks.ps1` 与两份文档的计数。

## 6. Testing

- **TEST-001**（红 → 绿）：`run-check.ps1 -Check lap -Level 3` —— 判据：完成 ≥2 圈、**卡住事件 0**、复位 0、车头方向正常。
- **TEST-002**（防回归）：`run-check.ps1 -Check lap`（默认关卡，无障碍）—— 判据不变，行为必须与改前一致。
- **TEST-003**（防回归）：`run-check.ps1 -Check enclosure` —— 缺口仍为 0。
- **TEST-004**（静态）：`lint-gdscript.ps1` + `parse-check.ps1`。
- **TEST-005**（人工证据）：`shoot.ps1 -Level 3 -Drive` 截图，看车是**绕过去**还是**停在石头前**。
- **TEST-006**（反假绿）：确认改前 `lap -Level 3` **真的红**（否则这个判据区分不了改前改后，等于假判据 —— 见 engineering-notes 第 57、60 条）。

## 7. Risks & Assumptions

- **RISK-001**：`_drive_track()` 同时被 `_check_lap`（行 1058）与 `_shot_block`（行 4481）调用 —— 改动会同时影响「跑圈验收」与「截图自动驾驶」。**缓解**：TEST-002 + TEST-005。
- **RISK-002**：低速时选道可能来回横跳（车道在中心线与绕行车道之间抖）。**缓解**：`pick_clear_lane` 的候选按「离 `prefer_lane` 最近优先」排序，天然倾向不动；若实测抖动，用 `hysteresis` 而不是放宽判据。
- **RISK-003**：`_drive_recover()` 的卡住分支调用 `_drive_best_track_arc(..., hint_arc=-1.0)`，而该函数的扫描范围**恒为整圈**（`span = total * 0.5` 两个分支都设），所以它会按「朝向最匹配」把车瞬移到**几十米外**——实测 268m / 58m。这是**独立的第二个缺陷**，本轮**不修**（会牵动已验证的「掉头纠正 ≤2.0s」判据），另开一轮。
- **RISK-004**：`--check=lap` 单项最长 420s，TDD 回路慢。**缓解**：失败在 13s 内即可复现，但判据仍需跑满 2 圈。
- **ASSUMPTION-001**：L4 卡死点 `(190.83, -0.06, -193.73)`（离中心线 2.14m）**不是静态石头**（石头在 ±0.125m，够不着）也**不是护栏**；按横向区间推算落在**动态滑动路障**的行程带（横向 2.0~3.6m）内。**未实测确证**，由 TASK-010 的结果间接验证：若选道后卡住消失，则该占用确实在 `obstacles[]` 里（`pick_clear_lane` 覆盖动态障碍）；若仍卡住，说明卡死物不在障碍集合里，本假设被证伪，需要新的假设。

### Implementation Phase 5 —— 第二轮取证（**只读，不改行为**，2026-10-08）

- GOAL-005: 把剩余卡死逐个解释清楚：是"撞障碍"，还是"reset 放到了不安全位置"，
  还是"两套恢复抢控制"，还是"规划时安全、到达时不安全"。

工具：全部读数带 `[DEBUG-L4]` 前缀（可按该前缀一次性 grep / 整块删除），入口在两处：
`main.gd` 的 `_l4_push / _l4_stuck_record / _l4_dump_window / _l4_eta_report / _l4_note_rec`
（环形时间线 + 结构化卡死记录 + 规划视角 + 恢复打点）与 `vehicle.gd` 的
`_debug_rec / debug_reset_target / debug_reset_lane_lookback`，
数据源是 `obstacle_field.debug_obstacles_near / debug_dynamic_state`。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-018 | 实验 1（卡死分类）：两轮共 9 次，**全部是 A 类真实撞击**（4 次静态石头 id=4、3 次动态路障 id=7、1 次石头 id=3 + 甩尾） | ✅ | 2026-10-08 |
| TASK-019 | 实验 2（骑石头时序）：本轮两轮 `y` 最大值仅 1.000m（= recovery 投放高度）→ **未复现**；上一轮日志显示悬空态出现在 **reset 之后** | ✅ | 2026-10-08 |
| TASK-020 | 实验 3（落点真实碰撞体）：两轮 18 次 `intersect_shape` **全部 safe=true**，方案 A 与方案 B 给出同一车道 → **"reset 把车放进石头里"证伪** | ✅ | 2026-10-08 |
| TASK-021 | 实验 4（双恢复）：不与同帧打架，但同一次停顿被**先后处理两次**（main@3.0s → vehicle@4.0s，间隔 18~192 帧） | ✅ | 2026-10-08 |
| TASK-022 | 实验 5（规划预算）：**根因** —— 石头进入 45m 视野才翻转车道，而横向移动需要约 100m；起始横向越靠右越撞得上 | ✅ | 2026-10-08 |
| TASK-023 | 顺带发现：`vehicle::recover_upright` 在 **0/4 接地 + 14~45 m/s** 触发 5 次，集中在 arc 966~1024（石头 id=3 一带）→ 被撞飞到空中 | ✅ | 2026-10-08 |

**本轮结论**：剩余卡死**不是** reset 落点安全问题，**不是**同帧控制权冲突，
而是 **`_drive_track()` 的"决策距离 = 执行距离"**：`prefer_lane` 恒为 0、
前瞻 45m、且只在障碍进入视野时才变道 —— 三件事共用一个 45m。
修复方向：把"何时决定"与"何时必须到位"解耦。
**已实施（见 testing.md 的第三轮一节）**：prefer_lane 改为本车实际横向 + 选道前瞻独立为
DRIVE_DECISION_HORIZON。A/B 实测（每组 1~2 次）**不支持"加长前瞻"**：45 优于 90 与 120。
**L4 仍未修好**：判据是卡住 = 0，干净基线上仍是 6~11 次。
下一刀应查 "换道 commitment / hysteresis" 与横向执行速率，而不是继续加大前瞻。

### Implementation Phase 6 —— 第四轮取证：变道走廊（**只读，不改行为**，2026-10-09）

- GOAL-006: 证明或证伪「`pick_clear_lane()` 只判目标车道最终安全，不判**从当前横向位置
  移动到目标车道的过程**是否穿过障碍」是不是 L4 剩余卡死的直接原因。

工具：`main.gd` 的 `_l4_transition_corridor / _l4_corridor_ladder / _l4_transition_report /
_l4_rate_sampler / _l4_summary_report`（全部只读，`[DEBUG-L4]` 前缀，可整块删除），
外加开发期分析器 `tools/l4_transition_report.py` + `tools/l4_transition_posthoc.py`。

| Task | Description | Completed | Date |
|------|-------------|-----------|------|
| TASK-024 | 实验 A（基线，代码 = HEAD `f0398f8`，未改一行）：`lap -Level 3` → 卡住 **4**，复位 5，222.0s / 3 圈 | ✅ | 2026-10-09 |
| TASK-025 | 实验 B（走廊诊断）：3 次实测，**撞击时刻 `transition_blocked` = 0/13、0/7、0/13** → **走廊假设被证伪** | ✅ | 2026-10-09 |
| TASK-026 | 实验 C（目标翻转）：切换 38 / 24 次，**间隔 median 3.47~5.13s**，切换时走廊受阻 **0** → **不是高频横跳**，commitment 本轮不做 | ✅ | 2026-10-09 |
| TASK-027 | 实验 P2（横向速率）：高速段中位 **0.011 m/m** → 挪 2m 需 ≈180m，而决策前瞻只有 45m | ✅ | 2026-10-09 |
| TASK-028 | 结论：根因是**反应距离 vs 实际横向执行速率**的算术不闭合，不是过渡走廊 | ✅ | 2026-10-09 |

**本轮结论**：计划 §20 的四种情况里落 **情况 D**（两者都不是）——
① 走廊在撞击时是通的；② 目标车道不是高频翻转。
真正的缺口是：**规划器假设「45m 内能完成任意横向位移」，而实测高速段只能以 0.011 m/m 横移。**

**未确证（不许当结论）**：高速段 0.011 m/m 是「控制器没打够舵」还是「打了舵车不响应」——
需要下一轮先只读打印 `steering` 实际值再定。

**下一刀**：见 `docs/testing.md` 的「2026-10-09 第四轮」§H。

## 8. Related Specifications / Further Reading

- `docs/testing.md` —— 「已知缺陷」一节（L4 AI 卡死、横向控制取证、探测盒 A/B）
- `docs/plans/p0-acceptance-contract-repair.md` —— 任务 5（L4 卡死，仍是 AI 侧未修好）
- `docs/plans/phase2-elevation-pipeline.md` §4.6 / §六 任务 10 —— 「验收自动驾驶改用 `racing_line`」（同一个函数，另一条缺口：**没有物理极限限速**）
- `docs/engineering-notes.md` 第 51、54、55、57、60 条 —— 诊断与判据的方法论
- `AGENTS.md` §2.3 / §4.2 / §5.3 / §8.2 / §10 / §18
