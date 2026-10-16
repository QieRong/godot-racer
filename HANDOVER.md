# Godot Racer · 跨平台交接说明

## 0. 当前接手状态（2026-10-16，L4 玩家自动驾驶专项收尾）

本节优先于下方 2026-10-14 的历史快照；实际 HEAD 仍以 `git log -1` 和远端核对为准。

- **当前玩家修复内容已提交并推送**：`57bdea470264f3e3031c14c02edc1ea1c67c7ce7`；
  `autopilot.gd` blob 为 `ebdf2e63b8737f13e32b35be18cb391551276a02`，
  与玩家三次实车验收及 2026-10-16 补跑的 AI/Quick 一致。此前 AI/L5 修复内容提交
  `d845ff5295bb18b517836cf2810088c7309840d1` 已推送，历史回执见
  `godot-logs/l4-recovery-content-push.log`；不要把文档收尾提交当作生产逻辑变化。
  当前 Git 与远端一致性须以本轮最终推送回执及现场查询为准；新对话读取 `NEXT_SESSION_PROMPT.md`。

- **L4 新基线已取证并推送**：干净的 `4dbc98a` 上 opponents L4 为 15527 帧、1 圈、
  自救 9 次，FAIL。旧 11 次不属于当前版本。证据/圆弧红用例提交 `ed7802c`，
  推送后核对本地 = origin = 实际远端，0/0，回执 `godot-logs/l4-red-push.log`。
- **L4 AI 数值回归已完成**：修正目标视线角到轮舵角的曲率换算；选道与排队共同覆盖
  实测跟踪偏差带。第一版只修曲率虽然 L4 三跑过，但使 L5 新卡点自救 1 次，已保留失败记录。
  第二版 L4 三跑 7968/7968/7815 帧、零自救；L5 三跑 10526/10544/10534 帧、零自救，均 1 圈未出界。
  L1 aidiag 已通过（贴限速 63.6%），Quick 15/15、EXIT=0，串行回归已记录 DONE EXIT=0。
  版本绑定与完整证据见 `godot-logs/l4-current-report.md`、`l4-envelope-*` 进度日志。
- **玩家 L4 自动驾驶已修复并通过三次冷启动**（2026-10-15）：有真实障碍的自动驾驶分支
  改用共享曲率连续转向 + 基于 `RacingLine` 现有限速的收油/刹车，只经真实 Input 链。
  用户已明确授权「仅该分支」绕过旧 ±0.06 二值门限；无障碍分支、手动驾驶、车辆参数、
  自救与验收判据原样未动。lap 三次均为 3 圈、卡住 0、复位 0（138.0 / 138.0 / 137.9s），
  对照归档基线：卡住 3→0、疑似复位 5→0、碰撞 7→1、入弯速度 205→107.7km/h。
  设计提案 `godot-logs/l4-autopilot-control-proposal.md` 保留为记录。
  2026-10-16 补跑：AI opponents L4 为 7965 帧、L5 为 10528 帧，均 1 圈、零自救、未出界，
  两份独立日志均 `[CHECK] 完成`、`DONE EXIT=0`；Quick 15/15、`DONE EXIT=0`。
  玩家有效画面已拍到先跨起点后 arc260.33、117.19km/h、偏离中心线 3.56m、车头夹角 6.98°、
  四轮接地，已人工看图；但截图进程在保存后退出时返回 `-1073741819`，故不算退出码为 0 的截图验收。
  三次截图尝试、延迟退出与兼容渲染尝试均保留，见 `godot-logs/l4-current-report.md`。
  ⚠ 帧率默认 60 + 菜单切换（用户已选）尚未实施，且会改变机器负载，
    因 lap 验收为双稳态，上述日志**不能**沿用作改帧率后的证据。
- 工作期间另出现 `godot-racer/models/environment/` 未跟踪素材，非本批创建；保留、不混入本批提交。
- WorkBuddy 新增审计 `godot-racer-audit-2026-10-15.html` 以旧 `d9de962` 加未提交工作区为基线，
  其中“L4 AI 仍卡死”“玩家分支未入库”等说法已过时；其余建议作为待核查线索，未自动改玩法或集成资产。
- **重启恢复后已修正取证工具**：玩家旧进度回执的 PASS=True 为误报，原始 lap 日志实际
  完成 3 圈但卡住 3 次、疑似复位 5 次，明确 FAIL。修正回执扫描显式失败与脚本错误，
  六条先红后绿；正确回执为 `l4-player-receipt-fixed-progress.log`，DONE EXIT=1 是预期结果。
  玩家圆弧夹具补齐 EngineSound 与 road_length 后，干净红灯仍为 -0.29375rad vs -0.01831rad，
  EXIT=1、无脚本错误；见 `l4-player-circular-clean-red.log`，正式 autopilot 未改。
- **旧截图无效**：`l4-final-pass.png` 拍到出生点 arc≈1803.62，不证明越过卡点；旧 DONE 仅代表
  保存图片成功。截图夹具已补“先跨过起点，再到 arc260–280”的守卫。
  有效补图 `l4-recovery-pass-valid.png`：arc260.47、121.69km/h、0 自救，已检查车辆在路面；
  `l4-recovery-visual-batch-progress.log` 最终 DONE EXIT=0。此前中断与启动期访问冲突各自保留。
- **本轮收尾边界**：用户要求先修紧急问题，再新开对话；本轮收尾回执、夹具、截图与文档，
  保留已完成的实车回归，不重复整个修复流程。玩家控制律替换仍须明确例外授权；雨声未接线。

