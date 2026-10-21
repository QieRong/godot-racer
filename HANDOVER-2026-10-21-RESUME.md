# 2026-10-21 恢复后交接

## 最新现场：默认回放 / 全量 / MCP

本轮用户已恢复任务并明确授权普通推送。音频生命周期修复 `01122df` 已推送 main。

- 首个合法候选已复制到本地默认目录；默认 aidiag 60/120 FPS 各 COMPLETE、10 条断言零失败、process/runner 0/0。
- 正常权限 full60 **20/20、runner exit 0**。full120 **19/20、runner exit 1**，phys 最低步频 117.18 Hz < 原门槛 118 Hz；最终 OUTCOME 为 COMPLETE / 1 FAIL，其余检查通过。不能说双档全绿。沙箱失败首跑/中止与环境探测分别封存。
- 当前新默认包仍绑定未提交 C 配置和工作区源码原始字节；五个 JSON 与 .gitattributes 草稿仍留在现场。本次归档候选及验证证据，未将其正式提交为远端默认包。不要手改 hash；资产/换行策略收口后再做干净检出重冻。
- 原 UI 源码保护复核 60/1、exit 1：menu.tscn 两行 UID 元数据变化；未回退用户文件、未放宽保护门。资产批次与依赖详见 `plan/review-p0-assets-20261021.md`。
- 90 分钟真人流程与空白表已就绪，尚未执行 U。历史随机 0xC0000005 未定位；AC-13 18-run、新包均未实测。严格大项仍 0/12。
- 用户追加 MCP 故障已恢复：原主服务 16506 拒绝连接，隐藏启动本机既有服务后编辑器自动连入；status=live、日志/版本真实读取成功。未重启编辑器、未改项目配置。运行助手尚未配置，不能说运行时发键已验证。

最新矩阵和复跑方式见 `plan/review-progress-20261021.md`；以下均为按版本保留的历史，旧暂停指令已被本轮明确继续撤销。

## 最新续做：P0-AUDIO-LIFECYCLE

用户已明确恢复并要求继续评审报告未完成项。基线 `e744884`。新增 `engine_audio_lifecycle_test.gd`：原实现 10 通过/6 失败 exit 1；`engine_audio.gd` 在音源离树时 stop + 清回执后 16/16 exit 0。finish_results / rel_final_finish_flow 双 FPS 4 次均 exit 0（各 57/57、67/67），未出现实例泄漏。详见 `plan/review-p0-audio-lifecycle-20261021.md`。

历史随机访问冲突修复前本轮也未复现，仍未定位，不能由上述结果销号；根证书错误保留。默认冻结带/用户既有 UI 音频资产此工单未修改。旧记录继续作为历史。

## 后续续做记录（2026-10-21，评审进度复核）

后续用户再次要求按本交接继续、控制 5h 额度并及时推送。开工 HEAD / 远端为 `fe6e422`。
最新进度与命令见 `plan/review-progress-20261021.md`，本节之后的旧记录保留为历史。

- 新 runner 的真实引擎 pause/aistart 双 FPS 共 4 次通过，engine / runner exit 均 0。
- countdown 场景双 FPS 各 29/29、exit 0；历史崩溃本轮未复现，**不能称已修**。
- finish_results：60 FPS 57/57 后访问冲突 exit -1073741819，红；120 FPS 57/57、exit 0。
- rel_final_finish_flow：60 FPS 67/67、exit 0；120 FPS 未到汇总即访问冲突，红。
- 默认 aidiag 带复现 INITIAL_STATE_CONTRACT_MISMATCH、2 条失败；进程超时被终止，新 runner 正确 exit 7。
- 以上 11 次运行合计 8 通过、3 失败；未做全量 20、AC-13 18-run、真人 U、新包。
- 独立新校准 exit 0：首个候选 5041 帧、数据有效；校准仍为 CALIBRATION_ONLY / 5 条失败。首个候选独立重冻成功，新清单 60 FPS 正式回放 COMPLETE、零失败、exit 0。原始全套证据与冻结包见 `godot-logs/resume-20261021b-freeze-evidence.zip` 及 SHA256；默认旧带未覆盖、尚未整合。
- 桌面评审第 8 章共 12 个大项：1 项代码修复落地待完整 T/U，1 项部分推进，10 项未完成；严格 C/T/U 闭环 0/12。详见进度矩阵，不把历史 50 分当完成率。
- 原有 UI/BGM/展车/冻结带等修改继续保留；本轮仅提交文档与指定实测证据，不改生产代码/阈值/系统设置。
- 用户随后明确“准备收尾暂停，最后记得 push”。现在只收尾推送；等待用户恢复，不再自行启动新测试或功能。

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
