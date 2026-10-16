# L4 当前基线与 TDD 回执（2026-10-15）

> 当前结论：AI 对手修复已完成两关各三次冷启动、L1 诊断、Quick 与有效截图；
> 玩家 L4 自动驾驶已修复并于 2026-10-15 通过三次独立冷启动（卡住 0、复位 0）。
> 本页前半部分为历史步骤，最终状态见末节。

## Step 0：在 L5 修复之上重建基线

- 基线：4dbc98ad7ce9659df4361d6cbd332b999ccf0c30；启动时已跟踪工作区干净，仅两项 Blender 中间产物。
- 本地 HEAD = origin/main = 实际远端，左右差异 0/0。生产 blob 见 l4-current-baseline-progress.log。
- 引擎：Godot 4.4.1；五道闸门全部 EXIT=0。
- opponents -Level 3：FAIL，15527 帧，1 圈，自救 9 次，终点离中心线 0.96m，护栏 6.20m。
- run-check 的 EXIT=0 仅代表检查执行结束；真实验收有“对手验收 ✘”。本次不以进程退出零冒充通过。
- 已看到 CHECK 完成、后台 DONE / EXIT=0。原始证据为 l4-current-opponents-baseline.log。
- 此结果属于当前 L5 代码；旧基线自救 11 次不能作为本版本结果。

## Step 1：圆弧追线的失败用例

真实 AI 的 _update_steering 把目标点方向夹角直接当作轮舵角，没有按轴距及目标距离换算曲率。
在半径 142m、轴距 2.6m、车速 30m/s 且车已经贴合圆弧的夹具中：

- 预期轮舵角 -atan(2.6/142) = -0.01831rad；实际 -0.08214rad（约 4.5 倍）。
- tools/test_lateral_tracking.gd 调用真实 AI 转向入口，FAIL，LATERAL_FAILURES=1，EXIT=1。
- 测试文件加入后 lint EXIT=0；CLI 实际运行已完成脚本解析，非语法错误导致的红灯。
- 本用例检验几何曲率，不从旧玩家自动驾驶的 0.011m/m 推导 AI 响应。
- 拟修正：共享曲率→轮舵角纯函数，保留现有权限/响应速率/roll guard；不改变既有限速与刹车公式。

基线首次自救前窗口显示：目标车道 +2.40m 可通，但实际横向误差峰值 1.31m；
这与“目标通行不等于实际路径安全”一致。新曲率用例支持跟踪控制存在偏置；
能否消除 L4 自救仍须专项实测，不据纯函数用例提前宣布修复。

## 边界

此步未改生产代码、验收判据、抓地、转向权限、自救或音频。L4 仍未修复。
L5 修复保持；雪地 100km/h 抱死风险仍独立保留。

## 实机红灯证据

l4-baseline-stuck.png 与 l4-baseline-visual.log 同帧：arc=248.47，速度 0.20km/h，
自救 0，still=152，目标车道 2.40，实际横向 2.48。夹具沿原 opponents 发车时序，
只切相机、不改车辆输入/位置/速度。截图显示车头侧面抵住石头；HUD 属于静止玩家。
夹具主动退出时有资源仍被引用的清理警告，不能把截图运行当作完整 opponents 验收。

## 第一版候选：曲率换算单独不足以闭环

基线为 ed7802c + 工作区；AI blob 633014968ede41bb71e3eee05d8392808a204bb2，
RacingLine blob 6c73df86b877c7d732f8fa6513cebcab30db4e24。

- 圆弧/抓地/响应速率扩展检查 9/9，通过；旧 probe 制动检查 19/19，通过。
- L4 三次 7477 / 7478 / 7480 帧，均 1 圈、0 自救、未出界。
- L5 回归 FAIL：10125 帧，1 圈、自救 1 次；新卡点 arc≈256.7，非旧 BUG-L5-001 卡点。
- 实际跟踪路径未被名义车道的占用验证覆盖，不能只凭曲率用例或 L4 绿灯提交为完成。
- 第一版回归脚本因此停止；未执行其后的 aidiag 和 Quick。视觉队列按失败条件停止。
- 证据前缀 l4-resume-* / l4-regression-*。此前 l4-tracking-* 启动遇到内存耗尽，
  没有 DONE；保留原 .out/.err，补跑结果不覆盖中断记录。