- **opponents 的 L4 自动覆盖已补齐（用户签字）**：全量套件 **20 行**，其中
  opponents 分别跑 `lv=3`（L4）与 `lv=4`（L5）；Quick 仍 **15 行**，游戏检查入口仍 **24 个**。
  两关日志分别为 `godot-logs/check-opponents-L4.log` / `check-opponents-L5.log`，
  `-Only opponents` 会串行跑两关，任一关红灯使套件退出 1，检疫不豁免失败。
- **2026-10-14 22:53–23:11 实测**：基线 `18b2069` + 本批工作区改动；五道闸门 EXIT=0，
  Quick 15/15；opponents：L4 FAIL（15984 帧、1 圈、自救 11 次），L5 本次 PASS
  （10974 帧、1 圈、自救 0 次），套件 EXIT=1。覆盖/失败传播断言 19 条全绿，
  对旧脚本先跑红（14 条失败）。证据统一使用 `godot-logs/gate-l4-001-*` 前缀。
- **L5 BUG-L5-001 已修复并解除检疫**：probe 走 `RacingLine.brake_distance()` 反查、
  6km/h 调整地板；执行层在制动距离耗尽时绕过巡航死区，使用实测标定制动力 30、
  保守减速度 11.3m/s²。没有外推雪地 AI 55 的能力，没有改转向、抓地或自救。
  三次独立冷启动分别 **11323 / 11331 / 11321 帧，均 1 圈、零自救、未出界**；
  补充测试 19/19、五道闸门 EXIT=0、Quick 15/15、L1 aidiag 通过。
  截图与同帧日志确认 AI 以 41.69km/h 越过旧卡点。证据与版本绑定见
  `godot-logs/l5-final-report.md`；原 Quick 中断记录保留，完成结果取 `l5-resume-*`。
  内容提交 **`ff18a0233639f598892d7f1e4cff91e41741fa3c`** 已推送；14:14:29 +08:00
  核对本地 = origin = 实际远端，0/0。此后仅有文档收尾提交，实际最新 HEAD 以 Git 为准。
- **上一轮用户确认的边界：L5 收尾、更新交接后暂停，由用户新开对话**。
  下一项是 **L4 横向控制**，必须先在当前 L5 修复代码上重建 L4 基线；
  旧 L4 的 11 次自救不是本次代码的测量结果。L4/L5 取证继续严格串行。
- **LICENSE 已补录**：`f78882d`，自有代码采用用户选择的 MIT；第三方素材单独列入
  `THIRD_PARTY_NOTICES.md`。雨声为用户从 SoundDino 下载 MP3 后转 OGG，
  单条下载页仍未知，不套用 MIT、不擅自替换音频；雨声接线留待后续。
- `REVIEW-AUDIT-2026-10-14.md` 已在 `18b2069` 入库；两个 Blender 中间产物继续不入库。
- 上述 GATE-L4-001 批次只改套件与文档；本次另修 AI probe。全量 **20 行尚未整套重跑**，
  本次未跑 L4 opponents、长时 lap/stress（范围限定 L5，AI 专项三跑 + Quick + L1 aidiag）。
  雪地 100km/h 抱死非线性仍是独立风险，不宣称已验证全部速度域。

> 生成时间：2026-10-14 18:40 (GMT+8)
> 修订：2026-10-14 19:16 —— **批次④ 的三条遗留（①②③）已全部闭环**，本文件按最终状态重写。
> 修订：2026-10-14 21:50 —— **批次⑤（SPLIT-CHECKS-BASIC-005）已完成并推送**，`main.gd` 的
>   `--check=` 函数体拆分**全部收尾**；**OpenRouter 联网功能已整体移除**。本文件按最终状态重写。
> 用途：给**新平台的 AI** 在零历史上下文下快速、准确地接手本项目。
> 阅读顺序：先 §1 §1.5（状态）→ §4 §6（工作方式与铁律）→ §7（待办）。

---

## 1. 一页速览

| 项 | 值 |
|---|---|
| 项目 | Godot Racer —— Godot 4.4.1 单机 3D 赛车（5 关 / AI 对手 / 天气 / 验收驱动的车辆物理） |
| 仓库根 | `D:/桌面/DSH-Work/data-analysis`（**仓库根 == 工作区本身**） |
| Godot 工程 | `godot-racer/`（即 `res://`） |
| 引擎 | `E:\godot\Godot_v4.4.1-stable_win64.exe`（同目录另有 `_console.exe`） |
| 远程仓库 | `github.com/QieRong/godot-racer.git` |
| 当前 HEAD | L4 基线/红用例提交 `ed7802c` + 本次修复收尾；实际最新提交看 `git log -1`。L4 实车验收绑定 `ed7802c` + 工作区，生产 blob 与最终结果见 `godot-logs/l4-current-report.md`，不冒称干净提交复跑 |
| **工作区状态** | 交接目标为已跟踪文件干净；保留 `02-Blender建模/race_car.glb`、`02-Blender建模/racecar-3d.blend1` 两个中间产物，以及用户未跟踪的 `godot-racer/models/environment/` 包；三者均不随本批入库 |
| 本地 vs 远端 | 每次收尾核对 `HEAD` / `origin/main` / `ls-remote` 三者相等，`rev-list --left-right --count origin/main...HEAD` 应为 `0<TAB>0`；实际结果见最新推送记录 |
| 开发阶段 | 制作（Phase 5）；打磨已局部开始；发布（Phase 7）未启动 |
| 平台 | Windows + Git Bash；开发/验收走 CLI + PowerShell 脚本，**不依赖编辑器** |

---

## 1.5 最近两批（OpenRouter 移除 + 批次⑤）已固化并推送（2026-10-14 晚）

