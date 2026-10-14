# Godot Racer · 跨平台交接说明

> 生成时间：2026-10-14 18:40 (GMT+8) ／ 修订：2026-10-14 18:50（批次④ 已提交固化）
> 用途：给**新平台的 AI** 在零历史上下文下快速、准确地接手本项目。
> 阅读顺序：先 §1 §2（状态与风险）→ §4 §6（工作方式与铁律）→ §7（待办）。**§2 是最要紧的一节。**

---

## 1. 一页速览

| 项 | 值 |
|---|---|
| 项目 | Godot Racer —— Godot 4.4.1 单机 3D 赛车（5 关 / AI 对手 / 天气 / 验收驱动的车辆物理） |
| 仓库根 | `D:/桌面/DSH-Work/data-analysis`（**仓库根 == 工作区本身**） |
| Godot 工程 | `godot-racer/`（即 `res://`） |
| 引擎 | `E:\godot\Godot_v4.4.1-stable_win64.exe`（同目录另有 `_console.exe`） |
| 远程仓库 | `github.com/QieRong/godot-racer.git` |
| 当前 HEAD | 工作树已固化到批次④ 三笔提交（`4e524fb` → `0fc8eb2` → `fcfd541`），**已推送** |
| **工作区状态** | 干净（仅 `02-Blender建模/` 两个中间产物未跟踪，按惯例不入库） |
| 开发阶段 | 制作（Phase 5）；打磨已局部开始；发布（Phase 7）未启动 |
| 平台 | Windows + Git Bash；开发/验收走 CLI + PowerShell 脚本，**不依赖编辑器** |

---

## 2. ✅ 批次④ 已固化（本轮已提交并 push）

原本滞留在工作区的整套「批次④」成果，现已按批次①-③ 惯例拆成三笔提交并推送：

| commit | 类型 | 内容 |
|---|---|---|
| `4e524fb` | `fix(checks)` | **GATE-REPAIR-001** —— 台架满舵判据 `0.45`→真源 `0.5`（`bench.gd`，用户签字）+ `push-log.md` 措辞「全部 5 项」→「本批 5 项」（清 `check-docs` 红） |
| `0fc8eb2` | `refactor(main)` | **SPLIT-CHECKS-ENVPHYS-004** —— 环境物理验收族外迁至 `scripts/checks/env_phys.gd`；`main.gd` 2577 行/53 func → **1613 行/36 func** |
| `fcfd541` | `docs(agents)` | 两份 `AGENTS.md` 各 +1 行：新增第 8 条「单个代码文件 ≤1000 行」硬上限 |

**未跟踪、按惯例不入库**：`02-Blender建模/race_car.glb`、`02-Blender建模/racecar-3d.blend1`（Blender 中间产物）。

> ⚠ 注意：若在别处 `git clone`，拉到的是 **HEAD 当前值**，请以 `git log --oneline -5` 实际输出为准。

### 两条待用户拍板的遗留（随代码一起入库了，但结论未定）

1. **`AGENTS.md` 第 8 条规则（≤1000 行）与现状冲突**：`main.gd` 现 **1613 行**、新建 `env_phys.gd` **1111 行**，均超上限。该规则**来源不在本轮派工单范围内**（可能来自并行会话或用户本人）→ 需确认它是**强约束**（那要再拆 `env_phys.gd` / 继续瘦身 `main.gd`）还是**新文件的向前约束**（需补一句适用范围）。
2. **批次④ 的 `AGENTS.md` 正文同步未做**：§1 核心代码列表 / §2.1 进度表+现状 / §2.4 模块清单（9→10）+ await 约定行 —— 只加了第 8 条规则，模块清单尚未登记 `env_phys.gd`。

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
03-2D赛车图 / 01-参考 / godot-logs(gitignored 证据目录) / screenshots/
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
pwsh -File 04-Godot启动器/check-docs.ps1       # 文档内部一致性（块数 ↔ 计数常量，如 REVERSE_CASES）
pwsh -File 04-Godot启动器/check-dup-source.ps1 # 单一真相源守卫（常量/公式是否有副本）
```

### 4.2 引擎验收（`--check=X --Level=N` 驱动）

```powershell
pwsh -File 04-Godot启动器/lint-gdscript.ps1
pwsh -File 04-Godot启动器/parse-check.ps1
pwsh -File 04-Godot启动器/run-check.ps1 -Check <项> -Level <0-4>
pwsh -File 04-Godot启动器/run-all-checks.ps1 -Quick     # 15 项；不带 -Quick 为 19 项（含慢项）
```

当前 **26 个检查项**：`aidiag aistart avoid brakebench enclosure escape flip friction lap layout minimap models obstacles oob openrouter opponents pause phys reset resetkey reverse steerbench stress stuck wallslide weather`。
`-Quick` 会**跳过** `slow=$true` 的 `aidiag / stress / opponents / lap`。

### 4.3 环境坑（踩过的，务必照做）

- **Git Bash 里不能调 `pwsh`**（安全策略拦）→ 一律用 PowerShell 工具/终端。
- **PowerShell 工具不回传 stdout**，长任务会被内部超时掐断 → 长验收必须后台跑 + 输出重定向到文件再读。
- `run-all-checks.ps1` 顶部自带强制 UTF-8；否则本机 gb2312 下 `✔` 不可表示 → **全线假红**。
- engine headless **不会自动生成 `.uid`** → 新模块的 `.uid` 手写（`uid://` + 13 位、不碰撞即可）。
- `shoot.ps1 -Out` **必须绝对路径**（相对路径必失败）。
- `godot-logs/` 整目录被 `.gitignore` 忽略 → 证据文件入库需 `git add -f`；裸目录名 `git check-ignore` 不命中。

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
| **SPLIT-CHECKS-ENVPHYS-004（④）** | `scripts/checks/env_phys.gd` | ✔ 已提交 `0fc8eb2`；**A/B 尚存 2 项未结案（见下）** |
| SPLIT-CHECKS-BASIC-005（⑤） | `scripts/checks/basic.gd` | ✘ **未开始** |

