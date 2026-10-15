# 四份外部评审 × 代码实证 · 交叉审查报告

> **2026-10-15 状态提示**：本文保留历史审查结论。其后已补 L4 opponents 门禁（全量 20 行）、
> 补 MIT 与素材来源记录、修复 L5 BUG-L5-001 并完成专项/Quick 回归；L4 仍待修。
> 当前状态、证据与范围以 `HANDOVER.md` §0 和 `godot-logs/l5-final-report.md` 为准。

> **生成时间**：2026-10-14 19:21 (GMT+8)　｜　**基线刷新**：2026-10-14 22:05（见 §0）
> **审查对象**：豆包评审 / GPT审查 / Gemini / DeepSeek 四份 HTML（原始文件在本机 `D:\桌面\`，**不在仓库内**，读不到不影响本文使用）
> **实证基线**：审查时 HEAD `f999af1`（本地 == origin/main，0/0），工作区干净（仅 2 个 Blender 中间产物未跟踪）；**当前基线已刷新为 `c25698b`**（见 §0）
> **方法**：只读实证——文件读取 + git + grep，**未启动 Godot / Blender**（审查期间另有 2 个对话并行操作，主动避让；并行会话在我审查过程中提交并推送了批次④收尾 4 笔，见 §7）
> **用途**：供新对话零上下文接手；本文只做审查与排序，**未修改任何代码**

---

## 0. 基线刷新说明（2026-10-14 22:05，原文其余部分未改动）

本文 §1 写的「评审基线之后仓库已前进 10+ 笔提交」是**审查当时**的实况。此后仓库又前进了 **10 笔**。
下列事实已**过时**，以本节为准：

| 位置 | 原文 | 现状 |
|---|---|---|
| §1 第 3 条、§3.4 #19 | `main.gd` 已拆到 **1613 行** / 36 func | **659 行 / 17 func** —— 批次⑤ `SPLIT-CHECKS-BASIC-005`（`f8b2cb2`）把基础验收族 + 跑圈/压测/反向族迁入 `scripts/checks/basic.gd`（608 行）/ `lap.gd`（598 行），**`main.gd` 的 `--check=` 函数体拆分全部收尾**；`main.gd` 已脱离 AGENTS 第 8 条的「超限历史遗留名单」 |
| §1 第 3 条 | 「仓库已前进 10+ 笔提交」 | 已前进 **20+ 笔**：批次⑤ 收尾 7 笔（`f8b2cb2..f7a94c9`）+ OpenRouter 整体移除 3 笔（`522c983` / `18eeae0` / `a96ee5e`）+ HANDOVER 终态 1 笔（`c25698b`）+ 批次④收尾 4 笔 |
| 全文关于功能面 | —— | **OpenRouter 联网测试功能已整体移除**（用户签字「彻底移除功能」）：`--check=openrouter` / `--check=models` 两项消失，`main.gd` 检查项 **26 → 24**；`run-all-checks` 的 **19 项套件项数未变**（这两项本来就不在套件里） |
| §6.1 / §6.5 | HEAD `f999af1` | **HEAD = `c25698b`**（本地 == origin/main == `ls-remote`，`rev-list --left-right --count` = `0 0`）；工作区干净，未跟踪 2 个 Blender 中间产物 |

**本节的结论部分（§4 的两个 P0、§5 的排序）不受影响，仍然有效**：两个 P0（L5 `BUG-L5-001` probe 死锁、
L4 横向控制卡死）在批次⑤ 与 OpenRouter 移除期间**均未被触碰**；`opponents` 门禁「只跑 L5、盖不住 L4」
的盲区也**原样存在**（`04-Godot启动器/run-all-checks.ps1` 的 `@{ n='opponents'; lv=4; ... }`）——
即 §5 P0-1 仍应先于一切修复执行。另一份交接文档 `HANDOVER.md`（仓库根）已在 §1.5 / §7 同步上述终态，
并把两个 P0 写进了待办清单。

---

## 1. 结论速览（先读这段）

1. **四份评审整体真实可信**：两个 P0 缺陷的判断全部属实、且相互印证。逐条核验 20+ 项关键断言：**属实 13 项、表述误导 2 项、明确失实 2 项**。
2. **最重大的元结论**：四份评审都基于 GitHub 公开仓库（基线 `3298de4`），**看不到被 gitignore 的 `.workbuddy/evidence/`**。因此他们列的"待办"有的已在本地完成——最典型的是 **a_brake 真值实测已落账**（`step1d-abrake-truth.md`，2026-10-12），四个评审都说"实施前必须先测 a_brake"，其实前置已就绪。**新对话不要重复他们过时的待办清单。**
3. **评审基线之后仓库已前进 20+ 笔提交**（明细见 §0）：Gemini 标记"待处理"的 bench 满舵 0.45→0.5 已修（`4e524fb`）；`main.gd` 已从 2577 行拆到 **659 行 / 17 func**（批次⑤ 后 `--check=` 函数体拆分全部收尾）；≤1000 行规则已补"历史遗留登记"签字口径；**OpenRouter 联网功能已整体移除**（检查项 26→24，套件 19 项不变）。
4. **当下最优先（排序见 §6）**：① 修验收门盲区（opponents 门禁当前对两个 P0 **双盲**）→ ② L5 BUG-L5-001 修复（检疫 10-19 到期，前置已就绪）→ ③ L4 横向控制修复（**与 ② 禁并行**）→ ④ 当前 HEAD 全量 19 项重跑并绑定证据。
5. **明确不需要现在做**：目录路径改名、Git LFS、大规模重构——均为高风险低收益。

---

## 2. 四份评审可信度总评

| 评审 | 基线 | 深度 | 可信度 | 主要失实 / 误导 |
|---|---|---|---|---|
| **GPT审查** | `3298de49` | ★★★★★ 唯一做了 P0 根因链分析 + 路线图 + DoD | **高** | 无明显失实；所有关键断言核验属实（含"干净克隆 godot-mcp 插件警告"——`addons/` 确实 git 未跟踪） |
| **豆包评审** | main@10-14 | ★★★★☆ 统计最全（119 commits / 15,534 行 GDScript），每条建议带验收门 | **高** | `godot-logs` "12MB" 数字过期（实际 286MB，方向正确）；"main.gd 2577 行"已被后续拆分改写 |
| **Gemini** | `3298de4` | ★★★★☆ 进度总览性质，BUG-L5-001 两层根因与 `testing.md` 逐字一致 | **较高** | "**5 关全部接入新管道（92%）**"误导——样条管道就绪 ≠ 关卡内容交付，五关 `.tres` 全部仍是 `layout="ellipse:..."`；其"bench.gd 0.45 待处理"已被 `4e524fb` 修复 |
| **DeepSeek** | `3298de49` | ★★☆☆☆ 表层工程卫生为主，两个 P0 仅一句带过、无根因分析 | **低** | **两处明确失实**：① 称 `rain_loop.ogg` "已接入"播放器——README 白纸黑字"还没有接线"；② 称目录名含尾部空格（`01- /`、`02-Blender ` 等）——repr 实测零空格（详见 §3.3 #18）。PNG 元数据一条未核验（本机无 PIL），其"归档截断"是它自己工具链的问题，非仓库缺陷 |

**四份评审的共同盲区**（重要）：均基于 GitHub 公开代码，看不到 `.workbuddy/evidence/`（gitignored）与本地未推送状态。凡是他们说"需实测/待跑/待补"的，先查 `.workbuddy/evidence/` 再决定要不要做。

---

## 3. 关键断言核验台账（每条附证据）

### 3.1 核验属实（评审说对了）

| # | 断言 | 来源 | 证据 |
|---|---|---|---|
| 1 | L4 荒漠自动驾驶/AI 卡死（撞→复位→再撞） | 全部四份 | `docs/testing.md` 已知缺陷区；`docs/plans/lap-autopilot-obstacle-avoidance.md` TASK-027：高速段横移仅 **0.011 m/m**，挪 2m 需 ≈180m 而决策前瞻只有 45m——**算术不闭合**；卡住事件 45→9、判据是 0；已历经 7 轮取证未破 |
| 2 | L5 极地 BUG-L5-001：撞石→定格 3s→瞬移，确定性结构缺陷 | 全部四份 | `docs/testing.md:889-902`：83% 红（5/6），卡点恒定 arc 789.2~789.7；代码实证 `ai_opponent.gd:799` 的 probe 分支 `pow(max(ahead-2,0),2)*1.8` 瞬时余隙二次式；50km/h 时限速 d=7.27m 才咬、雪地需 11.6m、缺口 4.3m；`QUEUE_MIN_KMH=6.0` 地板在 queue 分支（:449）有、probe 分支没有——设计不对称实锤 |
| 3 | BUG-L5-001 检疫至 2026-10-19，到期强制重评估；检疫期内 opponents 行**对回归检测失效** | GPT/豆包/Gemini | `testing.md:895` 检疫规则①②③写死；`run-all-checks.ps1:74` opponents `lv=4`（=第 5 关极地） |
| 4 | **opponents 门禁只跑 L5，盖不住 L4** | GPT/Gemini | `run-all-checks.ps1:74`；`testing.md:46` 明说"这条自动化现在盖不住该缺陷，必须手动 -Level 3" |
| 5 | 五个关卡全部仍是 ellipse 占位形态 | GPT/豆包 | `data/levels/level_{1..5}.tres` 全部 `layout = "ellipse:..."`（L4 `ellipse:340:220:4:18`、L5 `ellipse:230:150:5:26`）；无一路段 DSL 组合 |
| 6 | L2 角度序列闭不上、残差 340m | Gemini/豆包 | `docs/plans/tracks-and-elevation.md:429,476`："任何两条直道组合都解出负长度" |
| 7 | rain_loop.ogg **未接线** | GPT/豆包/Gemini | `assets/audio/README.md`："预置资源，还没有接线到任何播放器"；`loop=false` 待办；全库 grep 无任何 .gd 引用 |
| 8 | 大文件行数（评审基线时） | GPT | vehicle.gd 1413 / ai_opponent.gd 1668 / track_generator.gd 809——与评审数字逐一吻合（±1 行） |
| 9 | 验收证据时效性不足：最近完整结果停在 2026-09 且无 HEAD 绑定 | GPT/豆包 | `testing.md:63-65` 自认"没有记录对应的 Git HEAD…不能证明任务 15 之后再跑过"；`baseline-all-checks.log` 绑 `44352f85`、18/19（opponents 红） |
| 10 | 干净克隆会因 godot-mcp 插件报加载警告 | GPT | `project.godot:27-29` `[editor_plugins] enabled=...addons/godot_mcp/plugin.cfg`，而 `git ls-files addons/` **为空**——插件在磁盘上但未入库 |
| 11 | 19 项日常验收套件 / layout 68 条断言 | GPT | `run-all-checks.ps1` 19 个 `@{ n=`；`testing.md` layout 行"68 条…全过" |
| 12 | godot-logs 已被 gitignore | DeepSeek/豆包 | 工作区 status 干净可证；实际体积 **286MB**（豆包说的 12MB 是旧数） |
| 13 | l4_debug_diag.gd 653 行 | 豆包 | `wc -l` 精确 653 |

### 3.2 表述误导（方向对、结论过头）

| # | 断言 | 问题 | 实证 |
|---|---|---|---|
| 15 | Gemini："5 关全部接入新管道，赛道生成 92%" | 样条几何管道（track_layout 真样条、68 断言）确实就绪，但**关卡内容仍是椭圆占位**——把"管线就绪"写成"内容交付" | 见 #5；豆包/GPT 的"30% 赛道形态"更准确 |
| 16 | DeepSeek：二进制大文件应上 LFS、"归档流被 rain_loop.ogg 撑爆" | 仓库 `.git` 仅 39MB，完全不到需要 LFS 的量级；"截断"是其读取工具的问题 | `du -sh .git` = 39M |

### 3.3 明确失实

| # | 断言 | 实证 |
|---|---|---|
| 17 | DeepSeek："在 assets/audio/ 中**接入**了 rain_loop.ogg 雨天循环音效" | README 明示未接线、无代码引用、loop=false——**未接入** |
| 18 | DeepSeek："阶段目录名包含尾部空格（`01- /`、`02-Blender /`、`03-2D /`、`04-Godot /`），部分文件名存在空格（如 `01- /GitHub .md`）" | **证伪**（2026-10-14 repr 实测）：四个目录名 `'01-参考'` / `'02-Blender建模'` / `'03-2D赛车图'` / `'04-Godot启动器'` **零空格**；全工作区（排除 .git/godot-logs/.workbuddy/godot-racer）文件名 **0 处**含空格。此前误判来源：git status 给中文路径加引号是 `core.quotePath` 的八进制转义，不是空格。附带事实：4 个 .bat 启动器文件名本身为中文（`启动器.bat` 等），Windows 中文环境可正常使用，不构成缺陷 |

### 3.4 评审之后的已发生变化（勿按旧评审行动）

| # | 事项 | 现状 |
|---|---|---|
| 18 | Gemini："bench.gd 满舵 0.45 vs 真源 0.5 待处理" | **已修**：`4e524fb` GATE-REPAIR-001（用户签字） |
| 19 | 各评审："main.gd 2577 行庞大" | **已拆到 659 行 / 17 func**：`0fc8eb2` SPLIT-CHECKS-ENVPHYS-004（环境物理族迁出 → 1613 行）、`f8b2cb2` SPLIT-CHECKS-BASIC-005（基础 + 跑圈/压测/反向族迁出 → 659 行）；checks 族**批次①-⑤ 全部迁完** |
| 20 | HANDOVER.md 遗留："≤1000 行规则与现状冲突待拍板" | **已定口径**：`ba5e31f` 第 8 条改为"向前约束 + 现存超限登记在册（ai_opponent 1668 / main 1613 / vehicle 1413 / env_phys 1111），随 SPLIT-* 批次收敛，不阻塞修复性提交" |

---

## 4. 本地已有、但外部评审看不到的关键证据（`.workbuddy/evidence/`）

| 证据 | 内容 | 意义 |
|---|---|---|
| `step1d-abrake-truth.md` | **a_brake 真值已实测**（2026-10-12，HEAD `7890b5e`，108+36 格次，A/B/C 跨进程极差 ≤1%）：手刹台架 L3≈12.0-12.9 / L4≈12.2-12.9 / L5≈11.4-12.2 m/s²；三档均"刹车力受限或保守复核带"，**AI（刹车 55）折算估算 L3≈19.2 / L4≈23.4 / L5≈13.7**；L5 100km/h 实测车轮抱死（抱死后有效减速度塌到 ~3 m/s²），雪地档不得线性外推；文档假设值 6.0 低估约 2 倍 | **L5 修复的前置已就绪**——四份评审都说"先测 a_brake"，别再排这个前置 |
| `opponents-L5-flaky.md`（409 行，未入库） | BUG-L5-001 完整取证 | 修复时直接引用，勿重新取证 |
| steerbench 传递函数数据（Step 1/1b′，10-11） | 舵角→横向加速度矩阵；证明 0.011 m/m 是"实现值"非物理上限（1m 误差时 77% 帧不打舵） | L4 修复的输入已备 |

---

## 5. 当下最需要优先解决的问题（按序）

### P0-1 · 验收门盲区 + 检疫到期决策（0.5 天，先于一切修复）

- **事实**：19 项套件里 `opponents` 只跑 L5（`lv=4`）；L5 在检疫期内"对回归检测失效"；L4 根本不进自动化 → **两个 P0 都没有自动保护网**。现在改任何 AI/限速代码，红了都不会有人知道。
- **动作**：用户签字后在 `run-all-checks.ps1` 给 opponents 增加 L4 矩阵行（或 `lv=3` 新增一行）。⚠ `check-readme.ps1` 会把清单行数当「N 项」与文档比对——**加行 = 改验收契约，需用户签字**；加行后预判立刻红（L4 未修），按既有预案"门禁独立 commit、红了可 revert、不放宽判据"执行。
- **检疫联动**：BUG-L5-001 检疫 **2026-10-19 到期（5 天）**。规则已写死"不自动续期"：L5 修好 → 解除检疫、恢复回归判读；没修好 → 延长检疫并升优先级，留带 commit 绑定的判读记录。

### P0-2 · L5 BUG-L5-001 修复（1-2 天；前置已就绪，见 §4）

- **方案 B（已拍板未实施）**：probe 分支接 `RacingLine.brake_distance()` 替换瞬时余隙二次式，用按 μ 分档的 AI a_brake（L5≈13.7，抱死风险单独评估——100km/h 档台架已实测抱死）。
- **方案 A（止血）**：`PROBE_MIN_KMH=6.0` 地板，与 queue 分支对称（注释里逐字描述过本死锁却没同步，属设计疏漏）。
- **方案 C**：probe 盒改车头朝向（先出对照实现再合）；动态路障相位调整**独立 commit**。
- **顺带**：brakebench 输入态 flake 加固 3 行（`step1d-abrake-truth.md` §5 diff，待签字）——handbrake 绑物理空格、失焦会清输入态。
- **验收门**：`opponents -Level 4` 连跑 3 次冷启动：≥1 圈、自救 0、未出界，且**不靠检疫规则判过**。

### P0-3 · L4 横向控制修复（1-3 天；与 P0-2 严格串行，禁并行）

- **根因已判决**：规划可达性问题——高速段 0.011 m/m × 45m 前瞻 ≠ 2m 变道；台架证明这不是物理上限而是"77% 帧不打舵"的实现值。7 轮取证已自行证伪三个假设（走廊/横跳/打舵门限）——**豆包的警告是对的：继续只读取证就是原地打转**。
- **方向**：换道前瞻改**时间制** + 横向加速度闭环（用 steerbench 传递函数反推舵角）；方向盘权限、死区、`max_steer`、横向辅助力**一律不碰**（反模式清单，过往实验证明会把车锁在护栏上）。
- **验收门**：`lap -Level 3` 与 `opponents -Level 3` 各连跑 3 次冷启动：卡住事件 = 0、非预期复位/瞬移 = 0、保留完整日志与截图。
- ⚠ **与 P0-2 同链路**（ai_opponent 限速链 + racing_line），Gemini 这点说得对：**不能并行**，否则 A/B 取证互相污染。

### P1-1 · 当前 HEAD 全量 19 项重跑 + 证据绑定（0.5 天，错峰执行）

- 最近一次完整结果停在 2026-09 且无 HEAD 绑定；`baseline-all-checks.log` 绑的是 `44352f85`（18/19）。当前 HEAD `f999af1` 没有全量回执。
- ⚠ 两个注意：① **lap 检查双稳态**——同代码两跑会稳定落在 12956/13460/17092 三种日志规模之一，先跑一次"同代码两跑"确认所处模式再解读；② 并行会话在跑验收时会改变机器负载，**错峰进行**。

### P1-2 · 内容债（P0 收敛后再动；勿与 P0 混提交）

- 五关从 ellipse 占位 → 真赛道（直道/扫弯/发夹/S 弯组合）；**L2 角度序列先重做**（340m 残差，工具已判负长度）；README"5 关难度递进"的承诺目前是空话。
- 每关独特轮廓 + 闭环残差 ≤0.1m + 每关 lap 稳定跑完。

### P2 · 体验与发布（不阻塞 P0/P1）

- **音频接线**（四份评审一致认为是"1.0 前性价比最高的体验项"）：rain_loop（记得把 import 的 loop 改 true）+ 引擎转速 / 胎噪打滑 / 碰撞 / UI 音。
- 发布面：GitHub Release + LICENSE + README 演示 GIF。
- 卫生：`godot-logs/` 286MB 定期清理（已 gitignore）；**命名规范经复核无问题**（§3.3 #18），无需改名；LFS 暂不需要（.git 仅 39MB）。

---

## 6. 新对话交接包

### 6.1 仓库状态（2026-10-14 19:21 实测）

| 项 | 值 |
|---|---|
| HEAD | **`c25698b`**（docs: HANDOVER 更新至批次⑤ 终态）——审查当时为 `f999af1`，变更明细见 §0 |
| 本地 vs origin/main | **0 / 0 一致**（铁律达标） |
| 工作区 | 干净；仅 `02-Blender建模/race_car.glb`、`racecar-3d.blend1` 未跟踪（Blender 中间产物，按惯例不入库） |
| 近 11 笔提交 | `c25698b` HANDOVER 终态 → `f7a94c9` 批次⑤ Quick 证据 → `5434252` push-log 勘误 → `7a77ac9` structcheck 强化 → `a8f395b` 批次⑤ push-log → `4d3a7cd` 批次⑤ 证据 → `25934e6` 批次⑤ AGENTS → `f8b2cb2` SPLIT-CHECKS-BASIC-005 → `a96ee5e` OpenRouter push-log → `18eeae0` OpenRouter 文档 → `522c983` OpenRouter 代码移除 |
| 审查期间变化 | 并行会话在我审查过程中提交并推送了批次④收尾 4 笔（`9628ea0`→`f999af1`）；此后又有批次⑤ + OpenRouter 移除 + HANDOVER 终态（见 §0）——**新对话开工前务必 `git log --oneline -5` 重新核对** |

### 6.2 并行会话避坑（本环境有 2+ 对话并行）

- **B 独占禁写**：`scenes/main.gd`、`scripts/checks/`、两份 `AGENTS.md`、`docs/testing.md`、`docs/push-log.md`、`04-Godot启动器/` 七契约（run-all-checks / run-check / check-docs / check-readme / lint-gdscript / parse-check / shoot）。
- **禁跑重活时段**：他会话跑验收/A-B 时，本会话不跑 Godot/Blender（lap 双稳态对机器负载敏感）；本会话不跑 `shoot.ps1`（会覆盖 `godot-logs/shot-0.log`）。
- **Git 纪律**：只 `git add <显式路径>`（永不 `-A`/`.`）；push 前先 `fetch`，落后就 `pull --rebase`；禁 `stash` / `checkout --` / `reset --hard`。
- **临时产物**：落 `godot-logs/` 用独立前缀（已 gitignore）。

### 6.3 项目铁律摘要（改代码前必读）

- `racing_line.gd` / `track_layout.gd` = 几何与限速唯一真相源，禁止复制公式。
- TDD：先写检查（红）→ 最小实现 → 绿 → 回归 → 提交；验收绑定 commit 号 + 工作区状态。
- 每步顺序：`lint-gdscript.ps1` → `parse-check.ps1` → 专项 → `run-all-checks.ps1 -Quick`。
- **不得**为变绿放宽判据/删测试/改阈值；加验收行 = 改契约，需用户签字。
- 反模式（禁）：收紧死区/打舵门限、抬 `max_steer`、加横向辅助力、抬 `GRIP_BASE`、删自救。
- 引擎 `E:\godot\Godot_v4.4.1-stable_win64.exe`；`-Level` 0 起（`-Level 3` = 荒漠 L4，`-Level 4` = 极地 L5）。
- Bash 不能调 pwsh；PowerShell 工具不回传 stdout 且长任务会被掐断——长验收必须 `run_in_background:true` + 输出落文件再看。

### 6.4 复现/验收命令

```powershell
pwsh -File 04-Godot启动器/lint-gdscript.ps1
pwsh -File 04-Godot启动器/parse-check.ps1
pwsh -File 04-Godot启动器/run-check.ps1 -Check opponents -Level 4   # L5（BUG-L5-001 相关）
pwsh -File 04-Godot启动器/run-check.ps1 -Check opponents -Level 3   # L4（当前无自动覆盖）
pwsh -File 04-Godot启动器/run-check.ps1 -Check lap -Level 3         # L4 自动驾驶
pwsh -File 04-Godot启动器/run-all-checks.ps1 -Quick                 # 15 项快跑
```

### 6.5 建议的新对话开场白（可直接复制）

```
接手 godot-racer。当前 HEAD c25698b（本地=origin/main，工作区干净，仅 02-Blender建模/
两个中间产物未跟踪）。先读仓库根 HANDOVER.md（跨平台交接说明，§1.5 = 最近两批，§7 = 待办）
与 REVIEW-AUDIT-2026-10-14.md（本文，四份外部评审的交叉实证 + 两个 P0 排序，§0 是基线刷新）。
已收尾：main.gd 的 --check= 函数体拆分全部迁完（checks 族六个模块；main.gd 659 行/17 func）；
OpenRouter 联网功能整体移除（检查项 26→24，19 项套件不变）。
两个 P0 全部属实且仍原样存在：L5 BUG-L5-001（probe 死锁，检疫 2026-10-19 到期、不自动续期）
与 L4 横向控制卡死。a_brake 真值已在本地 .workbuddy/evidence/step1d-abrake-truth.md
（L5 AI 折算≈13.7，抱死风险单独评估）——别重复"先测 a_brake"这个已完成前置。
待办按序：① opponents 门禁加 L4 覆盖（需签字，加行=改契约；04-Godot启动器/run-all-checks.ps1
的 opponents 行现为 lv=4）② L5 修复（方案 B：probe 分支接 brake_distance + PROBE_MIN_KMH 地板）
③ L4 换道前瞻时间制 + 横向加速度闭环（与②同链路，禁并行）④ 当前 HEAD 全量 19 项重跑绑定证据
（注意 lap 双稳态，先同代码两跑定模式）。铁律：不改判据、先红后绿、racing_line 单一真相源、
显式路径 add、push 前 fetch。请先确认方向再动手。
```

---

## 7. 已知风险与缓解

| 风险 | 信号 | 缓解 |
|---|---|---|
| 检疫 10-19 到期未处理 | 日期到 | 规则已写死"不自动续期"；与 P0-2 修复联动决策 |
| L4 第 8 轮取证仍原地打转 | 又一轮只读插桩 | 豆包建议设"取证轮次上限，到点强制换方案"；本报告已把方向定为换模型而非继续取证 |
| P0-2/P0-3 并行导致 A/B 污染 | 日志互相干扰 | 严格串行；每个 commit 只变一个因素 |
| 加门禁行后全红 | run-all-checks opponents 失败 | 预期内（L4 未修）；独立 commit 可 revert；不放宽判据 |
| 并行会话改动基线与本报告不一致 | git log 对不上 | 开工前重新 `git log --oneline -5` + `git status` |
| 按外部评审过时待办重复劳动 | 又要"先测 a_brake" | 先查 `.workbuddy/evidence/`（gitignored，外部评审看不到） |

---

## 8. 审查边界声明

- 本报告为**静态实证审查**：未启动 Godot/Blender，未重跑任何验收；所有"属实/失实"判定均附可复现的文件证据（路径:行号）。
- 并行会话在审查期间有提交（批次④收尾 4 笔），本报告原始基线以 19:21 实测为准。
- **2026-10-14 22:05 基线刷新**：§0 记录了刷新内容（`main.gd` 1613→659 行、OpenRouter 移除、HEAD → `c25698b`）；**§4 的两个 P0 与 §5 的排序结论未受影响**。
- 豆包评审的"工期估算"（13-24 活跃日）与 Gemini 的"6-9 周"量级一致，可作排期参考，非承诺。
