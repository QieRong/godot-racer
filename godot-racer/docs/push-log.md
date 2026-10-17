# 推送记录（Push Log）

> 为什么单独一个文件：AGENTS.md §15 要求「验收结果必须绑定 commit」，但**没有任何地方记录
> 「这些 commit 到底推没推上去」**。2026-10-09 实际发生过一次：本地攒了 4 个 commit、
> 远端还停在 4 轮之前，而所有本地检查都是绿的 —— 绿的是**本机工作区**，不是远端。
> 从此每推一次就在这里追加一行。

## 记录规则

- 每行必须写全：**本地 HEAD 短哈希 / 远端 `refs/heads/main` 短哈希 / 两者是否相等 / 推送时间**。
- 哈希要用**命令的输出**填，不能凭记忆写（`git rev-parse HEAD` + `git ls-remote origin refs/heads/main`）。
- 只写「已推送」不算数：必须能让下一个人只靠这一行就复核（命令写在下面「复核方法」里）。

## 复核方法

```powershell
cd <仓库根>            # 注意：git 根是 data-analysis/，不是 godot-racer/
git fetch origin
git rev-parse HEAD
git ls-remote origin refs/heads/main
git rev-list --left-right --count origin/main...HEAD   # 期望 0<TAB>0
```

⚠ **踩过的坑**：`git ls-tree` / `git ls-files` 在**子目录**里跑只会看那一层，
  从 `godot-racer/` 里查 `screenshots/...` 会得到「不存在」的假结论。
  查跨目录的文件必须先 `cd` 到 git 根。

## 记录

| 推送时间 | 本地 HEAD | 远端 main | 相等 | 这一批推上去的 commit |
|---|---|---|---|---|
| 2026-10-09 17:53 (+08:00) | `1106c08` | `1106c08` | ✅ | `c99c3a3` `aa308f3` `9b078a0` `1106c08` |
| 2026-10-09 17:58 (+08:00) | `476f4aa` | `476f4aa` | ✅ | `476f4aa` |
| 2026-10-09 18:01 (+08:00) | `9332f40` | `9332f40` | ✅ | `9332f40` |
| 2026-10-09 18:03 (+08:00) | `f8c1ad4` | `f8c1ad4` | ✅ | `f8c1ad4` |
| 2026-10-12 21:05 (+08:00) ＊ | `2eabe60` | `2eabe60` | ✅ | `2eabe60` |
| 2026-10-12 21:49 (+08:00) ＊ | `e049f79` | `e049f79` | ✅ | `e049f79` |
| 2026-10-12 23:40 (+08:00) ＊ | `8188e90` | `8188e90` | ✅ | `8188e90` |
| 2026-10-13 12:49 (+08:00) | `9ba73dc` | `9ba73dc` | ✅ | `031abd5` `9ba73dc` |
| 2026-10-14 18:59 (+08:00) ※ | `060b738` | `060b738` | ✅ | `4e524fb` `0fc8eb2` `fcfd541` `060b738` |
| 2026-10-14 19:12 (+08:00) ※ | `9628ea0` | `9628ea0` | ✅ | `ba5e31f` `9628ea0` |
| 2026-10-14 19:16 (+08:00) ※ | `adb668f` | `adb668f` | ✅ | `adb668f`（push-log 批记录） |
| 2026-10-14 20:12 (+08:00) | `18eeae0` | `18eeae0` | ✅ | `522c983` `18eeae0` |
| 2026-10-14 21:14 (+08:00) | `4d3a7cd` | `4d3a7cd` | ✅ | `f8b2cb2` `25934e6` `4d3a7cd` |
| 2026-10-15 08:59 (+08:00) | `a7294a1` | `a7294a1` | ✅ | `a7294a1`（GATE-L4-001，用户签字补 L4 门禁） |
| 2026-10-15 09:12 (+08:00) | `f78882d` | `f78882d` | ✅ | `f78882d`（用户选择 MIT；补第三方来源记录） |
| 2026-10-15 14:14 (+08:00) | `ff18a02` | `ff18a02` | ✅ | `ff18a02`（L5 probe 修复、TDD、专项/回归证据、交接更新） |

※ **2026-10-14 三批（批次④ 固化 / 文档+证据 / push-log）**：推送时刻本机未单独记录，
"推送时间"取该 HEAD 的 **commit 时间**（`git log -1 --format=%cI` =
`2026-10-14T18:58:53+08:00` / `2026-10-14T19:11:07+08:00` / `2026-10-14T19:14:21+08:00`），
与真实推送时刻相差分钟级，不冒充精确推送时刻。内容见下
「2026-10-14 SPLIT-CHECKS-ENVPHYS-004 这一批的内容」。
本表最后一行之后还有一个**收尾提交**（更新 `HANDOVER.md` + 本行），即 HEAD 之后一格，
符合本文件「最后一行永远落后一个 commit」的自指说明。

＊ **补记（2026-10-13，SPLIT-AUTOPILOT-002 收尾时）**：main.gd 拆分前三步推上去时忘了在本文件
落行，现按 git 记录补。哈希用命令复核过（`git log --oneline` + `git ls-remote origin refs/heads/main`，
origin/main = `8188e90` 时三者均已在远端）；"推送时间"取的是 **commit 时间**（真实推送时刻未记录，
以此为准并明确标注，不冒充）。

⚠ 本表仍缺 2026-10-10~10-11 测试基建那一批的落行（`5b7e3ef` `7857bb9` `479f370` `c65b1de`
`135bfd2` `00a2b13` `7890b5e` `44352f8` `459902f` `53b9138`）—— 那批不属于拆分线，留待该线负责人补。

### 2026-10-09 17:53 这一批的内容

推送前远端停在 `f0398f8`（第三轮），本地领先 4 个 commit。逐个说明：

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `c99c3a3` | L4 变道走廊只读取证（走廊假设被证伪） | `godot-racer/scenes/main.gd`、`godot-racer/tools/l4_transition_report.py`、`godot-racer/tools/l4_transition_posthoc.py`、`godot-racer/docs/testing.md`、`godot-racer/docs/plans/lap-autopilot-obstacle-avoidance.md`、`screenshots/l4-rock-2800.png`、`screenshots/l4-rock-6800.png` |
| `aa308f3` | 第四轮记录补 commit 绑定 | `godot-racer/docs/testing.md` |
| `9b078a0` | 补一条 steering 直接读数 | `godot-racer/docs/testing.md`、`screenshots/l4-stuck-a.png` |
| `1106c08` | 第五轮：打舵门限修复失败并整份回退（**纯文档，无代码改动**） | `godot-racer/docs/testing.md`、`godot-racer/docs/plans/lap-autopilot-obstacle-avoidance.md` |

推送命令与输出（原样抄录）：

```text
PS> git push origin main
To https://github.com/QieRong/godot-racer.git
   f0398f8..1106c08  main -> main
PS> git ls-remote origin refs/heads/main
1106c0808de7c70e2e48fc65965906cf32006f28	refs/heads/main
PS> git rev-list --left-right --count origin/main...HEAD
0	0
```

⚠ **`1106c08` 的代码状态 = `9b078a0` = `c99c3a3` 的 `main.gd`**：第五轮的修复尝试失败后
整份回退，所以 `main.gd` 与第四轮取证时逐字节相同。**不要**以为这个 HEAD 里含某个修复。

### 2026-10-09 17:58 这一批的内容

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `476f4aa` | 本文件（`docs/push-log.md`）落库 —— 把上一批 4 个 commit 的推送取证写成可复核的记录 | `godot-racer/docs/push-log.md` |

推送命令与输出（原样抄录）：

```text
PS> git push origin main
To https://github.com/QieRong/godot-racer.git
   1106c08..476f4aa  main -> main
PS> git ls-remote origin refs/heads/main
476f4aaaddb918e2f3eb314a578f7ad0a6cea13c	refs/heads/main
PS> git rev-list --left-right --count origin/main...HEAD
0	0
```

推送前跑过的检查（都在 `04-Godot启动器/` 下）：`check-docs.ps1` PASS（扫描 6 个文档）、
`check-readme.ps1` PASS —— 新增文档没有让文档漂移检查变红。

