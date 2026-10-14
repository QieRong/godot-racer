# Godot Racer · 跨平台交接说明

> 生成时间：2026-10-14 18:40 (GMT+8)
> 修订：2026-10-14 19:16 —— **批次④ 的三条遗留（①②③）已全部闭环**，本文件按最终状态重写。
> 用途：给**新平台的 AI** 在零历史上下文下快速、准确地接手本项目。
> 阅读顺序：先 §1 §2（状态）→ §4 §6（工作方式与铁律）→ §7（待办）。

---

## 1. 一页速览

| 项 | 值 |
|---|---|
| 项目 | Godot Racer —— Godot 4.4.1 单机 3D 赛车（5 关 / AI 对手 / 天气 / 验收驱动的车辆物理） |
| 仓库根 | `D:/桌面/DSH-Work/data-analysis`（**仓库根 == 工作区本身**） |
| Godot 工程 | `godot-racer/`（即 `res://`） |
| 引擎 | `E:\godot\Godot_v4.4.1-stable_win64.exe`（同目录另有 `_console.exe`） |
| 远程仓库 | `github.com/QieRong/godot-racer.git` |
| 当前 HEAD | 批次④ 收尾后的 HEAD —— **以 `git log --oneline -1` 为准**（本文件所在的收尾提交紧随 `adb668f`；`adb668f` = push-log 批记录提交） |
| **工作区状态** | **干净**（仅 `02-Blender建模/` 两个中间产物未跟踪：`race_car.glb` / `racecar-3d.blend1`，按惯例**不入库**） |
| 本地 vs 远端 | 已推平（`git rev-list --left-right --count origin/main...HEAD` = `0<TAB>0`） |
| 开发阶段 | 制作（Phase 5）；打磨已局部开始；发布（Phase 7）未启动 |
| 平台 | Windows + Git Bash；开发/验收走 CLI + PowerShell 脚本，**不依赖编辑器** |

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
   文件**；4 个现存超限文件登记为**历史遗留**、随 `SPLIT-*` 批次逐步收敛、**不阻塞其修复性
   提交** —— `scripts/ai_opponent.gd` 1668 / `scenes/main.gd` 1613 / `scripts/vehicle.gd` 1413 /
   `scripts/checks/env_phys.gd` 1111（2026-10-14 实测）。
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
│   └─ checks/    layout.gd / bench.gd / ai.gd / env_phys.gd   ← 验收族已外迁模块
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
pwsh -File 04-Godot启动器/run-all-checks.ps1 -Quick     # 15 项；不带 -Quick 为 19 项（含慢项）
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

`main.gd` 历史上是巨型文件，正在按批次外迁。**已完成 10 步**：

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
| SPLIT-CHECKS-BASIC-005（⑤） | `scripts/checks/basic.gd` + `scripts/checks/lap.gd` | ✘ **未开始（最后一批）**；⚠ 实测待迁约 1008 行 > 1000 行「向前约束」→ **必须拆两个模块**（见下） |

**拆分铁律**：`match _check:` 分派口 + 三个计数常量 `LAYOUT_ELEV_CASES` / `LAYOUT_RACING_CASES` / `REVERSE_CASES` **永久留守 `main.gd`**（两道闸门直接读它们）→ 闸门脚本零改动；只外迁函数体。模块**无 `class_name`**，消费方 `const X := preload("res://scripts/checks/x.gd")`；依赖经 `setup()` 注入；**模块内 `await` 数 = 迁入前，一拍不加**（多一层协程会让 physics_frame 恢复差 1 帧）。各模块 await 数：`layout` 0 / `bench` 4 / `ai` 8 / `env_phys` 29 —— 由各自 structcheck 机器钉死。

**⑤ 为什么必须拆成两个模块**：待迁 17 个函数合计约 **1008 行**（`_check_lap` 256 + `_check_pause` 120 +
`reverse` 族 160 + `minimap`(×2) 103 + `enclosure` 76 + `_check_reset` 55 + `_check_stress` 52 +
`escape` 52 + `resetkey` 50 + `oob` 27 + `_reset_loop_hit` 5 + 若干分隔空行）。单个模块会撞破
AGENTS 第 8 条「新建文件 ≤1000 行」的**向前约束**（该条不豁免新文件），故按族拆两个：
  · `scripts/checks/basic.gd`（≈560 行）—— 场景 / 边界 / UI：`enclosure`、`reset`、`resetkey`、
    `oob`、`minimap`(+`_check_minimap_obstacles`)、`escape`(+`_find_wrong_way_panel`)、
    `pause`(+`_menu_press_escape`)
  · `scripts/checks/lap.gd`（≈500 行）—— 跑圈 / 压测 / 反向：`lap`(+`_reset_loop_hit`)、`stress`、
    `reverse` 族（`_reverse_call` / `_rev_dot` / `_reverse_case` / `_check_reverse_e2e` / `_cp`）

