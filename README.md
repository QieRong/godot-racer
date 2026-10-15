# Godot Racer

用 **Godot 4** 做的 3D 赛车游戏：5 个数据驱动关卡、会避让的 AI 对手、会真实改变抓地力的天气、
静态与滑动障碍，附带一套可自动化的验收测试。

![主菜单](screenshots/01-主菜单.png)

## 特性

- **5 个关卡**，难度递进（新兵训练营 → 阳光竞速场 → 雨夜街道 → 荒漠遗迹 → 极地挑战）。
  加关卡只需新增一个 `.tres`，不用复制场景。
- **AI 对手**：每关 1 台，与你**并排发车**（你起步它才起步），会主动绕开你，也会避让障碍。
  可在主菜单里关掉。
- **天气**：晴 / 雨 / 雪 / 沙尘。不只是换颜色——抓地力倍率真实生效（0.5~1.0）。
- **障碍**：静态障碍（合并为单个物理节点）+ 横向滑动路障，任何时刻都留得出一条通道。
- **小地图**：赛道轮廓 + 检查点 + 你 + 对手 + 障碍，四类标记用颜色和形状区分。
- **暂停菜单**：`ESC` → 继续 / 重新开始 / 返回选关 / 退出。

## 环境要求

| 需要 | 说明 |
|---|---|
| **Godot 4.4.1**（Windows） | 已用 `4.4.1-stable` 验证。默认期望装在 `E:\godot\` |
| Python 3.10+ | **可选**，只在用开发期工具（赛道布局闭环解算等）时需要 |

## 快速开始

1. 安装 Godot 4.4.1，解压到 `E:\godot\`
   （或改 `04-Godot启动器/launcher-menu.ps1` 里的 `$Godot` 和 `运行游戏.bat` 里的路径）
2. 双击 **`04-Godot启动器/启动器.bat`** → 选 `1) 运行游戏`

启动器菜单里还能跑验收测试、看日志、做启动诊断、设计新赛道。

> 也可以直接命令行：
> `Godot_v4.4.1-stable_win64.exe --path godot-racer`
>
> 用 `*_console.exe` 会在这台机器上启动期段错误，用不带 `console` 的那个。

## 操作

| 键 | 作用 |
|---|---|
| `W` / `S` | 油门 / 刹车·倒车 |
| `A` / `D` | 左 / 右转向 |
| `空格` | 手刹 |
| `R` | 复位（离赛道中心 < 3 m 时只扶正车身） |
| `V` | 切换视角（第一 / 第二 / 第三人称） |
| `M` | 显示 / 隐藏小地图 |
| `ESC` | 暂停菜单 |
| 右键拖动 | 环视 |

极速（80~240 km/h）和 AI 对手开关都在**主菜单**里调。

### 双击哪个 `.bat`？（四个入口，各管一件事）

| 双击 | 作用 |
|---|---|
| `04-Godot启动器/启动器.bat` | **主入口**：中文菜单（游玩 / 跑验收 / 设计赛道 / 看日志 / 诊断） |
| `04-Godot启动器/运行游戏.bat` | **直接开跑**：先跑 lint + 真语法闸门（挡"赛道不生成"那类坑），再启动，带崩溃重试 |
| `04-Godot启动器/打开Godot编辑器.bat` | 打开 Godot 编辑器改场景 |
| `04-Godot启动器/诊断Godot启动.bat` | 启动不了时用：逐个试启动方式并报告哪个能用 |

> 曾经还有一个 `launcher.bat`（和 `启动器.bat` 指向同一个菜单），2026-09 已删除 ——
> 两个入口做同一件事只会让人困惑。现在菜单入口只有一个。

## 目录结构

```
godot-racer/               Godot 工程
├── scenes/                场景（menu / main / track / race_car）
├── scripts/               游戏逻辑（vehicle / ai_opponent / obstacle_field / racing_line / track_layout / hud ...）
├── data/levels/           关卡配置（5 个 *.tres）
├── data/ai_test_cases.json --check=stress 的确定性极端用例（离线算得、可复现）
├── assets/textures/       AI 生成的地面与路面贴图
├── assets/audio/          雨声 loop 素材（尚未接线）
├── models/                赛车模型（来自 02-Blender建模）
├── tools/                 开发期工具（截图诊断、赛道布局闭环解算、几何解算）
└── docs/                  详细文档（见下）

