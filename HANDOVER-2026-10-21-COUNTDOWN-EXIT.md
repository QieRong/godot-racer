# 新对话交接：五关准备文字与退出资源（2026-10-21）

> 后续已完成一次续做并分批提交；本文件下文是前轮原始交接，不覆盖新证据。最新入口为 `HANDOVER-2026-10-21-EXIT-DRAIN.md`，含用户本轮新崩溃截图、雨声退场补测及120FPS圈钟新红项。

用户准备新开对话，本轮停止新功能和长测试；已启动检查已结束。后续恢复以本文件为最新入口，旧交接保留历史。

## 目标与现场

- 用户要求继续《项目进度评审报告-20261020.md》的未完成项，明确所有关卡准备发车文字都应清楚，并尽量避免历史0xC0000005退出崩溃。
- 仓库 `D:\桌面\DSH-Work\data-analysis`；工程 `godot-racer`；PowerShell、Godot 4.4.1。中文沟通，先读AGENTS、NEXT_SESSION_PROMPT、当前交接及进度矩阵。
- 收尾现场本地HEAD和远端main均 `7e255c8b72a950e452df3178db4879f31d8f0ffd`，本轮全部修改尚未提交/推送，证据绑定当前工作区。
- 工作区已有大量UI/首页/展车/BGM/相机/冻结带改动及两个旧交接删除，开工清单在 `godot-logs/countdown-readability-20261021/status-before.txt`。禁止reset/clean/stash/add-A或覆盖这些文件。

## 本轮代码范围

1. `godot-racer/scripts/start_countdown.gd`：标题26px、提示20px，统一近白字 `f3f6fa`，4px黑描边与黑阴影，数字仍6px描边，提示高度60px。保持正常场景亮度、透明输入穿透、3秒倒计时、0.5秒GO收旗及真实GO唯一入口/时序。五关共享该实现。
2. `godot-racer/scripts/engine_audio.gd`：实际Playback通过metadata `racer_generator_owner` 强持有自身Generator，保护异步播放回执仍存活时的生成器所有权。只加3行，未改音色/波形/输入/引擎版本/系统设置；保留已有stop+清回执。
3. `godot-racer/tests/ui_pages_test.gd`：仅本轮颜色断言改为近白字且outline>=4。这个文件有大量更早工作区修改，不可整文件顺带提交。
4. 新专项 `countdown_readability_test.gd`、`engine_audio_owner_test.gd` 及各自UID；串行runner `run-countdown-readability.ps1`。
5. 报告 `plan/countdown-readability-20261021.md`、`plan/exit-audio-owner-20261021.md` 和本交接。

`start_countdown.gd`本轮开工已含未提交透明UI-B修订；本轮样式依赖该透明层。若分批提交，应说明该直接依赖；其余首页/BGM/展车公共主题等不要混入。当前countdown162行、专项136行，历史ai_opponent1686行未改。

## 实测证据与C/T/U

主目录 `godot-logs/countdown-readability-20261021/`；矩阵目录 `godot-logs/countdown-readability-20261021-matrix/`，日志目录被Git忽略，不能假定推送源码后新机器也有证据。

- 文字红测：L4原实现19通过/24失败、exit 1；首次绿测43/43、exit 0。红测Forward+、首次绿测Compatibility；两者画面差异不能全部归于样式。
- 五关×720p/1080p×AI开关，20次各43/43，保存80张自然3/2/1/GO图；已检查四张QA原图索引和L4完整图。**实际进程19通过/1失败、runner exit 1**：L5/720p/AI开在汇总后访问冲突 `-1073741819`。旧红证据完整保留。
- 截图标题/提示轮廓清晰，正常亮度保留；1080p为离屏SubViewport，不是实体窗口或真人验收。AI关时部分首次3截图有相机就位过渡，不能认定装配演出已完善。最终Forward+补测图尚未逐张复看。
- Generator所有权合法红测9/3、exit 1，修复后12/12、exit 0；既有音频生命周期16/16、exit 0。最早红测脚本类型错误不算产品红测。
- 修复后真实倒计时/结算/完赛流程各60/120 FPS，六次均exit 0，分别29/29、57/57、67/67；`exit-owner-regression-audit.csv`为最终标记审计。倒计时120仍有ObjectDB警告。
- 修复后图形四次43/43且exit 0，`owner-final-results.csv`：L1无AI Compatibility/Dummy/60、L5 Compatibility/Dummy/120仍泄漏Generator及Playback；L4 Forward+/WASAPI/60、L5 Forward+/Dummy/60未见ObjectDB警告。本批未复现访问冲突，**不等于彻底解决历史崩溃**。
- lint81个GD通过；聚合解析覆盖53个scripts/scenes/tools源文件，exit 0（已有autoload过滤，不是53次独立运行，不含全部tests）；文档门两道通过；UI源码保护原60/1、exit 1，仍为menu.tscn UID差异。
- 完整ui_pages运行suite、Quick/full20、AC-13 18-run、新导出包本轮未复跑；U未验。不得将截图/断言/exit 0改写成真人通过。

## 崩溃诊断边界

官方4.4.1源码的Playback持Generator裸指针，独立WeakRef专项证明本地原实现存在生成器过早释放风险，本轮修补该所有权缺口。但未取得本机原生崩溃栈，不能认定全部历史0xC0000005只由它导致。metadata保护没有清掉所有异步退场残留，verbose仍可看到Generator/Playback泄漏。

下一最小工单应针对场景销毁/AudioServer异步退场顺序取证。新文字专项清理目前为game.queue_free→process_frame→view.queue_free→process_frame→quit；该等待不一定代表音频服务清理完成，需实证。不要直接固定sleep、隐藏ObjectDB、放宽断言、升级引擎或修改Windows调试器。已有根证书、shadercache/settings保存错误保留，不能将全部异常归于环境。

## 后续顺序

1. 先核实Git现场和上述报告/CSV；复看最终Forward+文字截图，确认本轮提交边界。不要盲目重跑已通过大套测试。
2. 若继续处理退出问题，先补最小诊断并保存真实exit/verbose；只有证据充分才改生产清理。每轮小工单，C/T/U分开，保留原红项。
3. 收口时按仓库AGENTS的普通提交推送契约办理，逐文件/逐hunk暂存，证据和SHA对应；本轮没有新提交。不要手改冻结hash或把旧首页/BGM资产吸入。
4. 再依 `plan/review-progress-20261021.md` 继续评审后续项；原full60 20/20、full120 19/20（phys最低117.18Hz<118Hz）、默认冻结带未正式发布、AC13/U/新包等边界保留，严格12大项仍0/12闭环。

矩阵复跑入口（需新证据目录名，当前不要求重跑）：

```powershell
Set-Location 'D:\桌面\DSH-Work\data-analysis'
pwsh -NoProfile -File godot-racer/tests/run-countdown-readability.ps1 -EvidenceName '<新的独立目录名>'
```

串行执行；runner检查最终汇总和真实进程退出码；内部45秒watchdog，但外层启动没有独立超时。禁止覆盖旧证据。
