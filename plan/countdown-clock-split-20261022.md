# CD-CLOCK-SPLIT-001：分离圈钟连续性与采样耗时

## 批准范围与规则

用户在上一轮具体方案后明确回复“批准”。承接 `plan/countdown-clock-diagnosis-20261022.md`：分离原点连续性与采样耗时检查，保留原耗时红门。开工 HEAD/实时远端 main 均为 `b7508c14a905a3ff75b5756683ce376b04ce7fa1`。两份 AGENTS 内容一致；既有首页、BGM、相机、冻结带与未跟踪资产继续保护。

玩家规则不变：圈钟由 GO 锚定，首次压线不完圈、不重置；本轮只调整测试如何判别失败。没有修改车辆、GameState、音频、场景、配置或引擎版本。

新检查规则：

1. **连续性**：覆盖 GO、首次压线轮询、随后完整30帧窗口，所有采样的圈钟原点均等于同一个 GO；圈钟不倒退，圈数0；相位RACING、树未暂停；比赛时钟及圈钟的读数落在采样前后墙钟扣除累计暂停的毫秒区间内。按实测区间处理跨毫秒读取，不新增任意误差阈值。窗口必须有索引0—30的31个样本、相邻process_frame连续。
2. **耗时**：保留原 `t2 > t1 && t2-t1 < 1.0`，并同时要求实际30帧墙钟耗时 `0 < wall_s < 1.0`。严格小于1秒，未抬高阈值；慢帧仍使整次测试失败，只改变失败归属。
3. 详细逐帧日志仍由 `--trace-countdown-clock` 开启；连续性采样始终执行，关闭日志不会关闭检查。简短 `COUNTDOWN_CLOCK_RESULT` 每次输出两个独立布尔结果及实际耗时。

原合并断言拆成两条，专项总数29→30；其余28条原断言继续执行。缺采样、漏帧、时钟回零/跳变、原点变化都不能变成空通过。无首次压线时保留原失败分支。

## 实现、先红后绿与专项

- `tests/countdown_scene_test.gd`：336→388行；新增两项静态判据并接入真实场景采样，未复制生产车辆或物理逻辑。
- 新增 `tests/countdown_clock_contract_test.gd`：107行，使用真实判据处理手工可核对的计时样本，21条用例。本机生成的UID侧文件随测试一起保存。
- 新独立快照在 `godot-logs/countdown-clock-split-20261022/source-snapshot/`，由前轮原始archive和缓存建立；生产源文件与原archive字节一致，仅原倒计时测试不同，另增本轮契约测试。没有复制脏工作区首页等代码。

有效红测 `contract-red-ready`：新契约测试针对尚未实现判据的旧倒计时测试，`pass=0 fail=1`、真实exit1、无脚本错误，原因是缺少两项分离判据。实现后同一份契约测试源码保持不变，21/21、真实exit0；最终runner同步适配新30条场景汇总与21条契约汇总后，`contract-final`严格通过。

准备阶段另有两项原样保留：`contract-red` 是测试装载写法导致的Parse Error，不作为有效TDD红测；`contract-green` 实际21/21、exit0，但旧runner没有契约汇总适配而判FAIL，不计入最终严格绿测。没有改测试预期来掩盖错误，也没有覆盖这些记录。

| 最终独立运行 | 断言 / 真实exit | 连续性 / 耗时 | 严格结果 |
|---|---|---|---|
| contract-final | 21/21，0 | 契约反例全部符合预期 | PASS |
| scene-120，开详细日志 | 30/30，0 | true / true；墙钟0.249656s，圈钟0.249s | PASS |
| scene-60，关详细日志 | 30/30，0 | true / true；墙钟0.498146s，圈钟0.498s | FAIL：Generator/Playback泄漏 |
| delay-control-120 | 29/30，1 | true / false；墙钟2.196122s，圈钟2.196s | FAIL：预期人工负载耗时红门 |

