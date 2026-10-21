# 2026-10-20 评审任务进度复核（2026-10-21）

## 后续续做：P0 音频生命周期

承接 `e744884`，修复音源离树后仍持有回执且未停止播放的缺陷。新测试先红 10/6 exit 1，再绿 16/0 exit 0；结算内容及结算/退出链双 FPS 分别各 57/57、67/67，4 次均 exit 0、无实例泄漏。详见 `review-p0-audio-lifecycle-20261021.md`。

**历史访问冲突在本轮修复前也未复现，仍未定位，不能写已修。** 此次只是 P0 机器验证增量；12 项三门关闭数量暂不增加。后文为前轮证据，保留原红项和统计口径。

原报告：`D:/桌面/项目进度评审报告-20261020.md`，基线 `09c0783`。
本次开工 HEAD / 现场远端 main：`fe6e422f74ad2d41db33d0b6c7f4f07fc54d7c64`。
本次测试绑定上述 HEAD **加原有脏工作区**，不代表干净提交或导出包验收。
用户要求按交接续做、控制剩余额度并及时普通推送；只提交本轮证据与文档。

## 数量口径

按原报告第 8 章的三级建议标题计，共 **12 个大项：P0 3、P1 6、P2 3**。
另有技术债、TOP9 细节和七项设计决策，与大项存在重叠，不叠加进分母。

- **1 项已落地、待完整回归与真人验收**：暂停计时修复。
- **1 项部分推进**：第二个 P0 中 runner 假绿修复已落地；原有资产分批提交及默认冻结带仍未收尾。
- **10 项未完成**：真人试玩、6 项 P1、3 项 P2。
- 以 C/T/U 全部关闭为“完成”，目前这批新增任务为 **0/12**；这不表示项目已有功能为零。
- 若只问代码修复落地数量，是 **1/12（8.3%）+ 1 项部分推进**，不能称项目总体完成率。
- 原报告综合评分 **50/100 是历史评审分，不是任务完成率**；本轮不凭测试条数重打综合分。

| ID | 原报告任务 | 当前状态 / C-T-U | 已核实证据 / 剩余工作 |
|---|---|---|---|
| P0-1 | 裁决并修复暂停不冻结计时 | 已实现；T 部分通过；U 待验 | `af18744` 权威比赛时钟；组件 44/44，`73fa808` 双 FPS 真实 ESC 场景各 41/41。本轮 pause/aistart 双 FPS 通过；退出崩溃及完整回归仍未闭环 |
| P0-2 | 分批提交 + 修假绿 + 重新冻结 | 部分推进 | `fe6e422` runner 修复、Pester 26/26；真实引擎成功/失败链已验证；首个新候选独立冻结及 60 FPS 正式回放通过。UI/BGM/展车/音频旧资产仍未提交，默认带未替换，完整回归未完成 |
| P0-3 | 90 分钟结构化真人试玩 | 未完成，U 未验 | 机器事件与截图均不能替代真人；无新增真人录屏/认可 |
| P1-1 | 障碍配色、棋盘格、提前提示 | 方案待确认 | 未实施；不改障碍种类、碰撞或阈值 |
| P1-2 | 7 个 GLB 景观接入、chevron | 未完成 | 未新增 scenery_spawner 或景观接入 |
| P1-3 | AI 车辆涂装、天气粒子柔边 | 未完成 | 未实施 |
| P1-4 | 护栏明度差、亮条与立柱 | 方案待确认 | 未实施 |
| P1-5 | 路肩路缘、结算玩家行高亮 | 未完成 | 未实施 |
| P1-6 | L1/L2 真实路线差异化 | 未完成 | 未改路线/关卡契约 |
| P2-1 | 计时挑战、PB、奖牌 | 未完成 | 未新增模式或持久化 |
| P2-2 | Excel 数值管线 | 未完成 | 仍为规划，未新增工作簿 |
| P2-3 | 新 Windows 包、视频、外部试玩 | 未完成 | 本轮未导出、录制或招募试玩 |

## 本轮真实引擎验证

环境：Windows / Godot `4.4.1.stable.official.49a5bc7b6`；渲染档位 60/120，物理固定 120 Hz；物理测试串行。
证据前缀：`godot-logs/resume-20261021b-`。所有失败首跑原样保留，未通过重跑抹红。