### 2026-10-09 18:01 这一批的内容

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `9332f40` | push-log 补记 `476f4aa` 这一批（含推送输出与文档检查结果） | `godot-racer/docs/push-log.md` |

```text
PS> git push origin main
To https://github.com/QieRong/godot-racer.git
   476f4aa..9332f40  main -> main
PS> git ls-remote origin refs/heads/main
9332f40aebba7b5aaa1fc425529ca37eec8088ed	refs/heads/main
PS> git rev-list --left-right --count origin/main...HEAD
0	0
```

### 2026-10-09 18:03 这一批的内容

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `f8c1ad4` | push-log 补记 `9332f40` | `godot-racer/docs/push-log.md` |

```text
PS> git push origin main
To https://github.com/QieRong/godot-racer.git
   9332f40..f8c1ad4  main -> main
PS> git ls-remote origin refs/heads/main
f8c1ad4fb8ad09ab8d1be669ac2a9d4a891c1ec2	refs/heads/main
PS> git rev-list --left-right --count origin/main...HEAD
0	0
```

## 关于本文件自身的滞后（**已知且刻意**）

每一批推送都会让 HEAD 前进一格，所以本文件里的最后一行**永远比 HEAD 落后一个 commit**
（记录 `X` 的那一批会把 HEAD 推到 `X` 之后的下一个哈希）。这是自指的必然结果，不是漏记。

**复核以远端为准**：`git ls-remote origin refs/heads/main` 的哈希必须与 `git rev-parse HEAD` 相等，
且 `git rev-list --left-right --count origin/main...HEAD` 输出 `0<TAB>0`。
本文件只用来回答「哪一批、什么时候、推了什么」。

## 尚未推送 / 待处理

- 无未推送的 commit（SPLIT-CHECKS-LAYOUT-001 批的代码提交 `13cb52f` 与文档提交
  `22386be` 已推；此前并行对话的 §23 Blender 提交 `a48c595` 亦已推）。
- **2026-10-14 批次④ 两轮推送亦已推**：`3298de4..060b738`（`4e524fb` `0fc8eb2`
  `fcfd541` `060b738`）与 `060b738..9628ea0`（`ba5e31f` `9628ea0`）；复核
  `git rev-list --left-right --count origin/main...HEAD` = `0<TAB>0`。
- 仓库根 `AGENTS.md` 与 `godot-racer/AGENTS.md` **均已被 git 跟踪**（根目录那份于
  `c3f8f76` 入库，2026-10-13 用户拍板「纳入」）；两处保持逐字节一致（现各 1100 行），
  由各批次 structcheck 的机器断言看住。
- `godot-logs/` 与 `data-analysis/screenshots/` 的其余调查产物按 `.gitignore` 留在本机。
  **例外**：SPLIT-SCREENSHOT-001 批（`ff80310`）17 个文件、SPLIT-CHECKS-LAYOUT-001 批
  （`13cb52f`）的 25 个证据文件（structcheck 脚本与红/绿/postab/修订三连日志、A/B 舞步
  脚本与两轮四跑证据、文本级核对脚本与 diff 快照、parse-check 修复前/后两跑日志）
  均 `git add -f` 强制入库。

### 2026-10-12 拆分前三批的内容（补记）

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `2eabe60` | 天气/环境块迁出至 scripts/environment.gd（SPLIT-ENV-001 纯迁移，main.gd 6171→6041 行） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/environment.gd`(+`.uid`) |
| `e049f79` | 占位引擎声迁出至 scripts/engine_audio.gd（SPLIT-ENV-002 纯迁移，main.gd 6041→5996 行） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/engine_audio.gd`(+`.uid`) |
| `8188e90` | [DEBUG-L4] 诊断块迁出至 scripts/l4_debug_diag.gd（SPLIT-L4DIAG-001 纯迁移，main.gd 5996→5422 行） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/l4_debug_diag.gd`(+`.uid`)、`godot-racer/docs/plans/lap-autopilot-obstacle-avoidance.md` |

三批的验收结论（行为等价证据）见各自 commit message 的正文。

### 2026-10-13 SPLIT-AUTOPILOT-002 这一批的内容

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `031abd5` | 自动驾驶族迁出至 scripts/autopilot.gd（SPLIT-AUTOPILOT-002 纯迁移，main.gd 5422→5011 行） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/autopilot.gd`(+`.uid`)、`godot-racer/docs/plans/lap-autopilot-obstacle-avoidance.md`、`godot-racer/docs/push-log.md` |
| `9ba73dc` | AGENTS.md 同步拆分实证（拆分进度表 / §2.4 模块共同约定 / §4.3 A/B 范式 / §5.4 结构校验先红 / push 铁律 / §20 技能路径纠错） | `godot-racer/AGENTS.md` |

本批验收（绑定 `9ba73dc`，证据 `godot-logs/`）：
- 结构校验 7 项 0 失败；lint / parse `EXIT=0`
- L2 A/B（round2）：归一化仅 14 行差异，全是圈速墙钟行
- L4 A/B：判定行两边相同、7 次瞬移坐标逐字节一致
- `run-all-checks -Quick` **15/15 ✔** `QUICK_EXIT=0`（`godot-logs/split-autopilot-quick-final.log`）

> 说明：本批为 `031abd5` `9ba73dc` 两个内容提交。写这一行时两者**已推送**
> （`8188e90..9ba73dc`，`git rev-parse HEAD` = `git ls-remote origin refs/heads/main`
> = `9ba73dc`）；记录本行的 push-log 提交自身即为 HEAD 之后一格，符合本文件「最后一行
> 永远落后一个 commit」的自指说明。