| commit | 类型 | 内容 |
|---|---|---|
| `522c983` | `refactor(openrouter)` | **OpenRouter 联网测试功能整体移除**（用户签字「彻底移除功能」）——清单见 §7 |
| `18eeae0` | `docs` | 全面移除 OpenRouter 提及（`README.md` 删「配置（可选）」整节 / 两份 `AGENTS.md` §1·§11 / `docs/testing.md` / `docs/engineering-notes.md` / 本文件） |
| `a96ee5e` | `docs` | `push-log.md` 落「OpenRouter 整体移除」批记录 |
| `f8b2cb2` | `refactor(main)` | **SPLIT-CHECKS-BASIC-005（批次⑤·压轴）** —— 基础验收族 + 跑圈/压测/反向族外迁至 `scripts/checks/basic.gd` + `lap.gd`；`main.gd` **1613 行/36 func → 659 行/17 func** |
| `25934e6` | `docs(agents)` | 两份 `AGENTS.md` 同步批次⑤（§1 核心代码列表 / 第 8 条超限名单剔除 `main.gd` / §2.1 进度表·现状·await 钉死行 / §2.4 模块清单） |
| `4d3a7cd` | `test(checks)` | 批次⑤ 证据 `git add -f` 入库（structcheck 红→绿 / 文本级反向核对 / A/B 闭环 / 全量验收） |
| `a8f395b` | `docs(push-log)` | 批次⑤ 推记录 |
| `7a77ac9` | `test(checks)` | 收尾追加：structcheck 补「模块 ≤1000 行」+ 钉死三条机器断言，红→绿重跑 |
| `5434252` | `docs(push-log)` | `push-log.md` 勘误（两模块实测 608 / 598 行；structcheck 断言数 15→17） |
| `f7a94c9` | `test(checks)` | 收尾追加：`run-all-checks -Quick` 复跑 15/15 证据 |

**批次⑤ 验收回执（已由接手方在 `f7a94c9` 上独立复跑确认）**

- 本地 `main` ≡ `origin/main` ≡ `git ls-remote origin refs/heads/main` = **`f7a94c9`**，`rev-list --left-right --count` = **`0 0`**。
- 两份 `AGENTS.md` **md5 一致** = `d055346ce4c0abcf4c25e33c1fdc86a8`。
- 五道闸门全绿：`lint-gdscript` **0** / `parse-check` **0**（31 个 `.gd` 走 Godot 解析器）/ `check-docs` **0**（19 项 / Quick 15 项）/ `check-readme` **0**（24 个检查项）/ `check-dup-source` **0**（5 项通过 / 0 项不一致）。
- `run-all-checks.ps1 -Quick` → **15/15 通过 ✔**（证据 `godot-logs/split-checks-basic-005-quick-append.log`，`QUICK_EXIT=0`）。
- **structcheck 各 17 项断言，先红后绿**：红（对迁移前 1522 行原码跑）= basic 14 项失败 / lap 15 项失败；绿（真工程）= **17/17、17/17**，EXIT=0。
  其中本批新钉的三条机器断言（给新平台 AI 复用）：
  ① **await 数守恒**：`basic` 恰 **12** = 8 `_physics_frame.call` + 3 `_tree.process_frame` + 1 族内调用；`lap` 恰 **8** = 6 `_physics_frame.call` + 1 `driver.call` + 1 族内调用。
  ② **模块内不得出现** `get_node(` / `get_tree(` / `get_viewport(` / `get_world_3d(` / `preload("res://scenes/main.gd")` 中任意一个（引用一律经 `setup()` 注入）。
  ③ **`_tree` 必须显式类型化为 `SceneTree`**，且成员访问全落在 SceneTree API 白名单（实测用到 `get_nodes_in_group` / `paused` / `process_frame` / `root`，无越界）。
- **A/B 舞步**：`reverse` 纯函数段 **逐行 diffcount = 0**（14 行）；`lap` 按 AGENTS §4.3 走**结构三重判据**（① 行数一致 ② 判定串集合一致 ③ 骨架多重集一致）**全过**；同代码残差 `work1↔work2 = 1` / `head1↔head2 = 1`，跨组最大 **1** ⇒ 残差即物理浮点噪声底，**迁移未引入可辨识差异**。
- **规模**：`main.gd` **659 行 / 17 func**；`basic.gd` **608 行 / 11 func**；`lap.gd` **598 行 / 10 func** —— 两个新模块均满足「新建文件 ≤1000 行」的向前约束。

**批次⑤ 两个设计判断（与初版任务书字面不同，已复核采纳，新平台 AI 别再翻案）**

1. **helper 归属「放消费方」**：`_cp` 全库唯一调用点是 `_check_escape`（escape 在 basic 族）→ 归 `basic.gd`；`_find_wrong_way_panel` 唯一调用点是 `_check_reverse_e2e`（reverse 在 lap 族）→ 归 `lap.gd`。任务书字面把两者写反，照字面放会让两个模块**互相注入对方 Callable（成环）**或**被迫复制第二份（违「单一真相源」）**。判据：**helper 永远跟它的唯一消费方走**。
2. **场景能力「注入 `SceneTree` 引用」而非逐项做 Callable**：basic/lap 族需要 `process_frame` 信号、`paused` 标志、`get_nodes_in_group("checkpoints")`、根视口 `push_input`。逐项 Callable 要给 `main.gd` 加 4 个新 helper；改注入一个 `SceneTree`（**0 个新 helper**）—— 与 `ai.gd` 注入 `World3D`（`get_world_3d()`）**同属「注入引擎对象」，不是注入场景节点、不是 `get_node`、不反向持有场景**。
   已核实等价性：`main.gd` 挂在场景根节点 `Main`（`main.tscn` 里 `Main` 是根；`Minimap/SubViewport` 是它的**子**节点、不是祖先）⇒ 迁移前的 `get_viewport().push_input(ev)` 返回的就是根 Window，模块里 `_tree.root.push_input(ev)` 是**同一个对象**。
   另新增两个必需 Callable：`_add_child`（stress 要 `add_child(driver)`）与 `_mark_keep_alive`（模块不得直接写 main 的 `_keep_alive_after_check`）—— 与 `main.gd` 既有注释口径一致（「模块不得持有场景树所有权 / 不得直接写 main 成员」）。