| 检查 | 60 FPS | 120 FPS | 边界 |
|---|---|---|---|
| run-check pause，Level 2 | PASS，engine/runner exit 0 | PASS，engine/runner exit 0 | 最终 OUTCOME COMPLETE、断言计数完整、零失败；验证暂停/重开，不代替专用计时断言 |
| run-check aistart，Level 2 | PASS，engine/runner exit 0 | PASS，engine/runner exit 0 | 玩家零输入、AI 同步发车；最终证据完整 |
| countdown_scene_test | 29/29，exit 0 | 29/29，exit 0 | 历史倒计时访问冲突本轮未复现，原因未明，不能宣布修复 |
| finish_results_test | 57/57 后 exit **-1073741819**，FAIL | 57/57，exit 0，PASS | 60 FPS 为 0xC0000005，不能只看 FINISH_RESULTS_PASS |
| rel_final_finish_flow_test | **67/67，exit 0，PASS** | 未到最终汇总即 exit **-1073741819**，FAIL | 补证原评审“67/67 待核实”；120 FPS 仍红 |

六次 SceneTree 专项最终 **4 通过 / 2 失败**（批次 exit 1），加四次 runner 正常专项，共 **8 通过 / 2 失败**。不能称结算双 FPS 或全套回归通过。
另做默认带 aidiag 60 FPS：`INITIAL_STATE_CONTRACT_MISMATCH`、2 条 ASSERT FAIL、最终 `INPUT_EVIDENCE_INCOMPLETE`；进程未退出至 220 秒超时，被 runner 终止（PROCESS_EXIT=-1，KILLED/TIMED_OUT=true），runner **exit 7** 正确报红。加此项为 **8 通过 / 3 失败**。
静态绑定核对：main、vehicle、game_state、project 四项 hash 不匹配；autopilot、race_car 场景匹配。preflight 只证明文件自洽，不能证明运行绑定有效。
lint 扫描 77 个 .gd 通过、源码聚合 parse 53 个通过；两道文档闸门 exit 0。保持 Quick 15 / 全量 20 枚举。
场景断言中的完赛有信号/状态注入，未完整驾驶赛程，不代表 U 或 AC-13 长时回归。
日志保留根证书错误、部分 ObjectDB 泄漏警告，以及图形 runner 的 shader 缓存目录错误，未把崩溃统一归因于环境。

复跑示例（请换新日志名，避免覆盖本次证据）：

```powershell
pwsh -File ./04-Godot启动器/run-check.ps1 -Check pause -Level 2 -RenderFps 60 -MaxTries 1 -LogName <新名称>
& E:/godot/Godot_v4.4.1-stable_win64_console.exe --headless --path ./godot-racer --log-file <新日志绝对路径> --script res://tests/finish_results_test.gd -- --render-fps=60
```

## 额外技术债与下一步

报告提到的两项超限债已有一项整改：`bb62498` 将 vehicle.gd 从 1021 拆至 951 行，wheel_visuals 83 行；不是新玩法任务完成。
ai_opponent.gd 仍待独立拆分；本轮没有修改生产 GDScript、物理公式、阈值或已有 UI/BGM 资产。

优先收尾 aidiag 的校准/冻结/正式回放并保留全过程，再单独处理退出访问冲突；完整 20、AC-13 18-run、真人 U、新包均未实测。
禁止从本次局部通过推断全库全绿，禁止将脏工作区证据绑定成干净提交验收。

## 校准与独立重冻的最终结果

用户要求准备收尾暂停；本轮不再启动下一专项。

- 原参数不变，仅刷新源码绑定；首次校准 headless / 60 FPS，exit 0，候选 5041 帧、无输入错误、无待核销回执。
- 校准结果为 **CALIBRATION_ONLY，12 条断言中 5 条失败**；不得算正式通过，未据 AI 成绩调参或挑选候选。
- 完整时序登记首个候选，使用已有全赛道几何预审（几何 hash 一致），`ai-tape-freeze.py` exit 0；新包位于 `godot-logs/resume-20261021b-frozen/`，未覆盖默认冻结带或原素材。
- 新包 headless / 60 FPS 正式回放：**COMPLETE、零失败、断言证据完整、process exit 0**，经 `Get-CheckResult` 判 Passed=true。
- 此为独立清单一次正式回放，不代表默认 runner、双 FPS、18-run 或干净提交全量验收。旧默认带仍失效；后续整合 UI/project.godot 后需重新确认绑定。
- 校准、候选、完整时序、冻结文件、正式回放与进程收据封装在 `godot-logs/resume-20261021b-freeze-evidence.zip`，附 SHA256。使用 ZIP 保留原始字节，避免 Git 换行转换破坏哈希；解压后各文件保持相邻，冻结清单在同名 frozen 子目录。
- 本轮 11 次既有专项为 8 通过 / 3 失败，另有新冻结带正式回放 1 次通过；校准另列，不计入正式通过数。

工程进展是 **暂停计时修复落地 + 假绿修复落地 + 新候选独立冻结/单次回放通过**。按原报告 12 个完整大项仍为 1 项落地待闭环、1 项部分推进、10 项未完成；严格三门通过仍是 0/12。
暂停后等待用户明确恢复；不自行启动长时测试、UI/资产提交、下一功能或导出。
