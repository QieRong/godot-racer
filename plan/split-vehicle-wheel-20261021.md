# SPLIT-VEHICLE-001：车辆车轮视觉模块等价拆分

用户于 2026-10-21 在本轮明确选择“先单独拆分车辆脚本，再修计时”。本工单是第一步，不包含计时口径修复。

## 规则与影响

- 将车轮查找、视觉网格绑定、网格转向/自转迁入 `scripts/vehicle_wheel_visuals.gd`。
- 保留 `vehicle.gd` 的两个调用入口、`_wheel_visuals` 状态、初始化位置和物理帧内调用顺序。
- 新模块通过参数接收车辆与条目，不引入 `class_name`、新节点、信号或 `await`。
- 动力、转向控制、恢复、赛道、计圈与时钟不改。无新依赖或资源替换。
- `vehicle.gd`：**1021 → 951 行**；新增视觉模块 **83 行**。另一项历史债务 `ai_opponent.gd` 1686 行仍存在。

## 现场证据

基线 HEAD：`09c0783563a90ea75eee86fcdc556aa477a62259`；验证针对本工作区，已有 UI/展车/BGM 等未提交内容不包含在本工单中。

| 检查 | 结果 | 证据 |
|---|---|---|
| 原实现真实模型视觉用例 | 15/15，退出码 0 | `godot-logs/review-20261021-wheel-before-01.*` |
| 拆分后同一套用例 | 15/15，退出码 0 | `godot-logs/review-20261021-wheel-after-01.*` |
| A/B 数据比较 | 12 个网格、108 个 basis 分量完全相同 | 两份 console.log 的 `WHEEL_VISUAL_SAMPLE` JSON |
| 核心函数逐字比较 | `_physics_process` / `_update_drive` / `_update_steering` / `_on_lap_crossed` / `_check_recovery` / `reset_to_track` 六函数不变 | 对 HEAD 与工作区函数正文比较 |
| await 数 | 3 → 3 | 对 HEAD 与工作区实际 await 语句计数 |
| 引号/行尾 lint | 通过，退出码 0 | `godot-logs/review-20261021-split-lint.log` |
| 全量源码 parse | 53 个源码聚合解析通过，退出码 0 | `godot-logs/review-20261021-split-parse.log` |
| 真实倒计时/同步发车场景 | 29/29，`COUNTDOWN_SCENE_PASS`，退出码 0 | `godot-logs/review-20261021-split-countdown-01.*` |

视觉专项冻结真实车辆，速度/转角只作为动画的确定性输入；它不代表实车运动或物理验收。启动时出现系统根证书读取环境错误，未出现脚本错误。无真人驾驶/视觉 U 认可；未运行全量 20 项或 AC-13 18-run 矩阵，不宣称全项目全绿。

复跑入口：

```powershell
& E:\godot\Godot_v4.4.1-stable_win64_console.exe --headless --path .\godot-racer --script res://tests/vehicle_wheel_visuals_test.gd --log-file <新的绝对日志路径>
& E:\godot\Godot_v4.4.1-stable_win64_console.exe --headless --path .\godot-racer --script res://tests/countdown_scene_test.gd --log-file <新的绝对日志路径>
```

代码已实现、所列专项机器通过；真人体验未实测。后续单独修复 GO 起表后的暂停计时，并保留本次迁移前后证据。