## 第二版：实测跟踪偏差带

AI 将“实际横向−上一帧目标车道”传给唯一选道模块。候选要求目标线与按偏差平移后的路径
之间的整条横向带均可通，且两端均在原路边界内；不只判两个端点。候选补偿使用同一实测偏差。
选道和排队共用 _tracking_band 与原占用函数，未复制障碍几何判据；原 API 默认偏差为 0。

- 实际偏差 -0.5m 时旧选道 2.40m 被红用例抓住；新选道 2.925m，原偏差路径也可通。
- 补充红用例抓住“整带受阻但只查询名义车道导致解除排队”；修正后进入减速等待。
- 五条包络用例已通过：偏差安全、路边界、旧 API、端点间受阻、不可达排队。
- 生产 blob 与串行专项实测记录见 l4-envelope-progress.log / l4-envelope-regression-progress.log。
- 本段尚不宣布最终修复；以完整专项、回归、截图与最终回执为准。

## 最终 AI 验收与恢复收尾

实车验收版本为 ed7802c0985612af643fc17abac1f9d832e1d844 + 修复工作区，
不是干净提交上的重新验收。最终生产 blob 与实测回执一致：

```text
ai_opponent.gd   4086292fb43fbe7a733040138d6347bd5d3a6d3f
racing_line.gd   6c73df86b877c7d732f8fa6513cebcab30db4e24
obstacle_field.gd bdf4d050e3e1f0f17ebaf3fc661c8d4503d725e4
autopilot.gd     e7dc6e923b31d996ca3db0f63bf42d787ca07a9d (未改)
```

| 检查 | 最终结果 | 证据 |
|---|---|---|
| lint / parse / docs / readme / dup-source | 五道 EXIT=0 | l4-envelope-对应闸门.log |
| opponents L4 三次 | 7968 / 7968 / 7815 帧，均 1 圈、0 自救、未出界 | l4-envelope-opponents-1.log / l4-envelope-l4-2.log / l4-envelope-l4-3.log |
| opponents L5 三次 | 10526 / 10544 / 10534 帧，均 1 圈、0 自救、未出界 | l4-envelope-l5-1/2/3.log |
| L1 aidiag | PASS，贴限速 63.6% | l4-envelope-aidiag-l1.log |
| Quick | 15/15、EXIT=0，后台 DONE EXIT=0 | l4-envelope-quick.log / l4-envelope-regression-progress.log |
| 恢复时补充检查 | 跟踪 9/9、偏差带 5/5、probe 19/19，EXIT=0 | l4-recovery-test_*.log / l4-recovery-final-progress.log |
| 回执反误报检查 | 6/6，先红后绿 | l4-receipt-red.log / l4-receipt-final.log |
| 玩家干净圆弧红灯 | 预期 -0.01831rad、实际 -0.29375rad，EXIT=1，无脚本错误 | l4-player-circular-clean-red.log |
| 玩家 lap L4 三次（修复后） | 138.0 / 138.0 / 137.9s，均 3 圈、卡住 0、复位 0 | l4-player-speed-lap-1/2/3.log |
| 有效 AI 实机图 | 先跨起点 arc=0.22，再至 arc=260.47，121.69km/h、自救0、在路面 | l4-recovery-pass-valid.png / l4-recovery-visual-attempt-1.log |

有效图的完整进程回执为 l4-recovery-visual-batch-progress.log：DONE EXIT=0。
截图不改车辆输入/位置/速度，只切相机；HUD 仍属于静止玩家，AI 速度取同帧 VISUAL。
主动退出截图夹具会有资源仍被引用的清理警告，不拿它替代整项 opponents 验收。

### 必须保留的错误/中断记录

- l4-player-baseline-progress.log 的 PASS=True 是旧谓词误报。原始 lap 日志有中途掉头演练 ✔，
  同时最终卡住 3 次、疑似复位 5 次并明确 ✘；真正结果为 FAIL。
