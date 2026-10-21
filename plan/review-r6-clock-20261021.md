# REVIEW-R6：比赛计时修复与暂停交接

状态：**用户选择先拆分后修复，现已实施；计时专项 44/44 通过，完整场景及双帧率回归待续。用户随后要求暂停并推送。**

## 目标与边界

- 用户本轮明确：3、2、1 倒计时结束即起表；不等车辆移动、首次压线或 GO 提示收起。
- 保留 GO 时总时间与互动首圈同原点；保留按住 W 不吞键、首次压线只标记。
- 已实现：暂停、退出确认不计入成绩；结算后时钟冻结；返回首页和新局清掉旧时钟状态。
- 只涉及比赛计时，不改车辆控制、AI 策略、赛道、关卡字段、阈值或 Quick/全量枚举。
- 失焦自动暂停是另一项体验规则，本工单暂不新增；景观、PB、Excel、视频与打包另排工单。

## 当前基线（本轮现场核查）

- 仓库：`D:/桌面/DSH-Work/data-analysis`。
- HEAD 与 fetch 后 origin/main：`09c0783563a90ea75eee86fcdc556aa477a62259`。
- 开工状态：15 项修改、42 项未跟踪入口，展开后共 63 个文件条目；已有 UI、展车、BGM、冻结带及音频诊断工作。
- 引擎：本机控制台程序返回 `4.4.1.stable.official.49a5bc7b6`。
- 开工行数债务：`ai_opponent.gd` 1686；`vehicle.gd` 1021。车辆已先拆分至 951 行，拆分提交 `bb62498`。
- 本轮未修改上述已有工作；未清理素材或重新冻结输入带。用户现已明确要求推送本轮修改，原有未验收改动不混入提交。

## 实测与判据

独立测试：`godot-racer/tests/race_clock_review_test.gd`。不挂入既有 runner，不改变 15/20 项口径。

```powershell
pwsh -NoProfile -File .\04-Godot启动器\lint-gdscript.ps1
pwsh -NoProfile -File .\04-Godot启动器\parse-check.ps1 -Scripts res://tests/race_clock_review_test.gd -MaxTries 1
& E:\godot\Godot_v4.4.1-stable_win64_console.exe --headless --path .\godot-racer --log-file ..\godot-logs\review-clock-unique.log --script res://tests/race_clock_review_test.gd
```

实际运行使用了绝对工程/日志路径。重跑时使用新的唯一日志名，保留旧证据。

- lint：通过，退出码 0（本轮是引号与批处理行尾门，不等同于通用静态分析）。
- 测试脚本 parse-check：通过，退出码 0。
- 原实现运行：**24 PASS / 20 FAIL，`RACE_CLOCK_REVIEW_FAIL`，进程退出码 1**。
- 第一次暂停约 0.6 秒：总时间增长 0.599 秒，本圈增长 0.600 秒；恢复瞬间仍含这段增量。
- 活跃比赛约半秒，经多次暂停与退出确认，AI 完赛记录和本圈均约 3.539 秒，结算 total 约 3.540 秒。
- `total == sum(laps)` 在坏实现中仍通过，证明它只能作为一致性辅助守卫。
- 结算后公开总时间继续增长约 0.613 秒；返回首页后总时间未清零。
- 无 `SCRIPT ERROR`；headless 启动出现系统根证书读取错误，属环境记录，不冒充无错误全绿。

证据：

- `godot-logs/review-20261021-clock-red-01.log`
- `godot-logs/review-20261021-clock-red-01.console.log`
- `godot-logs/review-20261021-clock-red-01.exit.log`

测试直接使用真实 `GameState`、车辆圈钟/过线方法及 AI `record_finish()`；它是计时组件复现，**不是实际驾驶跑圈或完整倒计时场景验收**。测试内总时长上界用于本机快速复现，尚未纳入正式契约。

## 最小修复（已在独立拆分后应用）

最初评审稿：`godot-logs/review-20261021-r6/R6-proposed.patch`，仅作本地历史草稿；最终 diff 以本工单提交为准。

| 文件 | 计时修复前 → 后行数 | 改动 |
|---|---:|---|
| `godot-racer/scripts/game_state.gd` | 473 → 512 | 单一 `race_clock_ms()` 扣暂停量；暂停/继续/退出确认/完赛/新局接入；更正与 GO 同原点现状矛盾的旧注释 |
| `godot-racer/scripts/vehicle.gd` | 951 → 951 | 仅将 4 个圈钟读取点由墙钟替换为同一比赛时钟；不动控制公式、脱困隔离墙钟、`await` 或计圈规则 |

