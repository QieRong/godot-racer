# 2026-10-21 恢复后交接

开工本地 / 现场远端 main 为 `af18744`。用户明确“继续”，并要求优先推进项目代码；Godot MCP 已连接。

## 本次落地

- `73fa808`：新增真实 main 场景计时专项，60/120 FPS 各 41/41、exit 0；自然倒计时、ESC 事件、继续按钮、真实 AI 记录链、结算冻结、重开清零。完赛为信号注入，不是完整驾驶或真人验收。
- 本交接所属 runner 修复：等待实际进程退出、核验最终 OUTCOME/ASSERT；失败、测量不完整、崩溃、超时不能报成功；仅启动未进入检查时可重试，保存每次启动日志。
- 新 runner 专项首批从 2/12 → 12/12；新增守卫后启动器合计 26/26，NUnit 报告在 `godot-logs/runner-result-20261021-pester.xml`。
- 真实旧 aidiag 失败日志由新解析器正确判为失败。历史 pause/aistart 日志可兼容解析，但不当作当前回归通过。

## 必须保留的红项与边界

- 既有 countdown 场景 60 FPS 输出 29/29 后，进程 exit -1073741819（0xC0000005）；用户看到 Visual Studio JIT 提示。**未修复、不能记绿**。
- 用户要求继续项目代码后，未继续展开退出崩溃与本机调试器排查。后续 countdown120、finish双 FPS、pause/aistart 等当前引擎回归未实测；全量20、AC-13 18-run、新包、真人 U 未做。
- 新场景专项启动有根证书环境错误；最终60 FPS还有ObjectDB退出泄漏警告。未把所有异常归为环境。
- aidiag 冻结带仍是原工作区版本，绑定失效问题未处理；没有校准/重冻/更改阈值。
- MCP live 项目正确、脚本语法校验通过，main启动后 get_errors=0，已停止；运行助手 MCPRuntime autoload 未注册，所以未用 MCP 发键或读运行节点，也未修改 project.godot。
- `ai_opponent.gd` 历史超限仍待单独拆分，本次没修改。

## 下一最小工作

先用修复后的 runner 做真实引擎专项，保留非零退出；之后按现有契约处理 aidiag 校准/冻结，再收尾计时相关回归和真人试玩。
不要扩展路线/Excel/美术大换风格，也不要把原有UI/BGM资产顺手一起提交。

## 文件与工作区

详见 `plan/review-r6-resume-20261021.md`、`plan/runner-result-20261021.md`。
原有15项修改及未跟踪UI/BGM/展车/音频/冻结带素材继续保留；只提交本轮指定测试、runner、文档和指定证据。
不使用 reset/clean/stash、无release/强推。推送结果以当轮最后的远端 hash 与0/0核验为准。
