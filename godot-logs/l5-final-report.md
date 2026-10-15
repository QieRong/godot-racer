# BUG-L5-001 修复回执（2026-10-15）

## 改动与根因

旧 probe 把瞬时余隙二次式当作制动模型：10m 处目标仍为 115.2km/h；0.8m 处目标为 0，
形成无法自行补油的固定点。即使改了目标，执行层的 3m/s 巡航超速死区仍会只给 1.2 怠速制动。

- racing_line.gd 增加纯函数 probe_speed_limit_kmh，二分反查既有 brake_distance，核心制动公式仍只有一份。
- probe 的调整地板为 6km/h；其它物理限制更低时继续取更低限制，不抬高天花板。
- 制动距离耗尽时跳过巡航死区，切断动力，probe 紧急分支使用与台架相同的制动力 30。
- 对应模型参数为 11.3m/s²，低于 L3/L4/L5 台架最低有效格均值 11.39。
  这是对“实际施加 30”的标定，没有线性外推 AI 55 的雪地能力。
- 复核又抓到旧巡航分支在 100km/h 时可给出 52.22；新增失败检查后，probe 分支固定为标定强度 30。

## TDD 与验收边界

分四步先红后绿：近障碍地板、10m 处提前减速、绕过执行死区、固定标定制动力。
最终补充检查共 19 条，还覆盖限速单调、刹车距离约束、较低物理上限、无障碍和较低减速度。
运行入口为 tools/test_probe_braking.gd，不新增 --check 项，不修改现有验收阈值。

生产代码的最终哈希由 l5-final-run.ps1 在冷启动前复核，恢复脚本在补跑前后再次复核：

```text
Baseline: f78882d82a4cd7ddc83bee2366a0089a048adb02 + 本批工作区改动
ai_opponent.gd blob: fe38b674492b7f15c173030dd65409dd93f84ab5
racing_line.gd blob: 39cea821f4fb6ccc0f2f76b7a01e4686d58a0a9e
```

这是上述基线加修复工作区的实测，不冒称干净提交上的复跑；最终内容提交与上述生产 blob 绑定，
实际提交号和远端相等检查写在 docs/push-log.md。

| 检查 | 实测结果 | 证据 |
|---|---|---|
| lint / parse / docs / readme / dup-source 五道闸门 | 全部 EXIT=0；解析 32 个 .gd | l5-final-对应闸门.log |
| opponents L5 三次独立冷启动 | 3/3 PASS，均 1 圈、0 自救、未出界 | l5-final-opponents-1/2/3.log |
| 补充行为检查 | 19/19，PROBE_FAILURES=0，EXIT=0 | l5-resume-unit.log |
| Quick 完整补跑 | 15/15，EXIT=0 | l5-resume-quick.log |
| aidiag L1 | AI 诊断通过，目标速度最大 129.8、贴限速 63.7%，EXIT=0 | l5-resume-aidiag-l1.log |
| 串行补跑完成标记 | unit / Quick / aidiag EXIT=0，DONE | l5-resume-progress.log |

原 l5-final-quick.log 在第 10 项附近中断，没有完整结果；l5-final-progress.log 因此没有 DONE。
这些原始记录保留，不当作通过。用户返回后确认生产 blob 未变，完整补跑 Quick 与 L1 AI 诊断，
恢复脚本记录为 DONE。未为绿灯修改任何现有判据或阈值。

Godot MCP 已连接正确工程；ClassDB 核对了 VehicleWheel3D 制动属性，两份生产脚本的 MCP
语法校验 valid=true。MCP 回执 can_instantiate=false，只作为语法诊断；CLI 解析和真实运行是验收依据。
本轮没有阻塞性 MCP 故障，未修改插件。自审未发现阻塞性新增问题，未声称做过外部人工评审。

已完成的最终冷启动：11323 / 11331 / 11321 帧，三次均 1 圈、自救 0、未出界。
实机截图 l5-final-arc805.png：AI 到达 arc 805.15m（越过原卡点 789.2–789.7），
速度 41.69km/h、自救 0，车身位于路面。截图夹具只起步并切换相机目标，
不改车辆位置/速度/控制。左上角 HUD 仍显示静止玩家的 0km/h，AI 速度取自同帧 VISUAL 日志。

## 保留的边界

- L4 横向控制未改，原已知缺陷保持登记；雨声接线未实施。
- 雪地 100km/h 的抱死非线性仍需单独评估；本次验收针对默认 L5 关卡的 BUG-L5-001。
- 整套 20 行未全量重跑；L4 opponents、长时 lap/stress 未跑：用户限定收尾 L5，已做专项三跑、Quick 与 L1 AI 诊断。
- ai_opponent.gd 是 AGENTS 中已登记的历史超限文件，本批仅做修复性增量（1668→1682 行），未为凑行数重构。
- 接到用户“完成 L5 后暂停”的指令；本批收尾推送后停止项目工作。