保留现有 `begin_lap_timing(go_ms)` 参数和内部圈钟锚点，以缩小改动和回归面。自动化旧路径仍在首次压线开始圈钟；互动路径仍在 GO 开始。

## 本轮用户决定

1. 用户重申：倒计时结束即起表，玩家不动也起表；玩家按键盘左上角 ESC 时，玩家和 AI 的计时都暂停。
2. 用户选择“先单独拆分车辆脚本，再修计时”。已先完成 `SPLIT-VEHICLE-001`，无需启用 1021 行临时例外。
3. 用户最后要求“现在可以暂停一下，并push到github”。停止后续开发和长时回归，仅整理、提交与推送本轮已实现部分。

## 修复后的现场验证

- 拆分后、修计时前，同一最终测试重新跑红：24/44 通过、20 失败，退出码 1；日志 `review-20261021-clock-red-postsplit-01.*`。
- 修复后：**44/44 通过、0 失败、`RACE_CLOCK_REVIEW_PASS`、进程退出码 0**；日志 `review-20261021-clock-green-01.*`。
- 暂停与恢复瞬间总时间/本圈增量均为 0.000 秒；退出确认与嵌套暂停同样为 0.000 秒。
- 活跃比赛约 0.516 秒、另有约 3 秒暂停等待：AI 完赛与本圈约 0.516 秒，结算 total 约 0.517 秒。
- 结算后总时间与本圈增量均 0.000；返回首页清零、新 GO 重新起算通过。
- 修复后 lint 与 53 个源码聚合 parse 通过，退出码均为 0；日志 `review-20261021-clock-lint.log`、`review-20261021-clock-parse.log`。
- 启动仍有系统根证书读取环境错误，无相关 `SCRIPT ERROR`。不据此宣称整个游戏无错误。

## 恢复后的验证与回退

待续：修复后真实倒计时场景、结算/重开场景、真实 ESC 输入路径的 pause、aistart 和 60/120 FPS 回归。本轮通过的是直接调用真实状态机与计时组件的独立专项，**不是按下真实 ESC 的完整游玩验收**。AI 冻结带绑定已受车辆源码变化影响，不能把旧带结果当作新代码验收；需先修 runner 假绿，再校准/冻结。

回退仅撤本工单逐行补丁，保留所有原始红测与用户已有工作，不使用 reset/clean/stash。

C：代码已实现；T：计时专项通过、完整回归未实测；U：真人体验未实测。项目全量 20 项、AC-13 18-run 矩阵均未在本轮执行。

## 另一条已现场复现的 P0：aidiag 假绿

独立命令：

```powershell
pwsh -NoProfile -File .\04-Godot启动器\run-check.ps1 -Check aidiag -MaxTries 1 -SkipLint -LogName review-20261021-aidiag-baseline-01
```

本次预检显示 FROZEN，但引擎内报 `INITIAL_STATE_CONTRACT_MISMATCH`，两条 `ASSERT` 失败，`OUTCOME.failed_assertions=2`、`measurement_status=INPUT_EVIDENCE_INCOMPLETE`，外层仍退出 **0**。

日志：`godot-logs/review-20261021-aidiag-baseline-01.log`。本轮只确认问题；runner 修复和重新校准/冻结作为下一独立工单，不混入本计时补丁。运行还出现 shader 缓存、系统根证书及 user 设置目录的环境报错/警告，均保留在原始日志。

## 报告其余事项的执行顺序

| 顺序 | 工作 | 本轮状态 |
|---|---|---|
| P0-1 | GO 起表基础上的暂停停表 | 代码已实现、专项 44/44；完整场景/双帧率与 U 待续 |
| P0-2 | runner 如实传递失败，再校准/冻结 aidiag | 假绿已复现；未修 |
| P0-3 | 逐批审核既有 UI/展车/BGM 改动与提交边界 | 仅盘点，未代替他人工作提交 |
| P0-4 | 真人完整流程/暂停/重开与录像 | 未实测，须真人参与 |
| P1 | 障碍可读性、景观、车辆涂装、音效/加载 | 未实施，逐个小工单确认 |
| P2 | L1/L2 路线、PB、Excel、视频与新交付包 | 未实施；不得编造试玩或数值证据 |