**拆分铁律**：`match _check:` 分派口 + 三个计数常量 `LAYOUT_ELEV_CASES` / `LAYOUT_RACING_CASES` / `REVERSE_CASES` **永久留守 `main.gd`**（两道闸门直接读它们）→ 闸门脚本零改动；只外迁函数体。模块**无 `class_name`**，消费方 `const X := preload("res://scripts/checks/x.gd")`；依赖经 `setup()` 注入；**模块内 `await` 数 = 迁入前，一拍不加**（多一层协程会让 physics_frame 恢复差 1 帧）。

### 批次④ 的验收证据与未结项

- **已做**：`env_phys.gd` 建成（`_check_weather`→`run_weather` / `_check_phys`→`run_phys` / `_check_friction`→`run_friction` / `_check_wallslide`→`run_wallslide` / `_check_stuck`→`run_stuck` / `_check_flip`→`run_flip` + 9 个私有 helper；`_probe_blocker`→公开 `probe_blocker`）；`main.gd` 分派已改 `_checks_envphys.run_*`；三常量仍留守。
- **结构校验** `godot-logs/split-checks-envphys-structcheck.ps1`：**15/15 PASS**（含 await 恰 29 处、main.gd 零残留 token、两份 AGENTS 逐字节一致）。
- **文本核对** `godot-logs/split-checks-envphys-textverify.py`：**未解释差异 = 0**（零转录漂移）。
- **A/B 舞步** `godot-logs/split-checks-envphys-ab-analysis.log`：**总判 ✘**。
  - ✔ 无差异项：`flip` / `phys` / `weather` / `friction`（跨组差 0）
  - ⚠ `wallslide`：跨组差 2 ≤ 噪声底 2（临界通过），但**缺"零差跨组对"** → 判 ✘
  - ⚠ `stuck`：跨组差 12 > 噪声底 9 → 判 ✘（但存在零差跨组对 `m2≡c1`）
  - 现场还有 `_envphys-ab-extra-m3/m4-*.log` —— 被中断时正在**补跑复测**这两项。
- **结论**：`wallslide` / `stuck` 属**临界/复测中**，需先跑"同代码两跑"定双稳态模式，再判是"迁移漂移"还是"双稳态噪声"。**不要直接当成通过。**

---

## 6. 项目铁律（违反即返工）

1. **`racing_line.gd` / `track_layout.gd` = 几何与限速唯一真相源，禁止复制公式**；新逻辑写成 `racing_line.gd` 纯函数。
2. **TDD**：先写检查（红）→ 最小实现 → 绿 → 回归 → 提交；**验收必须绑定 commit 号 + 工作区状态**。
3. **不得为变绿放宽判据 / 删测试 / 改阈值**。改验收契约（闸门脚本、判据值）**必须用户签字**。
4. **每步验证链**：`lint` → `parse-check` → 专项 `run-check` → `run-all-checks -Quick`；**改文档后必须复跑三道文本闸门**。
5. **GitHub 同步铁律**：每完成一步必须 `git push`，**本地 `main` 始终 = `origin/main`**；报告里要报"本地 vs origin 是否一致"。
6. **代码文件 ≤1000 行**（新增第 8 条；`main.gd` 现 1613 行、`env_phys.gd` 1111 行已超 —— 待用户确认适用范围后处理）。
7. 两份 `AGENTS.md`（根 + `godot-racer/`）**必须逐字节一致**（有机器校验看住）。
8. 反模式（禁）：收紧转向死区/打舵门限、抬 `max_steer`、加横向辅助力、抬 `GRIP_BASE`、删自救。

