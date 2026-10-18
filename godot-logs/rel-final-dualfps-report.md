# Windows 首版 · 60/120 FPS 长时跑圈验收

- 日期：2026-10-18（Asia/Shanghai）。
- 被测生产基线：`518b8e59712da709d6c02a4e8aacc0d13776b6ad`；开始和结束时生产脚本、场景、关卡配置均未修改。工作区**不干净**：玩家 README 有未提交改动，新增测试脚本未跟踪。故本报告是该生产 blob 在当前工作区的实测，**不是干净提交快照的复跑**。
- 引擎：Godot 4.4.1；物理固定 120 Hz；`-RenderFps` 分别覆盖 60 / 120，仅改变渲染上限。
- 执行：先 60 FPS 的 `lap -Level 3`、`opponents -Level 3`、`opponents -Level 4`，再按相同顺序跑 120 FPS；每组各 3 次，严格串行。每次均经过 `run-check.ps1` 的 lint 与 parse preflight，独立原始日志见表末文件名，`godot-logs/rel-final-dualfps-progress.csv` 留有进程退出码。18 次均为第 1 次尝试通过，退出码 0。
- 判定：必须见到完整圈数、对应 `✔` 断言及 `[CHECK] 完成，退出`，且无 `✘`/脚本解析错误。两档使用同一判据。

## 逐次结果

| 渲染 FPS | 检查 / 关卡 | 次数 | 圈数 | 总时长 s | 最快圈 s | 卡住 | 复位/自救 | 碰撞 | 结论 | 原始日志（均在 `godot-logs/`） |
|---:|---|---:|---:|---:|---:|---|---|---|---|---|
| 60 | 玩家 L4 | 1 | 3 | 138.0 | 45.168 | 0 | 0 复位 | 未计量；冲击候选 1 | PASS | `rel-final-dualfps-lap60-p1.log` |
| 60 | 玩家 L4 | 2 | 3 | 137.9 | 44.970 | 0 | 0 复位 | 未计量；冲击候选 1 | PASS | `rel-final-dualfps-lap60-p2.log` |
| 60 | 玩家 L4 | 3 | 3 | 138.0 | 44.613 | 0 | 0 复位 | 未计量；冲击候选 1 | PASS | `rel-final-dualfps-lap60-p3.log` |
| 60 | 对手 L4 | 1 | 1 | 67.4 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL4-60-1.log` |
| 60 | 对手 L4 | 2 | 1 | 69.0 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL4-60-2.log` |
| 60 | 对手 L4 | 3 | 1 | 66.5 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL4-60-3.log` |
| 60 | 对手 L5 | 1 | 1 | 87.7 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL5-60-1.log` |
| 60 | 对手 L5 | 2 | 1 | 87.7 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL5-60-2.log` |
| 60 | 对手 L5 | 3 | 1 | 88.6 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL5-60-3.log` |
| 120 | 玩家 L4 | 1 | 3 | 138.0 | 44.586 | 0 | 0 复位 | 未计量；冲击候选 1 | PASS | `rel-final-dualfps-lap120-p1.log` |
| 120 | 玩家 L4 | 2 | 3 | 138.0 | 44.605 | 0 | 0 复位 | 未计量；冲击候选 1 | PASS | `rel-final-dualfps-lap120-p2.log` |
| 120 | 玩家 L4 | 3 | 3 | 137.9 | 44.836 | 0 | 0 复位 | 未计量；冲击候选 1 | PASS | `rel-final-dualfps-lap120-p3.log` |
| 120 | 对手 L4 | 1 | 1 | 66.3 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL4-120-1.log` |
| 120 | 对手 L4 | 2 | 1 | 66.4 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL4-120-2.log` |
| 120 | 对手 L4 | 3 | 1 | 66.4 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL4-120-3.log` |
| 120 | 对手 L5 | 1 | 1 | 87.7 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL5-120-1.log` |
| 120 | 对手 L5 | 2 | 1 | 87.7 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL5-120-2.log` |
| 120 | 对手 L5 | 3 | 1 | 87.6 | 未计量 | 未计量 | 0 自救 | 未计量 | PASS | `rel-final-dualfps-oppL5-120-3.log` |

`lap` 的卡住/复位是验收脚本的直接计数。`opponents` 只采集最小完成圈数和 `rescue_count`，不单独输出卡住、复位或碰撞次数；表中的“未计量”不可解释为 0。`[DEBUG-L4] IMPACT` 是玩家速度单帧骤降的**冲击候选**，并非物理碰撞回调或真实碰撞计数。对手最快圈也未由此检查输出。

## 雪地 100 km/h 制动边界

原始测量：`godot-logs/rel-final-dualfps-snowbrake-bench.log`，有效格 12/12。40、60、80、100 km/h 三次 `a_brake` 分别为 `12.03/12.05/12.11`、`11.76/11.75/11.75`、`12.23/12.23/12.23`、`11.43/11.43/11.42` m/s²。100 km/h 档低于 60/80 档，存在非单调的极端制动表现；测量时车辆能刹停，100 km/h 有效下界 11.42 m/s²，约为抓地容量 13.73 m/s² 的 83%。

`godot-racer/scripts/ai_opponent.gd` 的 `PROBE_ROLLING_DECEL` 为 11.3 m/s²，规划值比上述实测最低值低 0.12 m/s²（约 1%）。L5 对手在 60 和 120 FPS 各三次均独立完成一圈、0 自救、未出界。**结论：首版交付的可接受边界，列为 CONCERNS，不判作已消失的非线性现象，也不需在本轮修改控制律或判据。** 余量很小，未来若变更轮胎、模板或 AI 速度模型，必须重新测量和验收。

## 总判定

**PASS（附 CONCERNS）**：60 与 120 FPS 各 9 次全部按原判据通过，玩家无卡住/复位，对手均 1 圈/0 自救/未出界。CONCERNS 为雪地高速制动非单调，以及对手检查未采集独立碰撞、卡住和最快圈；这些未计量字段没有被写成零。主观驾驶手感、音频听感和干净 Windows 首启不属于本报告的实测范围。