---

## 2. 批次④ 已全部固化并闭环（2026-10-14 一次做完）

原本滞留在工作区的整套批次④成果，已按批次①-③ 惯例拆笔提交并推送 —— **共 7 笔、三批推送**：

| commit | 类型 | 内容 |
|---|---|---|
| `4e524fb` | `fix(checks)` | **GATE-REPAIR-001** —— 台架满舵判据 `0.45`→真源 `0.5`（`bench.gd`，用户签字）+ `push-log.md` 措辞避让（清 `check-docs` 红） |
| `0fc8eb2` | `refactor(main)` | **SPLIT-CHECKS-ENVPHYS-004** —— 环境物理验收族外迁至 `scripts/checks/env_phys.gd`；`main.gd` 2577 行/53 func → **1613 行/36 func** |
| `fcfd541` | `docs(agents)` | 两份 `AGENTS.md` 各 +1 行：新增第 8 条「单个代码文件 ≤1000 行」 |
| `060b738` | `docs` | 本文件 `HANDOVER.md` 首次入库 |
| `ba5e31f` | `docs(agents)` | **批次④ AGENTS 正文同步** + 第 8 条口径澄清（见下） |
| `9628ea0` | `test(checks)` | **批次④ A/B 闭环（结构判据）** + `godot-logs/` **56 个证据文件** `git add -f` 入库 |
| `adb668f` | `docs` | `push-log.md` 落批次④ 批记录（记录表 2 行 + 内容段 + 未推送节） |

推送区段：`3298de4..060b738` → `060b738..9628ea0` → `9628ea0..adb668f`（+ 本次收尾提交）。

**未跟踪、按惯例不入库**：`02-Blender建模/race_car.glb`、`02-Blender建模/racecar-3d.blend1`（Blender 中间产物）。

### 三条遗留的闭环结论

1. **A/B 判据 → 已结案（用户签字「按结构结案」）**
   - 原 `split-checks-envphys-ab-analyze.py` 的**逐行**判据：`flip` / `phys` / `weather` /
     `friction` 四项跨组**零差**；`wallslide` / `stuck` 残差 1~2 / 7~12 行 → 判 ✘。
     **该记录保留不覆盖**（`split-checks-envphys-ab-analysis.log`）。
   - 新增 `godot-logs/split-checks-envphys-ab-closure.py`，按 AGENTS §4.3「非确定性检查只比结构」
     重判：① 行数一致 ② 判定串集合一致 ③ **骨架多重集一致**（数字全部抹为 `#` 后逐对相同，
     即无任何行被增删/改文案/改逻辑）→ **6/6 通过 ✔**（`-ab-closure.log`，EXIT=0）。
   - **排除迁移成因的关键反证**：同代码对照组自身非零且量级相当 —— `stuck` 同代码
     **m1↔m3 = 12 行** == 跨组最大差 12；`wallslide` 跨组 2 ≤ 同代码 `c1↔c2` = 2；
     且 `m1↔m2` 与 `m1↔c2` 出现**逐字相同的 ±1~2 帧相位移位块**。残差全部是物理浮点抖动
     （pos 第 4~6 位小数、侧倾 0.1°、km/h 0.1、命中距离 0.01m）。
   - 复现命令：`python godot-logs/split-checks-envphys-ab-closure.py`（退出码 0 = 通过）。
2. **`AGENTS.md` 第 8 条（≤1000 行）→ 口径定为「向前约束」**：只约束**新建文件与本次改动的
   文件**；现存超限文件登记为**历史遗留**、随 `SPLIT-*` 批次逐步收敛、**不阻塞其修复性
   提交**。**现状（2026-10-14 晚，批次⑤ 后）只剩 3 个**：`scripts/ai_opponent.gd` 1668 /
   `scripts/vehicle.gd` 1413 / `scripts/checks/env_phys.gd` 1111。
   `scenes/main.gd` 已由批次⑤ 从 1613 行**收敛到 659 行**，**已脱离超限名单**；且
   `ai_opponent.gd` / `vehicle.gd` 属核心玩法文件（§2.2 禁大重构），**不要为凑行数去拆它们**。
3. **批次④ 的 AGENTS 正文同步 → 已补**：§1 核心代码列表（+ `env_phys.gd`）/ §2.1 进度表
   （+ SPLIT-CHECKS-ENVPHYS-004 行、后续候选、现状行 1613 行/36 func）/ §2.1 checks 族 await
   钉死行 / §2.4 模块清单 九→十 + await 约定行（env_phys 恰 29 处）。两份 AGENTS.md 逐字节一致。

> ⚠ 本项目**不把 `godot-logs/` 当临时目录**：按批次惯例，每批的结构校验脚本/日志、A/B 舞步
> 与原始样本、文本核对脚本、闸门证据都会 `git add -f`（该目录被 `.gitignore` 忽略）强制入库。
> 本批新增 56 个。

---

## 3. 项目是什么（结构与职责）

