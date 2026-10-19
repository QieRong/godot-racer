# godot-racer 项目交接 · 游戏策划求职方向（2026-10-19 19:10）

> 用途：切换到新平台（GPT）后粘贴本文即可接手。已按额度友好压缩：只留结论、判据、入口。
> 基线：HEAD `7f65173`，本地 `main` = `origin/main`（工作区仅 2 个 `.import` 噪声）。

## 1. 项目背景与现状

- **项目**：Godot 4.4.1 3D 赛车游戏 godot-racer（Jolt 物理、物理 120 Hz、Forward+；引擎 `E:\godot\Godot_v4.4.1-stable_win64.exe`，关卡索引 0 起，`-Level 3` = 荒漠 L4）。
- **定位**：游戏策划岗位**求职作品集**。展示「把玩家体验假设转成规则、配置、可试玩场景和验收判据」的完整过程，不把未做的用户测试写成成功结论。
- **仓库**：根 `D:/桌面/DSH-Work/data-analysis`，工程根 `godot-racer/`，remote `github.com/QieRong/godot-racer.git`。
- **工作方式**（长期约定）：TDD 先红后绿；验收绑定 commit + 工作区状态；每步提交须用户批准后才 commit + push。**桌面端 GPT 只做难题**（方法学/判据设计、方案取舍与铁律裁定、设计类），**workbuddy只做机械活**（跑测/lint/归档/提交推送）；GPT 给的方案一律本机 TDD 实证后才采信，绝不让 GPT 重复跑测。
- **验证体系**：20 项验收 runner（Quick 15）+ `tests/` 场景测试 + 两道文本闸门（check-docs/check-readme）+ aidiag 冻结带回放。
- **当前轮次**：第四轮（修复 2026-10-19 用户试玩反馈）代码提交 A/B/C/D **已全部完成并推送**，进入提交后验证阶段。

## 2. 当前阶段核心目标

**通过游戏策划岗位面试。** 三条决胜线：
1. 作品可试玩、无硬伤（本轮修的「起步时间对不上」正是面试会一眼看穿的硬伤）；
2. 规则/取舍/验证记录完整成文：策划案 `plan/racing-system-design-20261018.md`（v1.2）+ `godot-racer/docs/portfolio-design.md` 是面试主展品；
3. 验收证据链可复现：每个结论绑 commit + 日志，红→绿全程留痕。

本轮子目标：修「起步时间」缺陷、AI 出现时机、起点龙门架 → 走完提交后验证 → 用户试玩截屏确认。

## 3. 关键进展

**第四轮 4 个提交（已推送，全部留证 godot-logs/round4-*）：**

| Commit | 内容 | 关键证据 |
|---|---|---|
| `e171cd9` | **A 统一计时原点**（D1 修订 R6）：总时间 ≡ 各圈之和。vehicle.gd 加 `start_line_crossed` + `begin_lap_timing()`，门控在 `start_race()` 返回值 —— **自动化路径逐字节不变** | 先红：countdown 26 项 2 红、position 7 项 1 红 → 转绿 29/29、7/7；race_position_scene 15/15、finish_results 57/57、release_flow_scene 13/13 |
| `f11a49f` | **B 删「起步」行**（D1 后恒为 0）：hud.gd −41 | tests/ 全部门 12 个复跑：10 全绿 + mode_guard 补跑绿 |
| `b1da5c0` | **C 起点龙门架**（D3）：`start_gantry.gd` 跨线而立 + 立柱 BoxShape3D 同址同厚带碰撞；网格第 18 层不进小地图 | parse 通过；`--check=minimap` 0 失败；截图 5 张观感 6 项 |
| `7f65173` | **D 文档同步**：R6/R15/AC-05 修订 v1.2 + README/portfolio/testing 三处漂移修正 + testing.md 新增 ROUND4 小节 | check-docs + check-readme 均 EXIT=0 |

**更早的主干**（均已推送）：阶段一倒计时+同步发车（`aa66d93`）、阶段二名次+胜负（`b3239f8`）、阶段三结算页+HUD 总时间（`f773cf7`）；checks 族 13 模块拆分收尾（main.gd 1613→659 行）。

**本轮三项执行修正**（diff 清单 → 实测，新平台勿回退）：① A-5.2 桩需双标志（先红阶段旧公式仍读 `lap_running`）；② **GDScript 4.4 的 `bool()` 构造器不接受 null**（一律 `== true` 比较）；③ 「GO anchors」断言须轮询（GO 与断言同毫秒时差值恰 0.0）。