### 2026-10-13 SPLIT-OPPONENT-001 这一批的内容

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `17c0b5a` | 对手生成族迁出至 scripts/opponent_spawner.gd（SPLIT-OPPONENT-001 纯迁移，main.gd 5011→4964 行、func 91→89） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/opponent_spawner.gd`(+`.uid`) |
| `8de5d2e` | AGENTS.md 同步：拆分进度表 / 对手生成族边界约定 / §2.4 模块共同约定 / §4.3「先确认模式」的 A/B 陷阱 | `godot-racer/AGENTS.md` |

本批验收（绑定 `8de5d2e`，证据 `godot-logs/`）：
- 结构校验 12 项断言 0 失败（先红：`split-opponent-structcheck-red-run.log` 11 项 10 红 →
  绿：`split-opponent-structcheck-green-run.log`）
- lint-gdscript（25 个 .gd）/ parse-check：通过
- A/B L2（同模式）：HEAD 与迁移后的 17092 行日志归一化后**只差 16 行，全是圈速墙钟行**，
  坐标/速度/判定逐行相同（AGENTS §4.3 的「轨迹级一致」）
- A/B L4（同模式 39598 vs 39600 行）：✔/✘ 6/2 相同、卡住 13/13、瞬移 13/13、判定行逐字相同，
  只有圈速墙钟与 ±1 帧相位差
- `run-all-checks -Quick`：15/15 通过
- ⚠ 副产品：**lap check 是双稳态的**（同一份代码依负载产出 12956 / 13460 / 17092 三种规模）。
  判决实验 `godot-logs/split-opponent-fileprobe.ps1` 证实纯 HEAD 代码也能跑出 13459 / 17091 行。
  不同模式的对比例子＝无效证据，做 A/B 前必须先确认模式。

> 说明：本批为 `17c0b5a` `8de5d2e` 两个内容提交，写这一行时两者**已推送**
> （`af4ed05..8de5d2e`，`git rev-parse HEAD` = `git ls-remote origin refs/heads/main`
> = `8de5d2e`）；记录本行的 push-log 提交自身即为 HEAD 之后一格，符合本文件「最后一行
> 永远落后一个 commit」的自指说明。

## 2026-10-13 15:56 —— HUD 圈数 + godot-mcp 工具链（`921916b` `a59c8d0` `dd01a64`）

| 推送时间 | 本地 HEAD | 远端 main | 相等 |
|---|---|---|---|
| 2026-10-13 15:56:19 | `dd01a64` | `dd01a64` | ✔（`--left-right --count` = `0<TAB>0`） |

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `921916b` | HUD 加「当前第几圈 / 共几圈」显示（原来只有圈速没有圈数）。运行时建标签、不碰 main.tscn | `godot-racer/scripts/hud.gd` |
| `a59c8d0` | godot-mcp 工具链入库：体检 / 4.4.1 补丁 / 端到端探针 / 能力评估 / 运行时通道探针 / 通用调用器 / 驱动器；连带跳过 addons 的 lint、addons 不入库、启用插件 | `04-Godot启动器/*`（7 个新脚本）、`.gitignore`、`godot-racer/project.godot` |
| `dd01a64` | AGENTS.md 新增 §22 godot-mcp 工具链（实测结论 + 四条红线 + 入库范围取舍） | `godot-racer/AGENTS.md` |

验收证据（`run-all-checks -Quick`，绑定 `0674a08`，工作区含 `921916b` 的改动）：

- Quick 集 15 项全部通过 ✔（`run-all-checks.ps1` 共 19 项，Quick 只跑其中 15 项）
- `lint-gdscript.ps1` / `parse-check.ps1` 均通过
- godot-mcp 端到端 `verify-godot-mcp.ps1 -Live`：7/7 通过（server 0.6.0 = 插件 0.6.0）

本批留下的**两条硬结论**（细节见 `AGENTS.md` §22）：

1. **MCP 顶不掉验收链路**：`run_scene` 不支持命令行参数，而本项目全部验收靠
   `--check=X --Level=N`。它省的是「查」，不是「跑」。
2. **别用 MCP 改 .tscn**：实测编辑器保存会吃掉手写注释并重生成 uid
   （`main.tscn` 的出生点踩坑注释被删过两次，两次都是 `git checkout` 救回来的）。

> 说明：本批为 `921916b` `a59c8d0` `dd01a64` 三个内容提交，写这一行时三者**已推送**
> （`0674a08..dd01a64`，`git rev-parse HEAD` = `git ls-remote origin refs/heads/main`
> = `dd01a64`）；记录本行的 push-log 提交自身即为 HEAD 之后一格，符合本文件「最后一行
> 永远落后一个 commit」的自指说明。

### 2026-10-13 SPLIT-SCREENSHOT-001 这一批的内容

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `ff80310` | 截图模式族迁出至 scripts/screenshot_mode.gd（SPLIT-SCREENSHOT-001 纯迁移，main.gd 4964→4801 行、func 89→90；模块 await 恰 2 处与迁移前一致） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/screenshot_mode.gd`(+`.uid`)、`godot-logs/`（structcheck 脚本 + 红/绿/postab 日志 + A/B 舞步脚本与三组证据，共 17 个文件 `git add -f` 强制入库） |
| `9ba8dec` | AGENTS.md 同步（§1 核心代码列表 / §2.1 拆分进度表+现状行 / §2.4 模块清单）；docs/testing.md 两处旧位置引用改指模块路径与方法名 | `godot-racer/AGENTS.md`、`godot-racer/docs/testing.md` |

本批验收（`run-all-checks -Quick` 绑定 `31aa68e`、工作区含本次改动；其余证据 `godot-logs/`）：

- 结构校验（`split-screenshot-structcheck.ps1`，15 项断言）：先红（11 失败，
  `split-screenshot-structcheck-red-run.log`）后绿（0 失败，
  `split-screenshot-structcheck-green-run.log`）；A/B 舞步后复跑仍 15/15
  （`split-screenshot-structcheck-postab.log`）
- `lint-gdscript.ps1`（26 个 .gd）/ `parse-check.ps1`：通过
- A/B 三组（stash 舞步、背靠背、定向 pathspec，证据 `split-screenshot-ab-*`）：
  - plain：同代码两跑先确认噪声底（3 行：车/相机落点第 4 位小数 + 音频帧墙钟计数）；
    ctrl(HEAD) vs after 归一化后差异恰为同类同量级 3 行，其余 222/225 行逐行相同；
    `save_png -> 0`、「结束，退出」、exit=0 四跑全过
  - drive（`-Drive`）/ wrongway（`-WrongWay -WrongWayMode 1`）：负载敏感只比结构，
    `[截图]` 前缀集合与条数一致（7/7 与 8/8）、`save_png -> 0`、结束，退出、exit=0 全过；
    wrongway 摆位行 ctrl 与 after **逐字节相同**（await/call_deferred 协程时序保持）
  - PNG 字节对比：8 个互不相同（连同代码两跑 base1/base2 都不同，墙钟沉降差）→ 以日志为准
- `run-all-checks -Quick`：15/15 通过（`RUNALL_EXIT=0`）
- ⚠ `screenshot_mode.gd.uid` 为**手写**（headless `--check-only` 不自动生成 .uid）：
  `uid://ybp61v7f3ei1f`，格式照先例、与现有 23 个 uid 无碰撞，随 `ff80310` 入库

> 说明：本批为 `ff80310` `9ba8dec` 两个内容提交，写这一行时两者**已推送**
> （`31aa68e..9ba8dec`，`git rev-parse HEAD` = `git ls-remote origin refs/heads/main`
> = `9ba8dec`）；记录本行的 push-log 提交自身即为 HEAD 之后一格，符合本文件「最后一行
> 永远落后一个 commit」的自指说明。

### 2026-10-13 SPLIT-CHECKS-LAYOUT-001 这一批的内容

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `13cb52f` | 赛道布局验收族迁出至 scripts/checks/layout.gd（SPLIT-CHECKS-LAYOUT-001 纯迁移，main.gd 4801→4033 行、func 90→66；模块 await=0） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/checks/layout.gd`(+`.uid`)、`04-Godot启动器/parse-check.ps1`（**唯一受保护路径例外**：聚合器 res:// 路径 bug 一行修复，用户当日签字；structcheck 以「diff 恰 1 增 1 删 + 新增行含指定标记」机器钉死）、`godot-logs/`（本批 25 个证据文件 `git add -f` 强制入库） |
| `22386be` | AGENTS.md 同步（§1 核心代码列表 / §2.1 拆分进度表+现状+checks 族边界约定新小节 / §2.4 模块清单六个→七个 + await 约定行）；push-log 落本批记录 | `godot-racer/AGENTS.md`、`AGENTS.md`（根副本，逐字节一致）、`godot-racer/docs/push-log.md` |

本批验收（`run-all-checks -Quick` 绑定 `13cb52f`、工作区含本次改动；其余证据 `godot-logs/`）：

- 结构校验（`split-checks-layout-structcheck.ps1`，15 项断言）：先红（8 失败，
  `split-checks-layout-structcheck-red-run.log`）后绿（0 失败，
  `split-checks-layout-structcheck-green-run.log`）；A/B 舞步后复跑仍 15/15
  （`split-checks-layout-structcheck-postab.log`）
- parse-check.ps1 例外链（用户签字后）：基线绿 → 错误形态修复（2 增 1 删）**红** →
  正确形态（1 增 1 删）绿（`split-checks-layout-structcheck-amend-baseline/red/green.log`）。
  同轮抓到并修掉一个**潜伏 bug**：git 默认 core.quotepath 把中文路径转义成 `\345`
  八进制，原断言按真中文 match → `04-Godot启动器/` 这条受保护路径**从来没生效过**，
  已改为「转义形态 + 真中文形态」双匹配
- 文本级完备性核对（`split-checks-layout-textverify.py`）：A/B 日志覆盖不到未执行分支，
  补这一层 —— 迁移前原始块施加变换后与模块正文 diff，**只剩 5 组文档化差异**（await
  说明注释 2 行 / 两个条数常量块留守 main.gd / reverse 族 183 行非本批 / Track 注入
  注释 2 行）。实证抓到并修回 3 处真实转录漂移：失败汇总行一处 `、`→`，`、
  两处段头横幅 `##`→`#`
- `lint-gdscript.ps1`（27 个 .gd）/ `parse-check.ps1`（27 个；修复后 layout.gd **首次
  真正进入解析覆盖** —— 修复前子目录脚本从未被聚合解析过）：通过
- A/B 舞步两轮（stash 舞步、背靠背、定向 pathspec；证据 `split-checks-layout-ab-*`）：
  ctrl(HEAD) vs after 归一化后**逐行相同**（两轮皆是；round 2 曾抓到 after 缺成功汇总
  行后缀 `+ 本关布局全部达标`，修复后复跑全同）。噪声底实证：日志里 9 个 `[车辆]` 诊断块
  的第 9 个（t=2.3s）位置会在检查输出前/后翻转（stdout/stderr 合流次序，**内容逐行
  相同**）；两轮 ctrl/after 均落同模式（B），舞步脚本已加「模式指纹」自动记录
  （AGENTS §4.3「先确认模式」的又一例）
- `run-all-checks -Quick`：15/15 通过（`RUNALL_EXIT=0`）
- ⚠ `layout.gd.uid` 为**手写**（headless `--check-only` 不自动生成 .uid）：
  `uid://chkly4out7f2d`，与既有 25 个 uid 无碰撞
- ⚠ parse-check.ps1 的修复内容（1 增 1 删）：`"res://" + $dir + "/" + $_.Name` →
  `"res://" + $_.FullName.Substring($Project.Length + 1).Replace('\', '/')`

> 说明：本批为 `13cb52f` `22386be` 两个内容提交，写这一行时两者**已推送**
> （`a48c595..22386be`，`git rev-parse HEAD` = `git ls-remote origin refs/heads/main`
> = `22386be`）；记录本行的 push-log 提交自身即为 HEAD 之后一格，符合本文件「最后一行
> 永远落后一个 commit」的自指说明。

### 2026-10-13 SPLIT-CHECKS-BENCH-002 这一批的内容

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `f6033f3` | 台架验收族迁出至 `scripts/checks/bench.gd`（SPLIT-CHECKS-BENCH-002 纯迁移，main.gd 4033→3346 行、func 66→58；模块 await 恰 4 处 = 2 处注入的 `_physics_frame.call()` + 2 处族内 `_run`） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/checks/bench.gd`(+`.uid` = `uid://chkbench002ab`)、`godot-logs/`（本批证据文件 `git add -f` 强制入库） |
| `b767e5f` | AGENTS.md 同步（§1 核心代码列表 / §2.1 进度表 SPLIT-CHECKS-BENCH-002 行+现状行 / §2.4 模块清单七→八 + await 约定行补 bench「恰 4 处」）；两份逐字节一致 | `godot-racer/AGENTS.md`、`AGENTS.md`（根副本） |
| （记录本行自身的提交） | push-log 落本批记录 | `godot-racer/docs/push-log.md` |

本批验收（`run-all-checks -Quick` 绑定 `f6033f3`、工作区含本次改动；其余证据 `godot-logs/`）：

- 结构校验（`split-checks-bench-structcheck.ps1`，15 项断言）：先红 **9 项失败**
  （`split-checks-bench-structcheck-red-run.log`：模块未建 / main.gd 残留 48 处 token /
  接线 0 处 / uid 未建 / 规模仍 4033·66）→ 绿 **15/15**（`-green-run.log`）→ A/B 后复跑仍
  **15/15**（`-postab.log`）。⚠ 红跑里「预期规模 3347」是迁移前的**预测值**，落地实测
  **3346**（4033 − 705 + 18 = 3346，与模块正文 702 行口径互校），绿跑起按实测值断言
- 文本级完备性核对（`split-checks-bench-textverify.py`）：HEAD 原始块 `L2326-3027`（702 行）
  与模块正文 diff，**只剩 4 个 hunk / 6 处文档化变换**：`_check_steerbench`→`run_steerbench`、
  `_check_brakebench`→`run_brakebench`、两处 `get_node_or_null("Track")`→`_track`、两处
  `await get_tree().physics_frame`→`await _physics_frame.call()`（**零转录漂移**）
- A/B 舞步（`split-checks-bench-ab-dance.ps1` v1 + `-dance2.ps1` v2；分析报告
  `split-checks-bench-ab-report.md` + `-ab-analysis.log`）：
  **v1 的「骨架逐行相同」判据对本族必然假红并正确停下报告**（台架逐帧 dump 有相位/墙钟
  噪声：同代码两跑 8528 vs 8524 行、difflib 报 12368 行差异；相对极差又被近零字段放大成
  100%）。v2 把判据改成**结构化结论记录 + 组内噪声底包络**，采集 steerbench 3 迁移 + 2 HEAD、
  brakebench 2+2：
  - steerbench：最大跨组差 **1.67%** ≤ 最大组内极差 **3.41%**。关键格
    `(steer=0.100, v0=120)`：mig={52.470, 52.460, 52.470}（组内 0.02%），
    ctrl={**50.710**, 52.470}（组内 3.41%）→ 偶发落在 **ctrl 组内部**，HEAD 代码在另一次
    运行里同样给出 52.470
  - brakebench：最大跨组差 **0.199%** ≤ 最大组内极差 **0.330%**
  - 结构：24 格有效帧数在 mig 与 ctrl **全部样本里完全一致**
  - 时序：**所有配对（含同代码对）前 539 帧逐字节相同**，分歧起点 539/543 与代码版本无关
    （若迁移改了协程时序，第 1 帧就该分叉 —— opponent_spawner 1 帧 = 25856 行发散的教训）
- `lint-gdscript.ps1` / `parse-check.ps1` / `run-all-checks -Quick`：`LINT_EXIT=0`、
  `PARSE_EXIT=0`、`RUNALL_EXIT=0`（15/15）
- ⚠ `bench.gd.uid` 为**手写**（headless 不自动生成 .uid）：`uid://chkbench002ab`，
  与既有 27 个 uid 无碰撞
- ⚠ **环境事实留证（非本批引入，判据未改）**：本机跨进程可复现性已退化 —— 历史基线
  （2026-10-11 repro A/B/C）逐格最大极差 **0.054%**，今天**同代码两跑**已达 **1.17%**。
  项目现行「跨进程极差 ≤1%」判据在**今天的机器状态下连同代码都可能判红**。本批**不动该
  判据**（改判据＝改验收契约，需用户签字），只把事实记进 `split-checks-bench-ab-report.md` §6；
  后续跑 `steerbench-repro.ps1` / `brakebench-repro.ps1` 前应先确认机器空闲

> 说明：本批为 `f6033f3` `b767e5f` 两个内容提交（外加记录本行的 push-log 提交自身），
> 写这一行时前两者**已推送**（`d03bc16..b767e5f`，`git rev-parse HEAD`
> = `git ls-remote origin refs/heads/main` = `b767e5f`）；记录本行的 push-log 提交自身即为
> HEAD 之后一格，符合本文件「最后一行永远落后一个 commit」的自指说明。

### 2026-10-13 SPLIT-CHECKS-AI-003 这一批的内容

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `0771984` | AI 验收族迁出至 `scripts/checks/ai.gd`（SPLIT-CHECKS-AI-003 纯迁移，main.gd 3346→2577 行、func 58→53；模块 await 恰 8 处 = 6 处注入的 `_physics_frame.call()` + 2 处注入的 `_sample_physics_ms.call()`） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/checks/ai.gd`(+`.uid` = `uid://chkaichecks03`)、`godot-logs/`（本批 54 个证据文件 `git add -f` 强制入库） |
| `adc2621` | AGENTS.md 同步（§1 核心代码列表 / §2.1 进度表 SPLIT-CHECKS-AI-003 行+现状行 / §2.4 模块清单八→九 + await 约定行补 ai「恰 8 处」）；两份逐字节一致 | `godot-racer/AGENTS.md`、`AGENTS.md`（根副本） |
| （记录本行自身的提交） | push-log 落本批记录 | `godot-racer/docs/push-log.md` |

本批验收（`run-all-checks -Quick` 绑定 HEAD `92d4b5f` + 工作区含本批改动 —— 与前两批同口径；
其余证据 `godot-logs/`）：

- 结构校验（`split-checks-ai-structcheck.ps1`，15 项断言）：先红 **9 项失败**
  （`split-checks-ai-structcheck-red-run.log`：模块未建 / main.gd 残留 40 处 token /
  接线 0 处 / 35 条日志锚串全缺 / await 0 处 / uid 未建 / 规模仍 3346·58）→ 绿 **15/15**
  （`-green-run.log`）→ 改 AGENTS.md 后复跑仍 **15/15**（`_ai-structcheck-postdoc-console.log`）
- 文本级完备性核对（`split-checks-ai-textverify.py`，**反向**核验器：`git show HEAD:` 取原文、
  不复用 `extract.py` 的替换逻辑，避免自证）：HEAD 原始块 793 行 → 模块正文 799 行，
  21 条机械改动**全部可用 10 条替换解释**（5 处函数改名 `_check_*`→`run_*`、6 处
  `get_node_or_null("Track")`→`_track`、1 处 `get_node_or_null("Obstacles")`→`_obstacle_field`、
  1 处 `get_world_3d().direct_space_state`→`_world_3d.direct_space_state`、6 处
  `await get_tree().physics_frame`→`await _physics_frame.call()`、2 处
  `await _sample_physics_ms(`→`await _sample_physics_ms.call(`），块接缝补 3 处/6 行空行，
  **未解释差异 0** → 零转录漂移
- A/B 舞步（`split-checks-ai-ab-dance.ps1`；分析 `split-checks-ai-ab-analyze3.py` +
  `-diffdetail.py`；报告 `split-checks-ai-ab-report.md` + `-ab-analysis.log`）：
  **26 份样本**（opponents 5 迁移 + 5 HEAD，其余 4 项各 2+2）。判据为**数据驱动噪声底**：
  ① 跨组差 ≤ 同代码组内极差 ② 存在至少一对 m↔c 完全零差 ③ 判定串集合两组一致
  - **`obstacles`：四跑全部 0 差异**（含 2 份 HEAD 原码），13 行判定逐字相同 —— 最强证据
  - **`opponents`：11 对 m↔c 零差**，含 **`m2≡c3`、`m4≡c3`、`m5≡c3`**
    （一份迁移态日志与一份 HEAD 原码日志归一化后逐行相同）；跨组最大差 3 = 噪声底 3
  - `aidiag` 噪声底 8（**全在 HEAD 组内部** c1↔c2）/ `avoid` 噪声底 3（全在迁移组 m1↔m2）/
    `aistart` 噪声底 1（HEAD 组 c1↔c2）；跨组差均未超各自噪声底，差异全是小数点后一位
    或三帧时序（如 `玩家=104.1 vs 104.2`、`最小中心距 2.92 vs 2.90`、`玩家 0.11 vs 0.10 km/h`）
  - 总判：**本批 5 项通过 ✔**（`split-checks-ai-ab-analysis.log` 末行，EXIT=0）
- `lint-gdscript.ps1` / `parse-check.ps1` / `check-docs.ps1` / `check-readme.ps1` /
  `run-all-checks.ps1 -Quick`：`LINT_EXIT=0`、`PARSE_EXIT=0`、`CHECKDOCS_EXIT=0`、
  `CHECKREADME_EXIT=0`、`RUNALL_EXIT=0`（15/15；本批 3 项 obstacles / aistart / avoid 全绿）
- ⚠ `ai.gd.uid` 为**手写**（headless 不自动生成 .uid）：`uid://chkaichecks03`，
  与既有 28 个 uid 无碰撞
- ⚠ **`opponents` 的 ✘ 属已知缺陷，非本批引入（本批关键对照）**：4 份 `✘` 样本
  （迁移态 m2/m4/m5 + **HEAD 原码 c3**）指纹**逐字相同** —— 自救**恰 1 次**、
  `[诊断] arc=` **789.2**、终点 **51 · 0.97 · 5.20**、卡点世界坐标
  `(-187.348, −0.057, −93.88)` 一致到 1 cm —— 逐项吻合 `docs/testing.md` L889+ 登记的
  **BUG-L5-001**（检疫至 2026-10-19）。**HEAD 原码复现同一离群 ⇒ 排除迁移成因。**
  帧数亦吻合检疫登记的双稳态两簇：绿 10977~11008（登记 10976）/ 红 11656~11657
  （登记 11539~11654，m5 超上界 3 帧属抖动）。⚠ `-Quick` **跳过** `slow=$true` 的
  aidiag/stress/opponents/lap，故 opponents 不在 Quick 集内，不影响上表
- 📌 **本批新增架构定论**：`_sample_physics_ms` 是 checks 族**共享采样器**（main 的
  `_after_world_ready` 也用它测对手基线）→ **采样口径属 main，采样器不搬进模块**，
  改 `Callable` 注入。搬走会让 setup 路径**反向** main→模块，正是 `opponent_spawner`
  实证过的「多一层协程 = physics_frame 恢复时机差 1 物理帧」陷阱；`await X.call()` 与
  直接 `await X` 的协程层次完全相同（Callable 只是调用方式，不加协程层）

> 说明：本批为 `0771984` `adc2621` 两个内容提交（外加记录本行的 push-log 提交自身），
> 写这一行时前两者**已推送**（`92d4b5f..adc2621`，`git rev-parse HEAD`
> = `git ls-remote origin refs/heads/main` = `adc2621`）；记录本行的 push-log 提交自身即为
> HEAD 之后一格，符合本文件「最后一行永远落后一个 commit」的自指说明。

### 2026-10-14 SPLIT-CHECKS-ENVPHYS-004 这一批的内容（含 GATE-REPAIR-001）

用户令「先 push 上去」→ 把被中断会话滞留在工作区的批次④成果按批次①-③ 惯例固化。

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `4e524fb` | **GATE-REPAIR-001**：`bench.gd` 满舵判据由字面量 0.45（那是矩阵最大值，不是真满舵）改为**真源 0.5**（= `vehicle.max_steer` = `racing_line.STEER_MAX`）并补 `0.50` 一列；`push-log.md` 把收尾行的「全部 N 项」措辞改为「本批 N 项」（原句里的计数会被 `check-docs.ps1` 当作与 `run-all-checks` 总项数 19 比对的声明，故自 `943037d` 起长期红）。**闸门脚本零改动**（用户签字：改 bench = 改验收契约） | `godot-racer/scripts/checks/bench.gd`、`godot-racer/docs/push-log.md` |
| `0fc8eb2` | 环境物理验收族迁出至 `scripts/checks/env_phys.gd`（**SPLIT-CHECKS-ENVPHYS-004** 纯迁移，main.gd 2577 行/53 func → **1613 行/36 func**；模块 await 恰 29 = 16 注入 physics_frame + 1 `_friction_probe` + 9 `_flip_case_*` + 3 `_flip_hunt_trial`；`match _check:` 分发口与三个 CASES 常量留守 main.gd） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/checks/env_phys.gd`(+`.uid` = `uid://chkenvphys004`) |
| `fcfd541` | AGENTS.md 新增第 8 条「单个代码文件 ≤1000 行」（来源未在本轮派工单内，先入库以免丢失） | `AGENTS.md`、`godot-racer/AGENTS.md` |
| `060b738` | 新增跨平台交接文档 `HANDOVER.md`（用户将换平台） | `HANDOVER.md`（仓库根；不在 check-docs / check-readme 扫描集内，已实测两闸门仍 EXIT=0） |
| `ba5e31f` | AGENTS.md 同步 SPLIT-CHECKS-ENVPHYS-004（§1 核心代码列表 / §2.1 进度表+后续候选+现状行 / §2.1 checks 族 await 钉死行 / §2.4 模块清单 九→十 + await 约定行）+ **第 8 条按用户签字改为「向前约束」** | `AGENTS.md`、`godot-racer/AGENTS.md` |
| `9628ea0` | 批次④ **A/B 闭环（结构判据）** + 证据入库 | `godot-logs/` 本批 **56 个证据文件**（`git add -f` 强制入库，`godot-logs/` 被 .gitignore 忽略） |

**第 8 条「向前约束」定稿（用户 2026-10-14 签字）**：≤1000 行只约束**新建文件与本次改动的
文件**；4 个现存超限文件登记为**历史遗留**、随 `SPLIT-*` 批次逐步收敛、**不阻塞其修复性提交** ——
`scripts/ai_opponent.gd` 1668 / `scenes/main.gd` 1613 / `scripts/vehicle.gd` 1413 /
`scripts/checks/env_phys.gd` 1111（当日实测；`ai_opponent` 与 `vehicle` 是核心玩法文件，
AGENTS §2.2 明令禁止大规模一次性重构）。

**A/B 定案（用户 2026-10-14 签字「按结构结案」）**：
- 原 `split-checks-envphys-ab-analyze.py` 的**逐行**判据：`flip` / `phys` / `weather` /
  `friction` 四项跨组**零差**；`wallslide` / `stuck` 残差 1~2 / 7~12 行 → 判 ✘。
  **该记录保留不覆盖**（`split-checks-envphys-ab-analysis.log`）。
- 新增 `split-checks-envphys-ab-closure.py`，按 AGENTS §4.3「非确定性检查只比结构」重判：
  ① 行数一致 ② 判定串集合一致 ③ **骨架多重集一致**（数字全部抹为 `#` 后逐对相同，
  即无任何行被增删 / 改文案 / 改逻辑）→ **6/6 通过 ✔**（`-ab-closure.log`，EXIT=0）。
- **排除迁移成因的关键反证**：同代码对照组自身非零且量级相当 —— `stuck` 同代码
  **m1↔m3 = 12 行** == 跨组最大差 12；`wallslide` 跨组 2 ≤ 同代码 `c1↔c2` = 2；
  且 `m1↔m2` 与 `m1↔c2` 出现**逐字相同的 ±1~2 帧相位移位块**。残差内容全是物理浮点抖动
  （pos 第 4~6 位小数、侧倾 0.1°、km/h 0.1、命中距离 0.01m）。
- 意义：这两个 check 会打印物理浮点，跨进程**不可逐行复现**，逐行判据不适用；此法理与
  批次③ `opponents` 的「HEAD 原码复现同一离群 ⇒ 排除迁移成因」一致。

**验收（本机实测，绑定 `ba5e31f` / `9628ea0` 工作区与 `0fc8eb2` 代码内容）**：
`lint` EXIT=0 / `parse` EXIT=0 / `check-docs` EXIT=0 / `check-readme` EXIT=0 /
`check-dup-source` **5 项通过 / 0 项不一致** / `run-all-checks -Quick` **15/15 通过**
（`RUNALL_QUICK_EXIT=0`，含批次④ 的 wallslide / flip / weather / friction / phys 全绿）；
`split-checks-envphys-structcheck.ps1` **15 项断言 0 失败**（含 await 恰 29、main.gd 零残留
token、两份 AGENTS.md 逐字节一致）。证据：`godot-logs/_push-preflight.log`、
`_push-quick.log`、`_envphys-postdoc.log`、`split-checks-envphys-structcheck.log`。

> 说明：本批分**两轮推送** —— 第一轮 `3298de4..060b738`（`4e524fb` `0fc8eb2` `fcfd541`
> `060b738`），第二轮 `060b738..9628ea0`（`ba5e31f` `9628ea0`）；复核
> `git rev-parse HEAD` = `git ls-remote origin refs/heads/main` = `9628ea0`。
> 记录本行的 push-log 提交自身即为 HEAD 之后一格，符合本文件「最后一行永远落后一个
> commit」的自指说明。

### 2026-10-14 OpenRouter 整体移除 这一批的内容

用户令「继续完成未完成的任务」并签字「**彻底移除功能**」。原话："OpenRouter API key
可选，只在联网生成测试用例时需要。玩游戏不需要这一个功能。readme 文档中也不要提
这一个招笑的示例。"

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `522c983` | **总体移除 OpenRouter 联网测试功能**：删 scripts/openrouter_client.gd（+其 .uid）/ 04-Godot启动器/test-openrouter.ps1 / tools/test_generator.py / openrouter.cfg.example / 本机 openrouter.local.cfg（真实 key，一直被 .gitignore 排除、**从未入库**）；`main.gd` 删 `match _check:` 的 `openrouter` / `models` 两分支与两函数 → **检查项 26 → 24**，`_check_stress()` 去掉 OpenRouter 旁路（客户端改挂 + AI 归因）；`ai_test_driver.gd` 改为自持 `_load_local_cases()` 直读 `res://data/ai_test_cases.json`（**保留为离线确定性夹具**），报告键 `ai_cases_used`/`ai_failures` → `cases_used`/`case_failures`；`run-check.ps1` 删两条超时项；`launcher-menu.ps1` 删「生成用例」两项菜单、菜单重排号、顺带修正过时项数；`启动器.bat` 菜单说明改「设计赛道」；`lint-gdscript.ps1` 注释举例改通用；`.gitignore` 收紧为通用 `*.local.cfg` / `.env` / `*.env` | `godot-racer/scenes/main.gd`、`godot-racer/scripts/ai_test_driver.gd`、`godot-racer/data/ai_test_cases.json`、`04-Godot启动器/run-check.ps1`、`04-Godot启动器/launcher-menu.ps1`、`04-Godot启动器/启动器.bat`、`04-Godot启动器/lint-gdscript.ps1`、`.gitignore`、删除 5 个文件（含 `.uid`）、证据 `godot-logs/_or-clean-gate3.log`、`_or-clean-quick.log` |
| `18eeae0` | 文档全面去 OpenRouter 提及：README「配置（可选）」整段 + 环境要求表行 + 检查项计数（26 → 24、未入套件 9 → 7）；AGENTS §1 行 + §11 改写为「移除说明 + 仍生效的通用原则」；`testing.md` 检查项表行 + 「测试用例生成器」节改写；`engineering-notes.md` 加移除说明；`HANDOVER.md` 同步 | `README.md`、`AGENTS.md`、`godot-racer/AGENTS.md`、`godot-racer/docs/testing.md`、`godot-racer/docs/engineering-notes.md`、`HANDOVER.md` |

**为什么必须连代码一起删（本机实测的两条硬约束）**：

1. `check-readme.ps1` 第 ② 条要求「`main.gd` 里实现的每个检查项，文档里必须被提到」——
   只删 README、保留代码会**直接把闸门打红**。
2. `openrouter` / `models` **不在** `run-all-checks.ps1` 的 19 项里（套件项数不变），
   所以移除它们是**功能删除**、不改套件契约；但会改 `main.gd` 的检查项计数（26 → 24），
   README / HANDOVER 随之更新。

**验收（本机实测）**：`lint` EXIT=0 / `parse-check` EXIT=0 / `check-docs` EXIT=0 /
`check-readme` EXIT=0（实测 **24** 检查项）/ `check-dup-source` **5 项通过 / 0 项不一致** /
`run-all-checks -Quick` **15/15 通过 ✔**（`RUNALL_QUICK_EXIT=0`）/ `run-check -Check stress`
通过 ✔（读落盘用例 **10** 组、帧数 3000、卡死 0、兜底 0 失败）。
证据：`godot-logs/_or-clean-gate3.log`、`_or-clean-quick.log`。

> 说明：本批为 `522c983` `18eeae0` 两个内容提交，写这一行时两者**已推送**
> （`f999af1..18eeae0`，`git rev-parse HEAD` = `git ls-remote origin refs/heads/main`
> = `18eeae0`）；记录本行的 push-log 提交自身即为 HEAD 之后一格，符合本文件「最后一行
> 永远落后一个 commit」的自指说明。

### 2026-10-14 SPLIT-CHECKS-BASIC-005 这一批的内容（checks 族批次⑤·压轴）

`scenes/main.gd` 拆分的**最后一批**：把基础验收族与跑圈/压测/反向族迁出。OpenRouter 移除后
`scenes/main.gd` 为 1522 行 / 34 func，本批后 **659 行 / 17 func**，`--check=` 函数体拆分
**收尾完成**。

| commit | 内容 | 它带来的文件 |
|---|---|---|
| `f8b2cb2` | 基础验收族 + 跑圈/压测/反向族迁出至 `scripts/checks/basic.gd` 与 `scripts/checks/lap.gd`（**SPLIT-CHECKS-BASIC-005** 纯迁移；basic 模块 await 恰 12、lap 恰 8；`match _check:` 分发口与三个 CASES 常量留守 main.gd） | `godot-racer/scenes/main.gd`、`godot-racer/scripts/checks/basic.gd`(+`.uid` = `uid://chkbasic005aa`)、`godot-racer/scripts/checks/lap.gd`(+`.uid` = `uid://chklap00500ab`) |
| `25934e6` | AGENTS.md 同步（§1 核心代码列表 +§2；第 8 条超限名单去掉 main.gd；§2.1 进度表 + 后续候选/现状行；§2.1 await 钉死行补 basic/lap；§2.4 模块清单 十→十二 + await 约定行） | `AGENTS.md`、`godot-racer/AGENTS.md` |
| `4d3a7cd` | 批次⑤ **证据入库**（structcheck 红→绿 / 文本级反向核对 / A/B 闭环 / 全量验收；`git add -f`） | `godot-logs/` 本批 **49 个证据文件** |

**为什么一个批次拆成两个模块**：本批待迁 17 个函数（迁出后两模块**合计 1206 行**）塞进单个
新模块会撞破 §8「新建文件 ≤1000 行」的**向前约束**（该条不豁免新文件）。故按族拆：
`basic.gd`（**608 行**，场景 / 边界 / UI 族）+ `lap.gd`（**598 行**，跑圈 / 压测 / 反向族）。

**三条关键设计决定**（详见两模块文件头决策注释）：
- **helper 归「消费方」而非计划书的字面归属**：`_cp` 只被 `run_escape` 调、`_find_wrong_way_panel`
  只被 `_check_reverse_e2e` 调 —— 计划书正好把两者放反了。放消费方 = 零环、零复制，且同样
  全部离开 main.gd（照字面放会让两模块互相注入对方 Callable 或复制第二份，违 §5.3）。
- **SceneTree 注入**：basic 族的非信号 tree 能力（`process_frame` 信号 / `paused` / 分组查询 /
  视口 `push_input`）经注入的 `SceneTree` 引用提供（与 ai.gd 注入 `World3D` 同属「注入引擎对象
  而非场景节点」）；`get_viewport().push_input(ev)` 与 `_tree.root.push_input(ev)` 是同一对象
  （main 挂在场景根，`Minimap/SubViewport` 非其祖先，已核实）。lap 族另用 `_add_child` Callable
  挂 `stress` 的鲁莽玩家 driver。
- **await 数一拍不加**：basic 恰 12、lap 恰 8，与迁移前一致，由各自 structcheck 机器钉死。
- **复核钉死的三条机器断言**（structcheck 各有一条独立输出）：① 模块内 `await` 数（basic 恰 12 /
  lap 恰 8）；② 模块内无裸 `get_node(` / `get_tree(` / `get_viewport(`，且无 `preload` 反向
  引用 main.gd（绕开注入、制造第二份场景真相）；③ 注入的 `_tree` 只以 `SceneTree` 用（显式
  类型化 + 成员访问落在 SceneTree API 白名单内）。

**验收（本机实测）**：`lint` EXIT=0 / `parse-check` EXIT=0 / `check-docs` EXIT=0 /
`check-readme` EXIT=0 / `check-dup-source` 5 项通过 / `run-all-checks -Quick` **15/15 通过 ✔**；
本批两模块的 10 个检查项全部实跑通过（enclosure / minimap / pause / reverse 在 Quick 内；
reset / oob / resetkey / escape / lap / stress 另跑）；`split-checks-basic-structcheck.ps1`
与 `split-checks-lap-structcheck.ps1` 各 **17 项断言 0 失败**；`split-checks-basic-textverify.py`
与 `split-checks-lap-textverify.py` **代码零漂移**（登记替换后逐行相同 + HEAD 注释零丢失）；
A/B（HEAD 码 vs 迁移后码）：reverse 纯函数段逐行相同、lap 结构零差。证据：
`godot-logs/split-checks-basic-*`、`godot-logs/split-checks-lap-*`、`_b5-*`。

> 说明：本批为 `f8b2cb2` `25934e6` `4d3a7cd` 三个内容提交，写这一行时三者**已推送**
> （`a96ee5e..4d3a7cd`，`git rev-parse HEAD` = `git ls-remote origin refs/heads/main`
> = `4d3a7cd`）；记录本行的 push-log 提交自身即为 HEAD 之后一格，符合本文件「最后一行
> 永远落后一个 commit」的自指说明。
>
> 追加：`4d3a7cd` 推送后，又补了 1 笔**结构校验强化 / 行数勘误**提交（structcheck 补
> 「模块总行数 ≤ 1000 行」与复核钉死的三条机器断言、勘正本节两模块行数 608 / 598 行），
> **代码与 AGENTS 零改动**，只动 `godot-logs/` 证据与本文档；记录这条追加说明的 push-log
> 提交自身，即为它之后一格。

### 2026-10-15 GATE-L4-001：opponents 补 L4 门禁

原套件仅运行 L5；用户批准增加 L4 后，opponents 按 L4/L5 分两行串行运行，
使用 run-check 既有 LogName 参数分别保存日志。全量套件 20 行，Quick 仍 15 行，
游戏检查入口仍 24 个。原通过判据、超时、重试次数均保留；失败汇总标出具体关卡。

内容提交：`a7294a1525ce1b2b88fe4898f2b87172b4638785`。
文件：run-all-checks.ps1、README、HANDOVER、testing.md 与本批 17 个证据/检查文件。

**验收与版本绑定**：运行发生于 2026-10-14 22:53–23:11（+08:00），HEAD 为
`18b2069507f38c14cedc2b986b7f9799f33984f2` + 本批三个已跟踪文件改动，另有两个未跟踪
Blender 中间产物。覆盖检查先红（14 条失败）后绿（19/19）；五道闸门 EXIT=0，
Quick 15/15；opponents 子集 EXIT=1，L4 15984 帧 / 1 圈 / 自救 11 次，
L5 本次 10974 帧 / 1 圈 / 自救 0 次。收尾文档三道闸门再次通过。

提交后的 runner Git blob 为 `dbf2d0d1ae83e9104b06d48444366680090aa5d8`，
与实测文件归一化 blob 一致；AI/场景/关卡数据/项目配置相对基线零差。
因此本条明确记录“基线 + 工作区改动”的实测，不伪称对干净 a7294a1 重新运行过引擎。
证据：`godot-logs/gate-l4-001-report.md`、同前缀 binding/validation/contract/quick/opponents 日志；
两关原始日志已独立保存。全量 20 行未整套重跑，aidiag/stress/lap 本轮未单独运行。

**保留的缺陷**：L4 自救违反原判据，红灯不豁免；L5 单次通过不解除 BUG-L5-001 检疫，
仍到 2026-10-19、不自动续期。后续按 L5 修复 → L4 修复严格串行。

推送后命令复核（2026-10-15 08:59:06 +08:00）：

```text
git rev-parse HEAD
a7294a1525ce1b2b88fe4898f2b87172b4638785
git ls-remote origin refs/heads/main
a7294a1525ce1b2b88fe4898f2b87172b4638785 refs/heads/main
git rev-list --left-right --count origin/main...HEAD
0 0
```

记录本条的 push-log 收尾提交自身位于该内容提交之后，遵循本文件的自指记录惯例。

### 2026-10-15 LICENSE 与素材来源补录

用户选择 MIT，并确认 rain_loop.ogg 来自 SoundDino 下载的 MP3，由用户自行转换为 OGG。
提交 `f78882d82a4cd7ddc83bee2366a0089a048adb02` 新增 LICENSE、THIRD_PARTY_NOTICES.md、
README 的许可入口及三道文本闸门证据。第三方音频排除在项目 MIT 授权之外，
保留官网条款入口、转换后文件 SHA256，以及原始条目 URL 尚未补齐的边界。
没有替换用户音频，也没有将来源不详的资产标成 CC0。

实测：文档三道闸门 EXIT=0。推送后于 2026-10-15 09:12:13 +08:00 复核：
本地 HEAD = 远端 refs/heads/main = `f78882d82a4cd7ddc83bee2366a0089a048adb02`，差异 0/0。
当时 L5 物理修复在工作区单独验收，未包含在该许可证提交中。

### 2026-10-15 BUG-L5-001 修复收尾

内容提交 `ff18a0233639f598892d7f1e4cff91e41741fa3c` 已于 14:14 推送，
14:14:29 +08:00 实际核对 HEAD = origin/main = ls-remote，左右差异 0/0，
原始回执 `godot-logs/l5-final-push.log`。该提交中两份生产脚本 blob 与实测一致：
AI `fe38b674492b7f15c173030dd65409dd93f84ab5`、RacingLine `39cea821f4fb6ccc0f2f76b7a01e4686d58a0a9e`。

实测基线为 `f78882d` + 本批工作区，完整回执见 `godot-logs/l5-final-report.md`：
四组 TDD 红→绿、补充检查 19/19、五道闸门 EXIT=0、L5 opponents 三次冷启动
11323/11331/11321 帧全部 1 圈零自救、越过旧卡点截图、Quick 15/15、L1 aidiag 通过。
首次 Quick 中断记录保留，最终通过结果取 `l5-resume-*`，未放宽任何既有判据。
文档同步后又跑三道文本闸门全 EXIT=0。整套 20 行、L4 专项及长时 lap/stress 本次未跑，
雪地高速度域抱死风险仍保留。用户确认本轮到 L5 收尾即暂停，L4 和雨声接线留待新对话。

本条与推送回执由后续文档提交入库，沿用既有自指记录惯例；不要把记录提交号误作运行基线。

### 2026-10-15 L4 当前基线与圆弧红用例

证据提交 `ed7802c0985612af643fc17abac1f9d832e1d844` 已推送；14:25:06 +08:00
实际复核 HEAD = origin/main = GitHub refs/heads/main，左右差异 0/0。
原始回执 `godot-logs/l4-red-push.log` 由下一内容提交纳入，遵循本文件自指记录惯例。

基线为干净的 4dbc98a（仅两项约定保留的 Blender 中间产物）：L4 opponents
15527 帧、1 圈、自救 9，FAIL；五道闸门通过。圆弧夹具调用真实 AI 转向入口，
所需 -0.01831rad、实得 -0.08214rad，明确 EXIT=1；数值和首次自救前截图已入库。
此步没有改生产代码，不将 L4 标记为已修复。后续候选必须另绑工作区哈希与实测。

### 2026-10-15 L4 AI 修复与重启恢复收尾

内容提交 `d845ff5295bb18b517836cf2810088c7309840d1` 已推送。
22:40:29 +08:00 实际核对：

```text
HEAD=d845ff5295bb18b517836cf2810088c7309840d1
origin/main=d845ff5295bb18b517836cf2810088c7309840d1
GitHub refs/heads/main=d845ff5295bb18b517836cf2810088c7309840d1
origin/main...HEAD=0 0
```

原始回执 `godot-logs/l4-recovery-content-push.log` 随本条所在文档提交入库，遵循自指记录惯例。
实车验收基线仍是 ed7802c + 工作区，最终提交的生产 blob 与实测完全相同：
L4 opponents 三次零自救、L5 三次零自救、L1 aidiag、Quick 15/15；有效图越过旧卡点。
重启恢复另修正开发回执误报、玩家红灯夹具、出生点误拍，原始失败记录保留。
恢复补充检查 9/9、5/5、19/19，回执自测 6/6；五道闸门与 PowerShell 语法全部通过。
玩家 lap 仍卡住 3 / 疑似复位 5，正式控制未改；未集成 WorkBuddy 资产、未接雨声。
本条之后仅交接文档收尾，实际最新 HEAD 用 Git 读取，不把文档提交误作干净实车复跑。

### 2026-10-16 L4 玩家自动驾驶补充回归与交接

生产修复内容提交 `57bdea470264f3e3031c14c02edc1ea1c67c7ce7` 的
`autopilot.gd` blob 为 `ebdf2e63b8737f13e32b35be18cb391551276a02`。
本批没有改生产代码。证据/交接提交 `a6aa520eaded271cc3eab8c7911b81266834616e`
已推送；推送后实际核对：

```text
HEAD=a6aa520eaded271cc3eab8c7911b81266834616e
origin/main=a6aa520eaded271cc3eab8c7911b81266834616e
GitHub refs/heads/main=a6aa520eaded271cc3eab8c7911b81266834616e
origin/main...HEAD=0 0
```

AI opponents L4/L5 各一次均 1 圈、零自救、未出界、`DONE EXIT=0`；Quick 15/15、
`DONE EXIT=0`。玩家 L4 真实跨起点后截图已有画面与数值，但截图进程保存后退出异常
`-1073741819`，不计作绿色退出。所有原始证据与未闭环边界见
`godot-logs/l4-current-report.md` 最后一节。WorkBuddy staging 未集成。
本条随文档收尾提交入库，记录的是上一个证据提交的远端核对，不把文档提交误认作生产变化。

### 2026-10-16 接手核对与交接状态同步

接手时重新 fetch 并查询实际远端，确认：

```text
HEAD=ce304c5403196379ab6e4addc7c70e26b182174b
origin/main=ce304c5403196379ab6e4addc7c70e26b182174b
GitHub refs/heads/main=ce304c5403196379ab6e4addc7c70e26b182174b
origin/main...HEAD=0 0
```

五份生产脚本的工作区与 HEAD blob 均与 l4-current-report.md 对应实车版本一致；
从玩家修复内容提交 57bdea4 到本次接手，生产脚本、场景与工程配置无提交差异。
本批仅同步 HANDOVER 的概要/待办与 l4-reachability 计划中遗漏的玩家完成状态、
既有补充回归及截图退出异常，保留历史失败与工作区验收边界；未重新运行物理验收或资产测试。
三道文本闸门的本批结果见仓库根 godot-logs/l4-handover-state-check.log。

本节记录的是接手基线，所在文档提交会推进 HEAD；最终推送同步以现场 Git 与
godot-logs/l4-handover-state-push.log 为准，不将后续文档提交改称生产变化或干净提交复跑。

### 2026-10-16 L4 玩家截图取证夹具退出修复

接手基线为 `f7accad3a4a1190f00927158e0b8e5914716fe76`，生产代码、场景、
关卡配置及验收判据未改。旧夹具有效红灯：PNG 保存成功，但进程
`-1073741819`、`DONE EXIT=1`。只改截图夹具成功保存后的退出路径：
不提前终止尚在等待物理帧的原 `--check=lap`，而让它自行完成并退出。
独立正式回归在跨起点后 arc260.08 保存有效截图，三圈 lap 通过，进程 0、
`DONE EXIT=0`；原始证据与工作区 blob 见 `godot-logs/l4-current-report.md` 末节。

取证夹具与证据内容提交 `4178a7c123754db60ea30dc94cb96a0f00ea06dc` 已推送；
其夹具 blob 为 `9d7ae5f6801dfbb928accd170d8c67065a4984a3`，与正式回归一致。
推送后实际核对 HEAD = origin/main = GitHub refs/heads/main 均为该提交，
左右差异 0/0。原始回执 `godot-logs/l4-capture-exit-push.log` 随本条所在文档提交入库，
遵循自指记录惯例；最终最新 HEAD 仍以现场 Git 为准。
这不是生产逻辑变化或干净提交实车复跑；此前失败记录保持可追溯。

### 2026-10-17 Windows 首版功能与倒计时交接计划

功能提交 `0e5430f7a1f5e4adfd25f886c4297550ac48b01d` 已推送，包含结算、退出确认、显示设置、雨声与构建脚本。该提交的 60 FPS Quick 15/15、进程退出码 0；全量 20 项、双帧率长时跑圈与最终发布包仍未完成。测试时工作区另有四组未跟踪素材/审计文件，未入提交。

计划提交 `f0a8d9c11ab255e991ba36d2c0f7bd2328b1285b` 已推送；新增 `plan/feature-race-start-results-1.md`，明确 3 秒倒计时、统一 AI 发车和结算闭环的下一步实施。推送后实测本地 HEAD = 实际远端 `refs/heads/main` = 上述计划提交，`origin/main...HEAD` 为 `0 0`。本条是随后入库的自指记录，不能把计划写成已实现功能；最终 HEAD 以现场 Git 查询为准。