```
godot-racer/
├─ scenes/        main.tscn(主场景) / menu.tscn / race_car.tscn / track.tscn / main.gd(编排)
├─ scripts/       车辆、AI、赛道、物理、UI、验收模块（见下表）
│   └─ checks/    layout.gd / bench.gd / ai.gd / env_phys.gd / basic.gd / lap.gd  ← 验收族外迁模块（6 个，已迁完）
├─ data/levels/   level_1.tres … level_5.tres（关卡参数契约）
├─ assets/        audio/(rain_loop.ogg) textures/(6 张 PNG)
├─ models/        race_car.glb（车辆模型，5824 tri / 预算 6000）
├─ docs/          testing.md / engineering-notes.md / push-log.md / plans/ / architecture/
└─ tools/         构建后处理与诊断脚本
04-Godot启动器/     18 个 .ps1 + 4 个 .js + 4 个 .bat —— **验收契约脚本所在地**
02-Blender建模/     build_racecar_3d.py（车辆几何唯一来源）+ 校验 + 渲染
03-2D赛车图 / 01-参考 / godot-logs(证据目录，入库靠 git add -f) / screenshots/
```

**核心文件职责（改代码前先看这张表，别把逻辑塞进 `main.gd`）**

| 需求 | 去处 |
|---|---|
| 车辆动力/转向/恢复 | `scripts/vehicle.gd` |
| AI 行为 | `scripts/ai_opponent.gd` |
| 赛道几何 DSL / 闭环 | `scripts/track_layout.gd` |
| **竞速线 / 限速 / 刹车 / 转向权限纯函数** | `scripts/racing_line.gd`（**唯一真相源**） |
| 关卡字段 | `scripts/level_config.gd` + `data/levels/*.tres` |
| 天气 / 环境视觉 / 粒子 | `scripts/environment.gd` |
| 对手生成 / 发车时机 | `scripts/opponent_spawner.gd` |
| 场景装配 / 验收调度 | `scenes/main.gd`（**只做编排，别扩张**） |
| 验收族实现 | `scripts/checks/<族>.gd` |
| 进程 / 启动 / 日志 | `04-Godot启动器/` |

**五关与天气**（以 `.tres` 为准）：L1 clear / L2 clear(sunny) / L3 rain(夜) / L4 sand(荒漠) / L5 snow。
（历史需求文档曾写 L2 雨战 / L3 雪地 / L5 极地，**已废弃，以 `.tres` 为准**。）

---

## 4. 验收体系（接手本项目最重要的认知）

本项目**不是**"改完手动玩一下"，而是**验收驱动**：游戏逻辑与验收逻辑共用同一份核心代码，全部走 CLI。

### 4.1 三道文本闸门（秒级，改文档后必跑）

```powershell
pwsh -File 04-Godot启动器/check-readme.ps1     # README/docs 与项目对照（路径/检查项名/项数/关卡数）
pwsh -File 04-Godot启动器/check-docs.ps1       # 文档内部一致性（块数 ↔ 计数常量；「全部 N 项」↔ run-all-checks 项数）
pwsh -File 04-Godot启动器/check-dup-source.ps1 # 单一真相源守卫（常量/公式是否有副本）
```

### 4.2 引擎验收（`--check=X --Level=N` 驱动）

```powershell
pwsh -File 04-Godot启动器/lint-gdscript.ps1
pwsh -File 04-Godot启动器/parse-check.ps1
pwsh -File 04-Godot启动器/run-check.ps1 -Check <项> -Level <0-4>
pwsh -File 04-Godot启动器/run-all-checks.ps1 -Quick     # 15 行；不带 -Quick 为 20 行（含慢项）
```

当前 **24 个检查项**：`aidiag aistart avoid brakebench enclosure escape flip friction lap layout minimap obstacles oob opponents pause phys reset resetkey reverse steerbench stress stuck wallslide weather`。
`-Quick` 会**跳过** `slow=$true` 的 `aidiag / stress / opponents / lap`。

### 4.3 环境坑（踩过的，务必照做）

- **Git Bash 里不能调 `pwsh`**（安全策略拦）→ 一律用 PowerShell 工具/终端。
- **PowerShell 工具不回传 stdout**，长任务会被内部超时掐断 → 长验收必须后台跑 + 输出重定向到文件再读。
- `run-all-checks.ps1` 顶部自带强制 UTF-8；否则本机 gb2312 下 `✔` 不可表示 → **全线假红**。
- engine headless **不会自动生成 `.uid`** → 新模块的 `.uid` 手写（`uid://` + 13 位、不碰撞即可）。
- `shoot.ps1 -Out` **必须绝对路径**（相对路径必失败）。
- `godot-logs/` 整目录被 `.gitignore` 忽略 → 证据文件入库需 `git add -f`；裸目录名 `git check-ignore` 不命中。
- 仓库 `core.autocrlf = true`：用 `git show HEAD:<path> > <path>` 还原文件时工作区会按 LF 写出，
  `git status` 可能短暂报 `M` 而 `git diff` 为空（内容等价）—— **以 `git diff` 为准**。

---

## 5. SPLIT-* 拆分进度（`main.gd` 拆解工程）

`main.gd` 历史上是巨型文件，已按批次外迁。**已完成 11 步，`--check=` 函数体拆分全部收尾 ✅**：