**批次⑤ 待迁清单**：`_check_enclosure` / `_check_reset` / `_check_reset_key` / `_check_out_of_bounds` / `_check_minimap`(×2) / `_check_pause`+`_menu_press_escape` / `_check_lap`+`_reset_loop_hit` / `_check_stress` / `_check_reverse` 族+`_cp` / `_check_escape`+`_find_wrong_way_panel`。⚠ `REVERSE_CASES` 必须留守 main 并由 `setup()` 注入 reverse 模块；`_sample_physics_ms` / `_avg_physics_ms` 属 main 共享采样器，**不搬**，按 Callable 注入。

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
| P1 | **SPLIT-CHECKS-BASIC-005（⑤，最后一批）** | 见 §5 待迁清单；完成后 `main.gd` 全量模块化。走 TDD + structcheck 先红后绿 + 文本核对 + A/B + `run-all-checks -Quick` |
| P1 | 素材管线 P0-a **LICENSE 补录** | 发布门禁级合规件（当前无 LICENSE） |
| P1 | 素材管线 P0-b **雨声接线** | `assets/audio/rain_loop.ogg` 已入仓但未接线；精确插点 `environment.gd` 的 `build_weather_particles` 之后，**零 `main.gd` 改动** |
| P1 | 素材管线 P0-c **LFS 迁移** | `git-lfs 3.7.1` 已装但 `ls-files` 空；≈10.7 MB 二进制直进 git（越拖着越多） |
| ✔ 已完成 | **OpenRouter 整体移除（2026-10-14）** | 用户签字「彻底移除功能」。删代码：`scripts/openrouter_client.gd`(+uid)、`tools/test_generator.py`、`04-Godot启动器/test-openrouter.ps1`、`openrouter.cfg.example`、本机 `openrouter.local.cfg`（真实 key，已被 gitignore、从未入库）；删检查项：`--check=openrouter` / `--check=models`（26→24）。文档全刷：`README.md`、`AGENTS.md §11`、`docs/testing.md`、`docs/engineering-notes.md`、`.gitignore`、`launcher-menu.ps1`。`data/ai_test_cases.json` 作为**离线确定性夹具保留**。 |
| — | 已决策**不做** | "正前方看全风镜"（需抬头盔→与挡风玻璃位置冲突）：**保持原样，只要不穿模**。v8 的 JOINT_GATE 65/65 已满足（无穿模）。`mat_glass_dark` 保持 0.25/0.04（玻璃镜面感是要的）。 |

---

## 8. 已知风险 / 陷阱

- **`lap` check 是「双稳态」**：同一份代码依机器负载会稳定产出不同规模的日志（诊断按墙钟打印）。**做 A/B 前必须先"同代码两跑"确认当前模式；不同模式的对比例子 = 无效证据。**
- **A/B 判据分两类**：日志**可逐行复现**的检查（`flip`/`phys`/`weather`/`friction`）→ 用逐行判据；**打印物理浮点、跨进程不可复现**的检查（`wallslide`/`stuck`，以及 L4 类）→ 按 AGENTS §4.3 **只比结构**（判定行逐字相同 + 逐类行数 + 允许 ±1 帧相位差），工具见 `godot-logs/split-checks-envphys-ab-closure.py`。
- **`check-docs` 的"计数契约"**：文档里「全部 N 项」字样会与 `run-all-checks.ps1` 的实际项数机器比对 —— **连引用旧措辞的叙述也会被误判**（本批就踩过一次）；往 `run-all-checks.ps1` 加检查项 = 改验收契约 = 需签字。
- **不要用编辑器 MCP 改文件**：编辑器缓冲区滞后于磁盘，会按过期行号错位；本项目真相源在磁盘。
- **headless 跑 Godot 不生成 `.uid`**；新增 `.gd` 记得手写 `.uid`。
- **并行会话**：项目常有多个会话/代理同时开工，`main.gd`/`scripts/checks/`/两份 AGENTS 是共享文件；提交前先看 `git status`，`git add` **只加显式路径**（永不 `-A`/`.`）。

---

## 9. 接管第一步（建议动作序列）

1. `git log --oneline -10` + `git status` —— 确认 HEAD 与工作区（预期：批次④ 收尾提交已在，工作区干净）。
2. 跑三道文本闸门 —— 确认当前是绿的（`check-docs` / `check-readme` / `check-dup-source` 应全 EXIT=0）。
3. 读 `04-Godot启动器/` 里的契约脚本 + `godot-racer/docs/testing.md` + `godot-racer/docs/push-log.md`（后者有每批的完整记录），理解验收链。
4. 从 §7 待办里挑一条开工；**每步走 TDD + 绑定 commit 号 + push**。

---

*本文件为一次性交接产物，不属于验收契约；放在仓库根（不在 `check-docs` / `check-readme` 的扫描集内），可安全删除或随仓库携带。*