- 修正后的开发回执同时要求完成、通过标志、无显式失败/脚本错误；默认只解析已完成日志，
  不重跑物理验收。l4-player-receipt-fixed-progress.log 为 PASS=False、COMPLETE=True、DONE EXIT=1。
  这不改变原游戏判据或 04 启动器闸门。
- l4-player-circular-red.log 有缺失 EngineSound / road_length 的夹具错误，不当作合格红灯。
  补齐夹具后另存 clean-red，正式玩家代码仍未修。
- l4-final-pass.png 是出生点误拍（arc≈1803.62、0.24km/h），原 visual DONE 不证明过卡点。
  新夹具强制跨起点后才允许在 260–280m 抓图；旧图保留为错误证据。
- l4-recovery-final-progress.log 没有最终 DONE，视为中断；其中三组已完成单元检查单独有效。
- l4-recovery-visual-retry-progress.log 记录启动期访问冲突 EXIT=-1073741819，VALID=False，
  保留失败，不冒称通过。最后的独立批次仅允许明确启动期访问冲突重试，不对行为失败刷绿。

### 未完成边界

玩家 lap L4 的 3 次卡住 / 5 次复位已于 2026-10-15 修复并通过三次冷启动（见末节）；
有障碍连续控制提案见 l4-autopilot-control-proposal.md 保留为设计记录。
其余边界不变：
整套 20 行未整套重跑；长时 stress 与默认 lap 本批未跑，因为生产代码未再变更，
已完成专项、Quick 和诊断保留为版本绑定证据。本次不把客户端重启当作重做修复的理由。
雪地 100km/h 抱死、雨声接线与音频来源单条页面待补仍保留；没有自动集成 WorkBuddy 资产。

### 最终提交与推送

内容提交 d845ff5295bb18b517836cf2810088c7309840d1 已于 2026-10-15 22:40:29 +08:00
核对 HEAD = origin/main = GitHub 实际 refs/heads/main，左右差异 0/0；原始回执
l4-recovery-content-push.log。四份脚本的提交 blob 均与上表相同，autopilot 保持原样。
恢复后五道闸门与六份 PowerShell 工具语法全部通过，最终 l4-recovery-gates-progress.log 为 DONE EXIT=0。
本节随文档收尾提交入库；不改变实车验收的工作区版本绑定，也不启动新的玩法修复。

## 玩家 L4 自动驾驶：有障碍分支连续控制 + 曲率限速（2026-10-15 收尾）

基线为 d9de962 + 本轮工作区；无速度控制的失败日志已归档保留，不覆盖：
l4-player-fix-lap-1-nospeed-archive.log（卡住 3、疑似复位 5、碰撞 7、入弯 205km/h）。

工作区生产 blob（实车验收版本）：

```text
autopilot.gd       ebdf2e63b8737f13e32b35be18cb391551276a02 (本轮唯一改动)
vehicle.gd         15b0e998a462be7d6007f4ac445785be163ebf96 (未改)
ai_opponent.gd     4086292fb43fbe7a733040138d6347bd5d3a6d3f (未改)
racing_line.gd     6c73df86b877c7d732f8fa6513cebcab30db4e24 (未改)
obstacle_field.gd  bdf4d050e3e1f0f17ebaf3fc661c8d4503d725e4 (未改)
```

改动内容只落在 autopilot.gd 的**有真实障碍自动驾驶分支**：

- 转向：共享曲率纯函数 `RacingLine.pursuit_steering` 换算目标轮舵角，再按
  `RacingLine.steer_limit` 与车辆 roll guard 归一化成 Input 强度，替代旧 ±0.06 二值门限。
- 纵向：以 `RacingLine.corner_radius_at` / `speed_limit_kmh` / `lookahead_limit_kmh`
  取现有限速，超速则 release accelerate + press handbrake，走真实 Input 链。
- 离开障碍分支或恢复接管时显式释放本模块自己按下的刹车，避免残留输入。
- 无障碍分支、手动驾驶、车辆参数、自救与验收判据**全部原样未动**；
  绕开旧二值门限属用户 2026-10-15 明确授权，仅限该分支。