## 4. 待办事项与后续重点（按序）

| # | 事项 | 要点 |
|---|---|---|
| 1 | **冻结带重冻结**（D2 已批准机时） | A/C 改了 vehicle.gd/main.gd → `tape-preflight.ps1` calibrate→freeze→`--check=aidiag` 复跑 3~4 次；**阈值一个不改**（60%/50%/110km/h） |
| 2 | **Quick 15 → 全量 20**（60 FPS） | `run-all-checks.ps1 -Quick` → 全量；20/20、RUNALL_EXIT=0；`--check=aistart -Level 3` 单独留证 |
| 3 | **AC-13 降级三项**（D4） | 60/120 × lap×1 + opponents L4×1 + L5×1；完整 18 次留发布前 |
| 4 | **lap 双稳态** | A/B 前同代码两跑定模式（12956/13460/17092 三档），同模式比对 |
| 5 | **用户试玩确认** | L5：倒计时→GO→本圈/总时间同时起走、无起步行、AI 并排、龙门架跨线；截屏留证后才可称「试玩缺陷已修复」 |
| 6 | 遗留单独立项 | 2 个音频测试**既存失败**（rel_final_audio C6 / rel_step2c_audio 雨声暂停同步）——HEAD 黄金对照（stash 后原样复现）证明非本轮引入 |
| 7 | 龙门架 L1 观感定夺 | 立柱厚度实测失败走兜底 0.5m → L1 视觉柱厚 1.89m、横梁拉宽；唯一旋钮是模型腿厚（资产改动），由用户试玩定夺 |
| 8 | 远期 | 五关设计与 Excel 数值配置（`plan/five-levels-excel-pipeline-20261019.md`） |

## 5. 交接必读（按序）

1. `plan/round4-implementation-diff-20261019.md` —— 第四轮执行 diff 清单（A/B/C/D 提交边界、十步验证链）
2. `plan/countdown-timing-ai-grid-gantry-20261019.md` —— 完整修复计划 + D1–D4 决策记录
3. `plan/racing-system-design-20261018.md` —— 规则策划案 v1.2（R1–R15/AC 口径，面试主展品；**R6/R15 已修订为同原点，勿再按旧口径改回去**）
4. `godot-racer/AGENTS.md` —— 开发契约（铁律全集）
5. `godot-racer/docs/portfolio-design.md` + `testing.md` —— 作品集说明与验证记录

## 6. 环境坑速查（本机 Windows + Git Bash）

- Bash 不能调 pwsh（安全策略拦）→ 用 PowerShell 工具；长任务必须 `run_in_background:true`，输出落文件再读；
- UTF-8：本机 gb2312，`✔`(U+2714) 不可表示 → 不强制 UTF-8 会全线假红（runner 顶部已自带）；
- `shoot.ps1` 的 `-Out` **必须绝对路径**（相对必败 err=7）；
- headless 跑 Godot **不生成 `.uid`** → 新模块手写（`uid://` + 不碰撞后缀）；
- `core.autocrlf=true`：`git show` 还原后 status 可能报 M 而 diff 为空 → **以 `git diff` 为准**；
- **git push 502**：会话注入 `http(s)_proxy=127.0.0.1:10409` 对 github.com 回 502 → 绕过后再推：
  `env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY git push origin main`；
- lap check 双稳态；打印物理浮点的检查跨进程不可复现 → 只比结构（AGENTS §4.3）；
- GDScript 陷阱：`bool(null)` 编译期 parse error；`get()` 缺失返回 null 需 `== true` 降级。

## 7. 铁律速查

- 不得为变绿放宽判据/删测试/改阈值；验收项数不变（Quick 15 / 全量 20）；
- `racing_line.gd`/`track_layout.gd` = 几何与限速唯一真相源，禁止复制公式；
- 隔离/幽灵化只摘车辆位 bit 2、保留地面位 bit 1；整车清零必致「坠入深空」；
- 单文件 ≤1000 行（向前约束；超限在册：ai_opponent 1686 / vehicle 1413 / env_phys 1111）；
- 高影响动作（提交/发布/删除）须人工批准；每步把改动清单和验证结果摆出来再 commit。
