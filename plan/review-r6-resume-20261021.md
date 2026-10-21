# REVIEW-R6 场景补验（2026-10-21）

基线：HEAD / 现场远端 main 均为 `af18744bcb8c81b01290b717bb3599d05ac95e33`。
用户要求继续原计时工单；保留原有 UI/BGM/冻结带等 15 项修改和未跟踪资产。
本次只新增测试，不修改生产代码、物理公式、阈值、Quick 15 / 全量 20 枚举。

## 规则与范围

- GO 即总时间和首圈起表，玩家不输入也起表；玩家和真实 AI 同步放行。
- ESC 事件通过真实 PauseMenu 暂停；暂停期间总时间、圈钟、双方位置冻结。
- ESC / 真实“继续游戏”按钮恢复，暂停等待不补计。
- 真实 AI 完赛信号进入 main 的记录入口，成绩扣除暂停。
- 玩家完赛信号进入结算、公开时钟与快照冻结；真实“再玩一局”按钮重开清零，再自然倒计时发车。
- 完赛采用信号注入，未驾驶完真实赛程；机器事件不是真人操作验收。

## 实施

新增 `godot-racer/tests/race_clock_scene_test.gd`（含 UID），独立 SceneTree 专项。
使用真实 main 场景、自然倒计时、Input.parse_input_event 的 ESC 按下/释放、真实菜单按钮。
首跑误取不存在的 `_pause_menu` 字段产生脚本错误；修正为实际 `PauseMenu` 节点。
失败日志 `r6-resume-scene-60-01.*` 留存，不能当产品红测。

命令模板（实际使用绝对工程/日志路径，日志逐次命名）：

```powershell
& E:\godot\Godot_v4.4.1-stable_win64_console.exe --headless --path .\godot-racer --log-file <唯一日志> --script res://tests/race_clock_scene_test.gd -- --render-fps=60
```

## 当前证据

| 项目 | 断言 / 进程 | 结论 |
|---|---|---|
| 新增场景专项 60 FPS | 41/41，exit 0 | 机器通过 |
| 新增场景专项 120 FPS | 41/41，exit 0 | 机器通过 |
| 既有倒计时场景 60 FPS | 29/29，但 exit -1073741819（0xC0000005） | **进程崩溃，不能记通过** |
| 后续倒计时 120、结算双 FPS、pause/aistart 等 | 批次因上述非零退出停止 | 未实测 |

最终新增专项日志：`godot-logs/r6-resume-race_clock_scene_test-60-03.{console,exit}.log`、
`godot-logs/r6-resume-scene-120-01.{console,exit}.log`。
60 FPS 两次 ESC 暂停的总时间与圈钟增量均 0.000；AI 墙钟 2.057s、成绩 0.779s，剔除 1.278s。
120 FPS 对应增量均 0.000；AI 墙钟 1.985s、成绩 0.685s，剔除 1.300s。
均存在系统根证书读取错误；最终 60 FPS 仍有 ObjectDB 退出泄漏警告，未归因为产品缺陷。

崩溃日志：`godot-logs/r6-resume-countdown_scene_test-60-03.{console,exit}.log`。
用户截图显示 Godot PID 14880 未处理 Win32 异常与 Visual Studio JIT 提示。
已确认日志末尾有 COUNTDOWN_SCENE_PASS，但真实退出码访问冲突；尚未证明根因，不能归咎于环境或写成已修。
已停止后续引擎批次。用户随后要求优先继续项目代码，不扩展本机调试器/系统设置排查。

## 状态与后续

C：计时代码已于 af18744 实现；T：44 条组件专项和本次双 FPS 场景专项通过，完整回归有崩溃未闭环；U：待真人验收。
全量 20、AC-13 18-run、完整真实圈速、真人录像、新包均未执行。
下一独立工单：runner 不再把失败/不完整日志报成功；之后再处理冻结输入带与退出崩溃。
回退：仅移除新增专项与本归档，不清理用户资产，不回滚已实现计时规则。