| 步骤 | 去处 | 状态 |
|---|---|---|
| SPLIT-ENV-001/002 | `environment.gd` / `engine_audio.gd` | ✔ |
| SPLIT-L4DIAG-001 | `l4_debug_diag.gd` | ✔ |
| SPLIT-AUTOPILOT-002 | `autopilot.gd` | ✔ |
| SPLIT-OPPONENT-001 | `opponent_spawner.gd` | ✔ |
| SPLIT-SCREENSHOT-001 | `screenshot_mode.gd` | ✔ |
| SPLIT-CHECKS-LAYOUT-001（①） | `scripts/checks/layout.gd` | ✔ `13cb52f` |
| SPLIT-CHECKS-BENCH-002（②） | `scripts/checks/bench.gd` | ✔ `f6033f3` |
| SPLIT-CHECKS-AI-003（③） | `scripts/checks/ai.gd` | ✔ `0771984` |
| SPLIT-CHECKS-ENVPHYS-004（④） | `scripts/checks/env_phys.gd` | ✔ `0fc8eb2`；A/B 已按结构判据结案 ✔ |
| SPLIT-CHECKS-BASIC-005（⑤） | `scripts/checks/basic.gd` + `scripts/checks/lap.gd` | ✔ `f8b2cb2`（**checks 族最后一批，已收尾**） |

**拆分铁律**：`match _check:` 分派口 + 三个计数常量 `LAYOUT_ELEV_CASES` / `LAYOUT_RACING_CASES` / `REVERSE_CASES` **永久留守 `main.gd`**（两道闸门直接读它们）→ 闸门脚本零改动；只外迁函数体。模块**无 `class_name`**，消费方 `const X := preload("res://scripts/checks/x.gd")`；依赖经 `setup()` 注入；**模块内 `await` 数 = 迁入前，一拍不加**（多一层协程会让 physics_frame 恢复差 1 帧）。各模块 await 数：`layout` 0 / `bench` 4 / `ai` 8 / `env_phys` 29 / **`basic` 12 / `lap` 8** —— 由各自 structcheck 机器钉死。

**⑤ 拆分（已落地）**：原待迁 17 个函数约 1008 行，**超过「新建文件 ≤1000 行」的向前约束**（该条不豁免新文件），故按族拆成两个模块（每个都是 0 复制、0 跨模块 Callable 注入）：
- `scripts/checks/basic.gd`（**608 行 / 11 func**）—— 场景 / 边界 / UI：`enclosure`、`reset`、`resetkey`、`oob`、`minimap`(+`_check_minimap_obstacles`)、`escape`(+`_cp`)、`pause`(+`_menu_press_escape`)
- `scripts/checks/lap.gd`（**598 行 / 10 func**）—— 跑圈 / 压测 / 反向：`lap`(+`_reset_loop_hit`)、`stress`、`reverse` 族（`_reverse_call` / `_rev_dot` / `_reverse_case` / `_check_reverse_e2e` / `_find_wrong_way_panel`）

⚠ 注意与初版任务书的**两处差异**（见 §1.5 末「两个设计判断」）：`_cp` 归 basic、`_find_wrong_way_panel` 归 lap（**跟消费方走**）；场景能力注入 **`SceneTree` 引用**而非 4 个 Callable。`REVERSE_CASES` 仍留守 main 并由 `setup()` 注入 lap 模块；`_sample_physics_ms` / `_avg_physics_ms` 属 main 共享采样器，**未搬**，按 Callable 注入。

---

## 6. 项目铁律（违反即返工）

1. **`racing_line.gd` / `track_layout.gd` = 几何与限速唯一真相源，禁止复制公式**；新逻辑写成 `racing_line.gd` 纯函数。
2. **TDD**：先写检查（红）→ 最小实现 → 绿 → 回归 → 提交；**验收必须绑定 commit 号 + 工作区状态**。
3. **不得为变绿放宽判据 / 删测试 / 改阈值**。改验收契约（闸门脚本、判据值）**必须用户签字**。
4. **每步验证链**：`lint` → `parse-check` → 专项 `run-check` → `run-all-checks -Quick`；**改文档后必须复跑三道文本闸门**。
5. **GitHub 同步铁律**：每完成一步必须 `git push`，**本地 `main` 始终 = `origin/main`**；报告里要报"本地 vs origin 是否一致"。
6. **单个代码文件 ≤1000 行（向前约束）**：只约束新建文件与本次改动的文件；现存超限文件为历史遗留清单（见 §2 第 2 条），随 `SPLIT-*` 收敛。
7. 两份 `AGENTS.md`（根 + `godot-racer/`）**必须逐字节一致**（有机器校验看住）。
8. 反模式（禁）：收紧转向死区/打舵门限、抬 `max_steer`、加横向辅助力、抬 `GRIP_BASE`、删自救。

---

## 7. 待办清单（按优先级）