| 检查 | 结果 | 证据 |
|---|---|---|
| lint / parse / docs / readme / dup-source | 五道 EXIT=0 | l4-player-speed-对应闸门.log |
| 单元夹具 | 7 条 PASS，AUTOPILOT_FAILURES=0，EXIT=0 | l4-player-speed-unit.log |
| 玩家 lap L4 第 1 次 | 138.0s、3 圈、卡住 0、复位 0、碰撞 1、最高 107.7km/h | l4-player-speed-lap-1.log |
| 玩家 lap L4 第 2 次 | 138.0s、3 圈、卡住 0、复位 0、碰撞 1、最高 108.3km/h | l4-player-speed-lap-2.log |
| 玩家 lap L4 第 3 次 | 137.9s、3 圈、卡住 0、复位 0、碰撞 1、最高 107.8km/h | l4-player-speed-lap-3.log |
| 三份 lap 日志负面项 | ✘ 判据 0 条、脚本错误 0 条，均 `[CHECK] 完成，退出` | l4-player-speed-lap-1/2/3.log |

对照归档基线：卡住 3→0、疑似复位 5→0、碰撞 7→1、入弯速度 205→107.7km/h。
两次瞬移的根因是 `owner=main action=reorient_teleport`（车头接近 180° 且低速被扶正），
瞬移是果不是因；前因是高速撞护栏，因此限速控制是对症项。

### 本轮未做与后续

- 玩家 L4 有效截图、AI 两关 opponents L4/L5 回归、`run-all-checks -Quick` 本轮未重跑，
  本项结论**只覆盖玩家 lap 三次与前置闸门**，不扩大为整轮全绿。
- 帧率默认 60 + 菜单 60/120 切换为用户已选定但尚未实施的功能项。
  改帧率会改变机器负载，而 lap 验收已知为双稳态，故上述日志不能沿用作改帧率后的证据。

## 2026-10-16 L4 玩家任务补充回归与截图

当前生产 `autopilot.gd` blob 为 `ebdf2e63b8737f13e32b35be18cb391551276a02`，
与内容提交 `57bdea470264f3e3031c14c02edc1ea1c67c7ce7` 相同。本节未改生产脚本、控制门限或验收判据。

| 验证 | 原始结果 | 证据 |
|---|---|---|
| AI opponents L4 | 7965 帧、1 圈、自救 0、未出界、`[CHECK] 完成`、`DONE EXIT=0` | `l4-player-post-opponents-L4.log` / `.out` |
| AI opponents L5 | 10528 帧、1 圈、自救 0、未出界、`[CHECK] 完成`、`DONE EXIT=0` | `l4-player-post-opponents-L5.log` / `.out` |
| Quick | 15/15 通过、`DONE EXIT=0` | `l4-player-post-quick.out` |
| 玩家 L4 画面 | 跨起点后 arc260.33、117.19km/h、离中心线 3.56m、车头夹角 6.98°、四轮接地；人工看图车辆在路面 | `l4-player-pass-valid-flush.png` / `l4-player-final-visual-flush.out` |

截图进程在 `save_png result=0` 后退出时返回 `-1073741819`；初跑、复跑、加三帧渲染收尾、
改兼容渲染均复现。图像可以证明该帧画面与位置，**不能**称为退出码 0 的完整截图验收。
相关失败输出 `l4-player-final-visual.out`、`l4-player-final-visual-retry.out`、
`l4-player-final-visual-flush.out`、`l4-player-final-visual-gl.out` 保留；未用重试掩盖异常。
三次玩家 lap 原判据的绿色结果与 AI/Quick 的绿色进程不受该截图工具退出问题影响。

WorkBuddy 审计 HTML 以 `d9de962` + 未提交工作区为基线，早于 `57bdea4`，其中 L4 AI
“55 次自救”、玩家修复“未入库、未覆盖”均不符合当前实测与 Git。报告提到的其它风险
（例如视觉碰撞差异、动态障碍时间轴）仍属待独立核查线索，本任务未自动实施。
WorkBuddy staging 三批资产与原工程未跟踪 `models/environment/` 均未集成。