人工负载仅给独立进程传 `--frame-delay 40`，不是生产或退场修复。此组新的连续性断言通过，仅耗时断言失败；旧证据与负对照均保留。历史2.563秒仍缺同段墙钟，不能因此认定其具体根因或关闭历史红项。

四次最终专项严格2通过/2失败，包含一个预期负对照；三个自然运行中2通过/1失败。全部无脚本错误、未超时；根证书错误仍存在，不能说零错误。自然60FPS的泄漏保留为独立退出缺陷，未重跑挑绿或顺带修改音频。

## 验证与运行

项目现有Quick15在新独立快照上串行运行120FPS，**15/15通过、最终exit0**，实际耗时1206.438秒。包括docs/readme、enclosure、wallslide、minimap、obstacles、aistart、avoid、pause、flip、layout、reverse、weather、friction、phys；不是完整20项、AC-13或导出包验证。本次phys最低实测120.055Hz通过，历史失败记录仍保留，不凭一次通过宣称长期稳定。

Quick的13个游戏原日志无SCRIPT ERROR、Parse Error或ObjectDB/资源泄漏；根证书及shader cache创建错误仍在，不能称零错误运行。最终控制台/收据见 `quick-120.console.log`、`quick-120.result.json`，复用原 `Get-CheckResult` 的逐项OUTCOME/ASSERT核对见 `quick-audit.json`。子进程exit0由现有suite必须childExit0才标PASS且最终suite exit0推定，未伪造逐个原生PID收据。

快照位于父仓库内部，现有runner向上探测Git，因此控制台标为父仓库b7508c1及67条脏状态；该标签不是快照源码混入脏文件的证明，也不能据此称干净HEAD验证。源码原字节核对和本轮测试脚本哈希另附收据，测试对象以这些记录为准。

lint扫描84个GD通过；Godot定向parse契约入口通过，倒计时脚本已在真实场景运行中加载验证；check-docs、check-readme均通过、exit0。两份GD均≤1000行；历史ai_opponent1686行未动，不称全库合规。

本机仓库根目录命令（新name，避免覆盖旧证据）：

```powershell
python godot-logs/countdown-clock-split-20261022/run-case.py new-contract res://tests/countdown_clock_contract_test.gd 120
python godot-logs/countdown-clock-split-20261022/run-case.py new-scene res://tests/countdown_scene_test.gd 120 --trace-countdown-clock
```

runner以新汇总、断言数、真实退出码、无脚本错误/泄漏/超时共同判定。证据ZIP含runner、全部红绿原日志、进程收据、源码及清单；不含整份可独立重建的资产/缓存。

归档：`evidence/countdown-clock-split-20261022.zip`，包内逐文件MANIFEST.sha256、外部ZIP SHA256，发布前逐文件核对。

归档复核中，附加Python审计曾错误地把暂停重开的两段RUNID合并计数、把wallslide的INFO记录当失败；现改为直接复用现有解析器，没有修改原闸门。文档中的一句“Quick不能替代完整20项”也误触原计数正则，已修正文案而未改检查脚本。错误辅助脚本、失败输出与文档门红日志保留；发布前的初包仅留本地 `pre-audit-package.zip`，最终包重新生成并核验。

## 状态与边界

C：获批的判据拆分已实现。T：按上表和Quick实际结果，不能称项目全绿。U：未验；本轮纯测试改动，不伪造新的画面或真人体验。

完整20项、AC-13 18-run、五关真人可读性/听感、GUI实体1080p、新导出包未实测。历史原生访问冲突、phys红项、默认冻结带未正式发布、UI UID源门与原12项关闭状态不由本轮改变。

回退仅反向本工单提交，不使用reset/clean/stash，不触碰未提交资产。下一独立候选工单是将普通倒计时/圈钟专项接入已有音频回执ID回收探针，保留本轮泄漏红证据并先证明判据能抓住旧退场缺口；本轮未实施该音频工作。