04-Godot启动器/            双击即用的入口：游玩 / 验收 / 设计赛道 / 诊断
screenshots/              画面记录
```

> 赛道形状由 **路段 DSL** 描述（`scripts/track_layout.gd`：`straight/arc/sweeper/hairpin/chicane`）。
> 拼装**不保证首尾相接**，所以设计新赛道要先跑 `tools/layout_closure.py` 把长度解出来
> —— 手写长度几乎不可能闭合（实测有一版残差 340m）。

## 文档

| 文档 | 内容 |
|---|---|
| [godot-racer/docs/testing.md](godot-racer/docs/testing.md) | 验收检查怎么跑、每项的验收标准、最近一次结果 |
| [godot-racer/docs/engineering-notes.md](godot-racer/docs/engineering-notes.md) | **改代码前必读**：踩过的坑与验证方法 |
| [godot-racer/docs/ai-opponent-design.md](godot-racer/docs/ai-opponent-design.md) | AI 对手设计：并排距离的推导、车道、发车时机 |
| [godot-racer/AGENTS.md](godot-racer/AGENTS.md) | 本项目的开发契约（安全红线、工程规范、目录约定） |
| [godot-racer/docs/plans/tracks-and-elevation.md](godot-racer/docs/plans/tracks-and-elevation.md) | **赛道重设计总体计划**（路段 DSL / 起伏 / 地形带 / 五关设计 / 验收标准）与当前进度 |
| [godot-racer/docs/plans/phase2-elevation-pipeline.md](godot-racer/docs/plans/phase2-elevation-pipeline.md) | **阶段 2 实施计划**：起伏管道 + 地形带 + AI 坡度/物理限速 + 新验收；含 §六 任务表（唯一进度真相） |
| [godot-racer/docs/plans/task15-ai-corner-speed.md](godot-racer/docs/plans/task15-ai-corner-speed.md) | 任务 15 设计：AI 弯道限速改走物理极限 `min(策略限速, 物理上限)`，含根因分析（旧公式两头都错）。**实现 ①/②/③ 已完成**，验证口径见该文件头部 |
| [godot-racer/docs/plans/lap-autopilot-obstacle-avoidance.md](godot-racer/docs/plans/lap-autopilot-obstacle-avoidance.md) | 验收自动驾驶的障碍避让计划（进行中） |
| [godot-racer/docs/plans/p0-acceptance-contract-repair.md](godot-racer/docs/plans/p0-acceptance-contract-repair.md) | P0 验收契约修复实施计划（启动器误报、验收输出版本绑定） |
| [godot-racer/docs/push-log.md](godot-racer/docs/push-log.md) | 推送记录：每个 commit 与远端的对照 |

## 测试

项目自有代码采用 [MIT License](LICENSE)。雨声音频及外部依赖遵循各自条款，来源、
转换记录与发布注意事项见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

```powershell
cd 04-Godot启动器
pwsh -File .\run-all-checks.ps1            # 全部 20 项，最后汇总成一张表
pwsh -File .\run-all-checks.ps1 -Quick     # 只跑快的（15 项）
pwsh -File .\run-check.ps1 -Check avoid -Level 4   # 单项
```

> `main.gd` 的 `match _check:` 共实现 24 个检查项，日常套件共 20 行
> （含 `docs` / `readme` 两道文档闸门，17 个不同的游戏检查；`opponents` 分 L4/L5 两行运行）；未入套件的 7 项
> （`steerbench` / `brakebench` / `escape` / `oob` / `reset` / `resetkey` / `stuck`）
> 按需单跑，口径见 [docs/testing.md](godot-racer/docs/testing.md)。

套件的第 0/1 项是两道**"文档不许漂移"**的闸门（不启动 Godot，几毫秒跑完）：
`check-docs.ps1` 管"文档里的条数/项数 ↔ 实现里的常量"，
`check-readme.ps1` 管"文档 ↔ 项目"（路径是否存在、检查项是否有文档、项数、关卡数）。
实测它们抓到过：新增检查项没写文档、往 Quick 集加了项而文档数字过期、
`docs/testing.md` 长期停在旧断言条数。

细节与验收标准见 [docs/testing.md](godot-racer/docs/testing.md)。

> 这台机器上 Godot 4.4.1 **启动期**偶发 signal 11（空场景也会，与项目无关），
> 所以脚本都内置重试。手动跑命令时失败一次请重试。

## 已知限制

- AI 只做巡线与避让，不会主动超车或走最优线。
- 障碍是固定布局（按关卡配置 + 固定种子生成），没有随机化。
- 只有引擎占位音，没有音效与背景音乐。

## 已知缺陷（验收相关，修复前不当「已解决」）

- `opponents` / `lap` 加 `-Level 3`（荒漠遗迹）时会被静态障碍卡死——AGENTS.md §8.2 明令不得当作已解决。日常全量套件已加入 L4 的 `opponents`，缺陷仍按原判据报红。
- L5 极地 BUG-L5-001 已于 2026-10-15 修复并解除检疫：制动距离限速、近障碍低速地板和标定制动接入；三次冷启动均 1 圈、零自救，补充检查 19/19、Quick 15/15。L5 恢复原判据；完整版本绑定与边界见 [修复回执](godot-logs/l5-final-report.md)。
- 两关日志分别保存为 `godot-logs/check-opponents-L4.log` / `godot-logs/check-opponents-L5.log`，Quick 跳过两行。历史判读与当前证据见 [docs/testing.md](godot-racer/docs/testing.md)。