| 优先级 | 事项 | 说明 |
|---|---|---|
| ✔ 已完成 | **SPLIT-CHECKS-BASIC-005（⑤，最后一批）** | ✔ `f8b2cb2`（+ 收尾 3 笔至 `f7a94c9`）；`main.gd` **659 行 / 17 func**，checks 族六个模块全迁完（见 §5） |
| ✔ 已完成 | **GATE-L4-001：opponents 增加 L4 覆盖** | 用户已签字；L4/L5 各一行、独立日志、原判据不变。全量 20 行、Quick 15 行；本次 L4 因自救 11 次报红，L5 单次通过，详见 §0 与本批证据。 |
| ✔ 已完成 | **L5 BUG-L5-001** | 2026-10-15 修复并解除检疫；三次冷启动零自救、19 条补充检查和回归通过，证据见 §0 与 `godot-logs/l5-final-report.md`。L5 恢复按原判据作为回归信号。 |
| ✔ 已完成 | **L4 玩家自动驾驶**（原 P0） | 2026-10-15 修复：有障碍分支连续转向 + 曲率限速收油/刹车，经真实 Input 链；绕开旧 ±0.06 门限由用户授权且仅限该分支。lap 三次 138.0/138.0/137.9s，均 3 圈、卡住 0、复位 0。玩家有效截图、AI 两关回归、Quick 尚未复跑，不扩大为整轮全绿。历史 0.011m/m 主要来自玩家路径，不套为当前 AI 实测响应。 |
| ✔ 已完成 | 素材管线 P0-a **LICENSE 补录** | `f78882d`：用户选择 MIT，根 LICENSE + THIRD_PARTY_NOTICES.md；第三方音频不套仓库许可，单条来源页仍待补。 |
| P1 | 素材管线 P0-b **雨声接线** | `assets/audio/rain_loop.ogg` 已入仓但未接线（import 的 `loop` 还是 `false`）；精确插点 `environment.gd` 的 `build_weather_particles` 之后，**零 `main.gd` 改动** |
| 暂不实施 | 素材管线 P0-c **LFS 迁移** | 本轮迁移前实测 `.git` **35.05 MiB**，没有立即迁移的收益依据；未来体积增长再量，不重写历史。 |
| ✔ 已完成 | 根目录 **REVIEW-AUDIT-2026-10-14.md 入库** | `18b2069`；它是历史审查记录，当前状态优先看本文件 §0。本地 `.workbuddy/evidence/step1d-abrake-truth.md` 是已完成的前置，勿重复测量。 |
| ✔ 已完成 | **OpenRouter 整体移除（2026-10-14）** | 用户签字「彻底移除功能」。删代码：`scripts/openrouter_client.gd`(+uid)、`tools/test_generator.py`、`04-Godot启动器/test-openrouter.ps1`、`openrouter.cfg.example`、本机 `openrouter.local.cfg`（真实 key，已被 gitignore、从未入库）；删检查项：`--check=openrouter` / `--check=models`（26→24）。文档全刷：`README.md`、`AGENTS.md §11`、`docs/testing.md`、`docs/engineering-notes.md`、`.gitignore`、`launcher-menu.ps1`。`data/ai_test_cases.json` 作为**离线确定性夹具保留**。 |
| — | 已决策**不做** | "正前方看全风镜"（需抬头盔→与挡风玻璃位置冲突）：**保持原样，只要不穿模**。v8 的 JOINT_GATE 65/65 已满足（无穿模）。`mat_glass_dark` 保持 0.25/0.04（玻璃镜面感是要的）。 |

---

## 8. 已知风险 / 陷阱

- **2026-10-15 新经验：后台启动不等于验收完成**。本轮 Quick 曾在第 10 项后中断，
  没有最终退出码；补跑另存 `l5-resume-*`。恢复会话时先查进程与 `EXIT` / `DONE` 回执，
  不把部分通过输出算作整套通过。直接运行单项 GDScript 时用同目录的 `_console.exe`，
  或 `Start-Process -Wait -PassThru` 读取退出码；直接调用 GUI `.exe` 可能提前返回、`$LASTEXITCODE` 为空。
- **AI 截图夹具**：`godot-logs/capture-opponent.gd` 直接加载 main，因此必须显式将 `--level`
  写入 GameState.chosen_level（正常 CLI 入口由菜单传递）。相机跟随 AI 时，左上 HUD 仍属于静止玩家；
  AI 的真实速度、弧长、自救计数见同帧 `[VISUAL]` 日志，不能把 HUD 的 0km/h 当成 AI 卡死。
- **建模前告知用户**：若后续确需使用 Tripo 制作或替换模型，先通知用户手动开启 Tripo 插件。
  L5 本轮无建模需求；MCP 仅按需做 API/解析诊断，不能替代 CLI 验收。
