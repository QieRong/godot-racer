# RUNNER-RESULT-001：检查失败必须传递（2026-10-21）

用户要求依据评审继续完善项目；REVIEW-R6 已复现 aidiag 测量失败却 exit 0，恢复时又出现倒计时 29/29 后访问冲突。
本工单仅修 Windows runner，不改 GDScript 物理、验收阈值、输入带、校准/冻结契约及 Quick/全量枚举。

## 规则

- `[CHECK] 完成` 只说明已到收尾，不等于验收通过；等待进程实际退出。
- 成功需 exit 0、完整且匹配检查名的最终 OUTCOME、COMPLETE、零失败及非空断言证据。
- 日志 ASSERT FAIL、脚本错误、缺失/破损证据、测量未建立、崩溃、超时或主动杀死均不通过。
- 跨场景重开使用最后 RUNID 段的断言计数；早先场景的失败不能被重开冲掉。
- 只有检查尚未开始的启动崩溃可沿既有 MaxTries 重试；已开始的失败不靠重试变绿。
- 校准产物保持 CALIBRATION_ONLY，不能充当正式验收通过。

影响：`04-Godot启动器/run-check.ps1`，新增只读日志判定模块及 Pester 进程替身回归。
退出码保留既有 2/3/4/5/6/8；新增 7 表示实际检查/进程/证据失败。
风险：旧的仅凭完成字样报绿结果会变红，属如实暴露；不为此调低判据。
人工验收：该脚本无新增玩家 UI；游戏 U 仍待真人。回退限本工单文件，不清理工作区。

## 已实施与实测

- 原实现配新增的首批 12 条进程替身测试：2 通过、10 失败（工具输出留证）；覆盖真实 runner 控制流，替身只替代引擎进程。
- 修复后同批 12/12；补入启动重试留证、超时/主动终止/缺退出码守卫后，新专项 14 条。
- 启动器目录 Pester 回归合计 **26/26**（新增 14 + 既有 parse 3 / 调度 1 / tape 8），进程 exit 0。
- 将进程收尾等待限制为 5 秒后，新专项复跑 **14/14**、exit 0，报告 `godot-logs/runner-result-20261021-final.xml`。
- 报告：`godot-logs/runner-result-20261021-pester.xml`；Pester 报告环境采集调用 CIM 被拒，但 XML 仍写出，测试结果不受影响，不改系统权限。
- 使用本地保留的真实 aidiag 故障日志运行新判定：ASSERT_FAIL、INPUT_EVIDENCE_INCOMPLETE、OUTCOME_ASSERTIONS_FAILED，返回 Passed=false。
- 对历史 pause/aistart 日志做兼容性读取均 Passed=true；只证明解析兼容，不是当前版本回归通过。
- PowerShell 语法解析、两道文档闸门通过；Quick/全量枚举仍为 15/20。
- 没有重新启动 aidiag/全量引擎测试，没有重冻带；新 runner 对当前真实引擎的完整链路仍待执行。

## MCP 现场状态

Godot MCP live 连接 `D:/桌面/DSH-Work/data-analysis/godot-racer/`；新增计时场景脚本 validate_script valid=true。
通过 MCP 启动真实 main 场景，started=true；编辑器 get_errors 返回 0，随后主动停止。
`MCPRuntime` autoload 缺失，runtime_connected=false，所以未通过 MCP 注入按键或读取运行节点；没有擅自修改 project.godot 注册运行助手。
这不替代 ESC 计时专项或真人 U，也不证明退出崩溃已解决。
