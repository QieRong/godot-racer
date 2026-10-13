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

- 无未推送的 commit（本轮 `9ba8dec` 已推，工作区仅剩根 `AGENTS.md` 这条未跟踪文件
  与 `.gitignore` 内的本机产物）。
- ⚠ 仓库根 `AGENTS.md` **未被 git 跟踪**（跟踪的是 `godot-racer/AGENTS.md`）。两处内容
  由 2026-10-13 起保持逐字节一致（各 1026 行），但 push 只覆盖仓库内那份；根目录那份
  是否纳入版本控制，**待用户拍板**（当前维持未跟踪）。
- `godot-logs/` 与 `data-analysis/screenshots/` 的其余调查产物按 `.gitignore` 留在本机，
  只把被文档引用到的截图入库。**例外**：SPLIT-SCREENSHOT-001 批（`ff80310`）按任务要求
  把 structcheck 脚本与红/绿日志、A/B 舞步脚本与三组证据共 17 个文件 `git add -f`
  强制入库（此前各拆分批次的同类证据均未入库）。

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