- **`lap` check 是「双稳态」**：同一份代码依机器负载会稳定产出不同规模的日志（诊断按墙钟打印）。**做 A/B 前必须先"同代码两跑"确认当前模式；不同模式的对比例子 = 无效证据。**
- **A/B 判据分两类**：日志**可逐行复现**的检查（`flip`/`phys`/`weather`/`friction`）→ 用逐行判据；**打印物理浮点、跨进程不可复现**的检查（`wallslide`/`stuck`，以及 L4 类）→ 按 AGENTS §4.3 **只比结构**（判定行逐字相同 + 逐类行数 + 允许 ±1 帧相位差），工具见 `godot-logs/split-checks-envphys-ab-closure.py`。
- **`check-docs` 的"计数契约"**：文档里「全部 N 项」字样会与 `run-all-checks.ps1` 的实际项数机器比对 —— **连引用旧措辞的叙述也会被误判**（批次④ 踩过一次）；往 `run-all-checks.ps1` 加检查项 = 改验收契约 = 需签字。
- **`check-readme` 的「反引号路径必须存在」会误伤散文**（2026-10-14 实证两次）：凡被 `` ` `` 包裹、且带 `scripts|scenes|tools|assets|data|docs|models/` 前缀 + `.gd|.tscn|.tres|.json|.py|.png|.glb|.md` 后缀的串，一律要求磁盘上真有该文件 —— **写"某文件已删"的叙述、或在 push-log 里列删除清单时，只要给它加反引号就判红**。规则：**删掉的路径一律不加反引号、且不带 `scripts/` 等前缀**（例：写成 `tools/test_generator.py，已删` 而不是带反引号的那串）。这和上一条是同一类自伤：**引述性文字被闸门当成断言扫**。
- **两道文本闸门的扫描范围（实测，改文档前先看）**：`check-docs` 扫 `README.md` + `godot-racer/docs/*.md`（**不递归**）+ `godot-racer/AGENTS.md`；`check-readme` 扫 `README.md` + `godot-racer/docs/*.md`（**不含 `AGENTS.md`**）。⇒ **本文件与根目录其它 md 天然逃过两道闸门**，可写真实数字与历史删除清单；但 `docs/plans/*.md` 与 `AGENTS.md` 的差异要心里有数（前者不被扫，后者只被 check-docs 扫）。
- **模块注入铁律（批次⑤ 定型，新平台 AI 照抄）**：验收族模块是 `RefCounted`、不在场景树上 ⇒ **模块内不得出现** `get_node(` / `get_tree(` / `get_viewport(` / `get_world_3d(` / `preload("res://scenes/main.gd")`，一切经 `setup()` 注入。**注入引擎对象是允许的**：`ai` 注入 `World3D`、`basic`/`lap` 注入 `SceneTree`（用 `_tree.paused` / `_tree.process_frame` / `_tree.get_nodes_in_group(...)` / `_tree.root.push_input(...)`）；**注入场景节点**则要写成 Callable（如 `_add_child` / `_mark_keep_alive`）。`_tree` 必须 `var _tree: SceneTree` 显式类型化。helper 跟**唯一消费方**走，别按族名直觉放。
- **本地有、远端看不到的证据**：`.workbuddy/evidence/`（被 gitignore）里有决定性前置数据，最典型是 `step1d-abrake-truth.md`（**`a_brake` 真值已于 2026-10-12 实测**：L3≈12.0-12.9 / L4≈12.2-12.9 / L5≈11.4-12.2 m/s²；L5 100km/h 实测**车轮抱死**，雪地档不得线性外推；文档旧假设值 6.0 **低估约 2 倍**）。**别重复"先测 a_brake"这种已完成的前置。**
- **`godot-logs/` 入库体量**：按批次惯例证据用 `git add -f` 强制入库，目前 **236 个文件**、单批最大的一批约 +91.5k 行（A/B 原始 `.out` 不入库、只入 `.log`）。本机实测 `.git` 仍仅 **35 MB**；如果将来觉得重，优先考虑压缩/裁剪旧的 A/B 日志，**不要**动 `docs/` 与闸门脚本。
- **不要用编辑器 MCP 改文件**：编辑器缓冲区滞后于磁盘，会按过期行号错位；本项目真相源在磁盘。
- **headless 跑 Godot 不生成 `.uid`**；新增 `.gd` 记得手写 `.uid`。
- **并行会话**：项目常有多个会话/代理同时开工，`main.gd`/`scripts/checks/`/两份 AGENTS 是共享文件；提交前先看 `git status`，`git add` **只加显式路径**（永不 `-A`/`.`）。

---

## 9. 接管第一步（建议动作序列）

1. `git log --oneline -10` + `git status` —— 按 §0 核对最新提交与工作区，不使用旧快照哈希作为预期；两项 Blender 中间产物保留，额外并行素材按实际 status 单列，不混入修复提交。
2. 先核对当前生产 blob 与最新完整回执，再按新改动选择最小验证；不把客户端重启当作重做已完成修复或整套回归的理由。五道闸门与专项旧结果必须保留版本绑定。
3. 读 `04-Godot启动器/` 里的契约脚本 + `godot-racer/docs/testing.md` + `godot-racer/docs/push-log.md`（后者有每批的完整记录），理解验收链。**若有 `REVIEW-AUDIT-2026-10-14.md`，先读它**（外部评审交叉实证 + 两个 P0 的排序，见 §7 末行）。
4. 从 §7 待办里挑一条开工；**每步走 TDD + 绑定 commit 号 + push**。
5. 若要做 §7 的 P0（两个缺陷），**先读 §8 的「本地有、远端看不到的证据」**，避免重复已完成的前置测量；且 **P0-2 / P0-3 必须串行**。

---

## 10. WorkBuddy 环境资产（独立 staging，未自动集成）

- 所有新资产产出位于 `D:/桌面/DSH-Work/godot-racer-assets-staging`；资产任务对原 Godot 工程只读，禁写、禁 git 写操作、禁自动复制或集成。
- Batch 1+2：L4 ruin_pillar_01 / sand_dune_01 / wind_rock_01，三角面 1128 / 656 / 672；L5 snow_pine_01 / snow_pile_01 / ice_spike_01，396 / 656 / 244。
- Batch 3：shared/guardrail_01.glb（120 面、4m 模块）和 start_gate_01.glb（108 面）；materials/l3_wet_road 为 StandardMaterial3D 湿路材质，roughness 图承载 0.06/0.09/0.58。
- 冻结风格：硬边平涂，每贴图 2–3 平色，纯 albedo、零法线、metallic=0，GLB roughness 0.30–0.95，多材质分件；不恢复旧需求表或候选清单中的法线/连续噪声建议。
- 规格：真实 GLB、每件 ≤5000 三角、米制 Y-up、底部 Y=0、贴图嵌入且 ≤1024²、无碰撞体；原项目既有 8 个用户 GLB 不重复制作。
- 已有交付报告：staging/reports/DELIVERY_REPORT.md、DELIVERY_REPORT_BATCH3.md，记录 Python GLB 解析、Godot 4.4.1 无头导入与运行时实例化通过；本轮仅只读核对报告与文件，未重新实测资产。
- 管线：E:/blender/blender.exe；source/asset_lib.py、verify_glb.py、gen_wet_roughness.py；独立 test_godot_proj/test_import.gd。无头导入的 Parameter "t" is null 按报告与运行时结果区分；GENERATED 图按 pixels→pack→colorspace，多 primitive 聚合尺寸/底部 Y。

*本文件是状态交接说明，不属于验收契约；最新现场以 Git、生产哈希及完整原始日志为准。*