---

## 7. 待办清单（按优先级）

| 优先级 | 事项 | 说明 |
|---|---|---|
| P0 | 定案 `wallslide` / `stuck` A/B | 先跑"同代码两跑"确认双稳态模式，再判是否真漂移（见 §5） |
| P0 | 确认 `AGENTS.md` 第 8 条规则的意图与范围 | 来源未明；`main.gd` 1613 / `env_phys.gd` 1111 均超限（见 §2） |
| P1 | 补 batch ④ 的 AGENTS 文档同步 | §1 核心代码列表 / §2.1 进度表+现状 / §2.4 模块清单 9→10 + await 约定行 |
| P1 | SPLIT-CHECKS-BASIC-005（⑤，最后一批） | 迁 `_check_enclosure` / `_check_reset` / `_check_reset_key` / `_check_out_of_bounds` / `_check_minimap`(×2) / `_check_models` / `_check_openrouter` / `_check_pause`+`_menu_press_escape` / `_check_lap`+`_reset_loop_hit` / `_check_stress` / `_check_reverse`族+`_cp` / `_check_escape`+`_find_wrong_way_panel` |
| P1 | 素材管线 P0-a **LICENSE 补录** | 发布门禁级合规件（当前无 LICENSE） |
| P1 | 素材管线 P0-b **雨声接线** | `assets/audio/rain_loop.ogg` 已入仓但未接线；精确插点 `environment.gd` 的 `build_weather_particles` 之后，**零 `main.gd` 改动** |
| P1 | 素材管线 P0-c **LFS 迁移** | `git-lfs 3.7.1` 已装但 `ls-files` 空；≈10.7 MB 二进制直进 git（越拖着越多） |
| P2 | **从 README/docs 移除 OpenRouter 段** | 用户明确要求："OpenRouter API key 可选、只在联网生成测试用例时需要、玩游戏不需要"，且"README 里不要提这个招笑的示例"。涉及 `README.md`(约 L25/71/79/81/88/140)、`AGENTS.md §11`、`docs/testing.md`、`docs/engineering-notes.md`、`docs/plans/*`。**是否连同代码（`openrouter_client.gd` / `tools/test_generator.py` / `04-启动器/test-openrouter.ps1` / `--check=openrouter`）一起删，用户尚未明确 → 先问。** |
| — | 已决策**不做** | "正前方看全风镜"（需抬头盔→与挡风玻璃位置冲突）：**保持原样，只要不穿模**。v8 的 JOINT_GATE 65/65 已满足（无穿模）。 |

---

## 8. 已知风险 / 陷阱

- **lap check 是「双稳态」**：同一份代码依机器负载会稳定产出不同规模的日志（诊断按墙钟打印）。**做 A/B 前必须先"同代码两跑"确认当前模式；不同模式的对比例子 = 无效证据。**
- **A/B 判据**：跨组差 ≤ 同代码组内极差 + 存在一对零差跨组对 + 判定串集合一致。缺一即需复测。
- **`check-docs` 的"计数契约"**：文档里"N 项"字样与实现计数被机器比对；往 `run-all-checks.ps1` 加检查项 = 改验收契约 = 需签字。
- **不要用编辑器 MCP 改文件**：编辑器缓冲区滞后于磁盘，会按过期行号错位；本项目真相源在磁盘。
- **headless 跑 Godot 不生成 `.uid`**；新增 `.gd` 记得手写 `.uid`。
- **并行会话**：项目常有多个会话/代理同时开工，`main.gd`/`scripts/checks/`/两份 AGENTS 是共享文件；提交前先看 `git status`，`git add` **只加显式路径**（永不 `-A`/`.`）。

---

## 9. 接管第一步（建议动作序列）

1. `git log --oneline -6` + `git status` —— 确认 HEAD 与工作区（预期：批次④ 三笔提交已在，工作区干净）。
2. 跑三道文本闸门 —— 确认当前是绿的（`check-docs` / `check-readme` / `check-dup-source` 应全 EXIT=0）。
3. 读 `04-Godot启动器/` 里的契约脚本 + `godot-racer/docs/testing.md`，理解验收链。
4. 从 §7 待办里挑一条开工；**每步走 TDD + 绑定 commit 号 + push**。

---

*本文件为一次性交接产物，不属于验收契约；放在仓库根（不在 `check-docs`/`check-readme` 的扫描集内），可安全删除或随仓库携带。*
