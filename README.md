# DSH-Work / data-analysis 目录说明

这个目录是「赛车项目」的工作区，按用途分成 4 个文件夹。整理日期：见各文件修改时间。

```
data-analysis/
├── godot-racer/            ← 【主交付物】Godot 4 赛车游戏工程
├── 01-参考/                ← 调研资料
├── 02-Blender建模/          ← 3D 模型源文件与导出脚本
├── 03-2D赛车图/             ← 最早的 2D 上色图
└── 04-Godot启动器/          ← 双击即用的启动入口
```

---

## godot-racer/ —— Godot 4 赛车游戏（主交付物）

**怎么玩**：双击 `04-Godot启动器/启动器.bat`（或 ASCII 同名入口 `launcher.bat`）→ 进菜单选「运行游戏」。
菜单里还能跑验收、生成测试用例、看日志、做启动诊断。

**操作**：`W` 油门 · `S` 刹车/倒车 · `A` `D` 转向 · `空格` 手刹 · `R` 复位 · `V` 切换视角 · `M` 隐藏/显示小地图 · `ESC` 暂停（继续 / 重新开始 / 返回选关 / 退出） · `鼠标右键拖动` 环视

| 内容 | 说明 |
|---|---|
| 关卡 | **5 个关卡，数据驱动**（`data/levels/*.tres`）。难度递进：新兵训练营 → 阳光竞速场 → 雨夜街道 → 荒漠遗迹 → 极地挑战 |
| 赛道 | 椭圆 + S 弯扰动，曲率连续（直线+圆弧的接点会把车弹飞）。曲线长 1307~1782 m，路宽 8~16 m |
| 护栏 | 视觉高 1.8 m + **隐形空气墙 12 m**（车翻不出去、飞不出去），全周**逐 0.1 m 射线验证无缺口** |
| 车辆 | `VehicleBody3D` + 4 个 `VehicleWheel3D`，后驱、前轮转向；质心自定义到 0.20 m（AUTO≈0.55 会侧翻） |
| 视角 | `V` 循环切换：第一人称（车头）/ 第二人称（车尾后 2.8 m）/ 第三人称（车尾后 5.2 m） |
| 车轮 | 模型里的 `Tire_*/Rim_*/Hub_*` 手动驱动自转与前轮转向（`VehicleWheel3D` 只有物理、没有视觉） |
| 极速 | **玩家可在主菜单用滑条调 80~240 km/h**（默认用关卡建议值 160~240） |
| AI 对手 | 每关 **1 台**，与玩家**并排发车**（横向 2.40 m，推导见 `docs/ai-opponent-design.md`）。**玩家一动它才动**；会**主动绕开玩家**，也会避让障碍 |
| 天气 | 晴 / 雨 / 雪 / 沙尘：环境色调 + 雾 + 粒子，并**真实改变抓地力**（抓地力倍率 1.0~0.5，实测侧向加速度单调下降 69%） |
| 障碍 | 静态障碍**合并为单个物理节点**（性能红线）+ 动态滑动路障；任何时刻保留 ≥ 车宽+0.5 m 通行缝隙 |
| 计时 | 4~5 个检查点 + 顺序校验，防止抄近道刷圈速；圈数按关卡配置（2~3 圈） |
| HUD | 车速 + 本圈 / 上圈 / 最快圈 + **右上角实时小地图** |
| 小地图 | 赛道轮廓 + 起终点 + 检查点（青实心方块）+ 玩家（橙圆盘）+ **对手（黄绿空心圆环）** + **障碍（红空心方块）**，带图例；`M` 可隐藏 |
| 脱困 | 翻车**原地扶正**（保留位置与朝向）；真正"想动却动不了"超过 4 秒才回到赛道 |
| 出界兜底 | 离中心线超出通道就自动拉回赛道（阈值与速度无关，避免"贴墙高速被误判出界"死循环） |
| R 键保护 | 离中心线 < 3 m 且未翻车时，`R` **只扶正、不传送**；否则按中心线切线复位 |
| 复位无敌 | 复位后 2 s 内不与其它车辆碰撞、不触发检查点，避免刚回赛道就被顶飞/刷圈 |
| 素材 | 5 套关卡地面贴图 + 路面贴图，由 **Agnes 在开发期生成**并打包进 `assets/textures/`（**禁止运行时生图**） |

**文件**（目录约定见 `godot-racer/AGENTS.md`）：
- `scenes/main.tscn` 主场景（赛道 + 玩家 + 相机 + HUD + 小地图 + 暂停菜单）
- `scenes/menu.tscn` 主菜单（关卡列表 + 极速滑条 + **AI 对手开关**）
- `scenes/track.tscn` 赛道生成器入口
- `scenes/race_car.tscn` 车辆（含四个轮的参数；AI 车也复用它，只换控制器脚本）
- `scripts/track_generator.gd` 用一条 Curve3D 生成路面/碰撞/护栏/检查点；对外提供 `nearest_on_centerline` 等查询
- `scripts/vehicle.gd` 玩家车辆控制（起跑位计算、限速、脱困、出界兜底、中心线复位）
- `scripts/ai_opponent.gd` **AI 对手**：纯追踪巡线 + 车道保持 + 主动避让玩家/障碍
- `scripts/obstacle_field.gd` **障碍物场**：静态障碍合并单节点 + 动态滑动路障（固定种子可复现）
- `scripts/chase_camera.gd` 第三人称跟随相机
- `scripts/checkpoint.gd` / `scripts/hud.gd` 计时与 UI
- `scripts/minimap.gd` 右上角小地图（从中心线现搭地图内容，分层渲染）
- `scripts/level_config.gd` + `data/levels/*.tres` **关卡数据驱动**：加关卡只丢一个 .tres
- `scripts/game_state.gd` autoload：在"主菜单 ↔ 关卡"之间传关卡选择、极速、AI 开关
- `scripts/menu.gd` / `scripts/pause_menu.gd` 主菜单与 ESC 暂停菜单（UI 代码构建）
- `scripts/ai_test_driver.gd` 本地确定性压测器（固定种子可复现）
- `scripts/openrouter_client.gd` OpenRouter 客户端（**已接通**；缺 key / 429 自动降级，绝不卡住）
- `tools/test_generator.py` **开发期**用例生成器（联网 / `--offline` 两模式），产出 `data/ai_test_cases.json`
- `tools/shot_game_diagnostic.gd` 截图诊断（让 Godot 渲染一帧存 PNG）
- `docs/ai-opponent-design.md` AI 对手设计规范（并排距离、车道、发车时机、已知取舍）
- `assets/textures/` 开发期 Agnes 生成的地面/路面贴图
- `models/race_car.glb` 从 `02-Blender建模` 导出的模型
- `scripts/orientation_check.gd` 启动自检（朝向、起跑位、车轮数）
- `scripts/physics_monitor.gd` 诊断用监控（可用命令行参数驱动自动化测试）

**验收自检（改完代码先跑这个）**：

```powershell
# 方式一：启动器菜单 → 4) 跑全部验收 / 5) 只跑快的 / 6) 跑单项（会列出全部检查项）
# 方式二：直接调
pwsh -File .\run-all-checks.ps1            # 全部 13 项，最后汇总成一张表
pwsh -File .\run-all-checks.ps1 -Quick     # 跳过 lap/stress/opponents 等耗时项
pwsh -File .\run-all-checks.ps1 -Only avoid,pause
```

单项（`-Level` 是 **0 起**，不传就用默认关卡）：

| 检查 | 验收标准 |
|---|---|
| `enclosure` | 沿中心线每 0.1 m 两侧各一条射线，**缺口必须为 0** |
| `wallslide` | 5°/10°/20° 内外两侧怼墙，**12/12 不卡死** |
| `stress` | 3000 帧鲁莽驾驶，**卡死为 0**，并跑完落盘的极端用例 |
| `lap` | 自动驾驶连续多圈，计时正常、**复位 0** |
| `minimap` | 标记数量/图层/是否在相机视野内（含障碍标记硬校验） |
| `opponents` | AI 能独立跑完 ≥1 圈、**零自救**、未出界 |
| `aistart` | 玩家不动则对手不动；玩家一动**同步发动** |
| `obstacles` | 障碍在路面内 / 射线命中 / 通行缝隙 ≥ 车宽+0.5 m / **静态障碍合并为 1 个物理节点** |
| `avoid` | 把玩家当路障摆在 AI 车道：**全程不接触**、真的横向绕开、能绕过去 |
| `pause` | ESC 暂停 → 四个选项 → 再按恢复 → 「重新开始」后新场景状态干净 |
| `weather` | 粒子该有则有、该无则无，且**对比度 ≥ 0.25** |
| `friction` | 抓地力倍率**单调**影响侧向加速度（实测降 69%） |
| `phys` | 实际物理步频稳在 120 Hz（用**实测步频**判定，不用逐帧耗时读数） |
| `openrouter` / `models` | 连通性探针 / 查询当前真实可用的免费模型（需梯子） |

```powershell
pwsh -File .\run-check.ps1 -Check opponents -Level 4   # 指定关卡（0 起）
pwsh -File .\run-check.ps1 -Check phys -Level 4 -NoAi  # 只差对手的干净 A/B
pwsh -File .\run-check.ps1 -Check lap -TimeoutSec 500  # 每项检查有自己合理的最短超时
```

> **`run-check.ps1` 自带两道闸门**（都是踩坑后加的）：
> ① 启动 Godot **之前**跑 `lint-gdscript.ps1`——中文串里的 ASCII 直引号会让整个脚本
> 解析失败，症状是"赛道不生成、车自由落体、每个关卡都这样"，看起来像游戏坏了；
> ② 跑完后扫日志里的 `Parse Error`/`Failed to load script` 并显式失败——
> 因为 `main.gd` 挂掉时日志里**照样有大量正常的 `[自检]` 输出**，只看那些会以为一切正常。

**AI 测试接入（已接通；断网/无 key 会自动降级，绝不影响游戏）**

分两层，职责刻意分开：

1. **用例来自开发期落盘的文件**（主路径）：`tools/test_generator.py` 在开发期生成极端用例，
   写入 `data/ai_test_cases.json` 并入库。Godot 的压测**优先读这个文件**——
   不联网、可复现、别人 clone 下来能跑出同样的结果。
2. **现问 LLM** 只在文件缺失时作为补充。AI 只做两件事：生成极端用例参数、归因失败日志。
   **不让它逐帧开车**——免费额度下延迟几秒，车早就撞墙了，而且每次结果都不同、测不出回归。

```powershell
# 生成用例（不需要梯子：由赛道几何算出确定性用例集）
cd godot-racer
python tools\test_generator.py --offline --level 4

# 生成用例（需要梯子；密钥只读环境变量或 openrouter.local.cfg，日志只打前 6 位+***）
python tools\test_generator.py --count 12 --level 4
```

密钥来源（三选一，**都不入库**）：

```powershell
# ① 环境变量（推荐）
$env:OPENROUTER_API_KEY = "sk-or-v1-..."
$env:OPENROUTER_PROXY   = "http://127.0.0.1:7892"   # 可选：只给该模块挂代理
$env:OPENROUTER_TIMEOUT = "45"                      # 可选：秒
# ② 复制 godot-racer\openrouter.cfg.example 为 openrouter.local.cfg 填值（已 gitignore）
# ③ 导出后放 user://openrouter.cfg
```

**实际状态（2026-09 实测）**：走本地代理时 Godot 侧返回 `HTTP 200 / PONG`，延迟约 7~8 秒；
模型目录里 22 个免费模型，探活前 5 个全部可用（最快 1.5 s → 用作备用模型）。

**测试用例生成器**的相关约定：
- 超时**默认 45 秒且可配置**（免费档首字延迟 3~15 s，1 秒会 100% 假超时）；
  生成长 JSON 时内部放宽到 90 秒。关键约束是"必须有截止时间、到点必须放弃"。
- 429/401/402 → 立刻降级为本地确定性测试，只打印原因、不重试、不阻塞。
- 模型名**不靠记忆写死**：跑 `--check=models` 探活实测后再填。
  （教训：`meta-llama/llama-3.1-8b-instruct:free` 已下架返回 404，
  一个消失的备用模型等于没有备用。）
- 输出被 `max_tokens` 截断时，按大括号配对**抢救**出完整对象，而不是整批丢弃。

**接通步骤（先分层定位，别一上来就跑游戏）**：

```powershell
# 第 1 步：独立探针（不依赖 Godot）。会分 4 层报告：读配置 → DNS → 代理端口 → 真实请求
pwsh -File .\test-openrouter.ps1
pwsh -File .\test-openrouter.ps1 -NoProxy     # 直连对比，用来判断是不是代理的问题

# 第 2 步：Godot 侧同一个代理与配置再测一遍（走游戏里的 HTTPRequest）
pwsh -File .\run-check.ps1 -Check openrouter
pwsh -File .\run-check.ps1 -Check models      # 顺便查当前真实可用的免费模型

# 第 3 步：跑压测，确认它真的用上了用例文件
pwsh -File .\run-check.ps1 -Check stress      # 日志里会打印"已从 data/ai_test_cases.json 读取 N 组"
```

探针会把失败原因分到具体一层，例如：
`RESULT_CANT_CONNECT`（代理没起/端口错）、`RESULT_CANT_RESOLVE`（代理没做远端解析）、
`401`（key 无效）、`404`（模型名不对，`:free` 后缀要带上）、`429`（限流/额度用尽）。

> ⚠ **不要拿 curl 的结论判断 Godot 能不能联网**：Godot 的 `HTTPRequest` 用自带 mbedTLS，
> **不走 Windows schannel**。实测命令行 `curl` 报 `SEC_E_NO_CREDENTIALS` 时 Godot 照样能通。

**为什么要"智能分流"**：`OPENROUTER_PROXY` 只作用于这一个 `HTTPRequest`，
游戏其它部分与本地工具（含 DSH 的 `127.0.0.1` 回环）都不走代理。
所以**不需要**开系统代理或 TUN；开全局代理反而会把正常请求也带进去，梯子一断全断。

没有 key 或连不通时，`available=false`，压测自动退回本地随机（固定种子），
日志会打印降级原因，不会报错、不会卡住。

当前实测结果（13 项全绿；数字取自最近一次完整回归）：

| 检查项 | 结果 |
|---|---|
| `enclosure` | 逐 0.1 m 两侧各一条射线，缺口 **0**（含起终点缝）；赛道下静态物理节点 3 个 |
| `wallslide` | **12/12** 通过（结束速度 51~66 km/h）；对照组去掉低摩擦墙材质只有 4/12、8 处卡死在 0.5 km/h |
| `stress` | 3000 帧鲁莽驾驶，卡死事件 **0**，最大偏离 7.4 m；极端用例 10/10 兜底通过 |
| `lap` | 连续多圈计时正常、复位 **0** |
| `minimap` | 障碍 8 个 → 标记 8 个，全在 MAP_LAYER、全在相机视野内 |
| `opponents` | AI 独立跑完 ≥1 圈、**零自救**（该关卡含 6 静态 + 2 动态障碍） |
| `aistart` | 玩家静止时对手 0.07 km/h 原地等待；玩家起步后 **0.19 s** 同步发动；两车中心距 2.40 m |
| `obstacles` | 位置/射线命中/通行缝隙 ≥2.25 m/**静态障碍合并为 1 个物理节点** 全通过 |
| `avoid` | 把玩家当路障摆在 AI 车道：最小中心距 2.85 m（净距 +1.10 m）、横向绕行 3.06 m、**不接触** |
| `pause` | ESC 暂停 → 四个选项 → 再按恢复 → 「重新开始」后圈数 0、上圈 0.000、车在出生点 |
| `weather` | 粒子该有则有；对比度 雪 0.53 / 雨 0.73（判据 ≥0.25）；帧率 120 Hz |
| `friction` | 抓地力倍率**单调**影响侧向加速度：36.4 → 11.2 m/s²（降 69%） |
| `phys` | 实际物理步频 **120.1 Hz**（1 台对手 + 6 静态 + 2 动态障碍全开） |
| 5 个关卡 | 关卡 1~5 全部 **0 缺口**（含 S 弯关卡：S 弯幅度超短半轴 25% 会被自动夹紧并告警） |

脚本内置重试：这台机器上 Godot 4.4.1 **启动期**偶发 signal 11（空场景也会），
重试几次即可；这点和项目代码无关。

**已知的坑（改代码前务必看这个）**：
1. **`Transform3D(...)` 前 9 个参数是按行给基向量**，按列填 = 填了转置矩阵
2. **`VehicleWheel3D.position` 是"悬挂塔顶"不是轮心**，静止时高度 = `轮半径 + rest_length`
3. **前进用的是负 `engine_force`**（与直觉相反，实测得出）
4. **场景里给导出节点变量赋值必须在 `[node]` 行写 `node_paths=PackedStringArray("xxx")`**，否则是 null
5. 改赛道形状后，车的出生点会**自动重算**（读白线位置/厚度），不用手填
6. **自动化校验与截图的正确姿势**（这条踩了很久，写清楚）：
   - `godot --path <工程> --script xxx.gd` **必崩**（signal 11，连"只 print 然后 quit"的
     空脚本都崩）；而 `godot --script <绝对路径>`（**不带** `--path`）是正常的。
     所以崩溃来自 **`--path` 与 `--script` 的组合**，不是脚本内容，也不是 Godot 装坏了
   - **`--headless` 在 4.4.1 里不是有效参数**，传了会被忽略并**直接去跑主场景**
     （以前这里写的"用 `--headless --path --quit` 做加载校验"是错的：它其实跑了整局游戏）。
     正确写法是 `--display-driver headless`，或者干脆走下面的 `--check=` 自检通道
   - **`--script` 方式本身也不稳**：即使不带 `--path`，也会落到主场景，
     而且启动期偶发段错误。所以本工程的验收一律走主场景自检：
     `godot --path <工程> -- --check=<检查名>`
     （在 `main.gd` 里实现，写完日志自动退出；外层 `04-Godot启动器/run-check.ps1` 带重试）
     现有检查名（用 `pwsh -File .\launcher-menu.ps1 -Action list` 或启动器菜单 6 可看全）：
     `enclosure` `wallslide` `stress` `lap` `minimap` `opponents` `aistart` `obstacles`
     `avoid` `pause` `weather` `friction` `phys` `openrouter` `models`
     以及历史检查 `reset` `oob` `resetkey` `escape` `stuck`
   - 要**截图**不能用 headless（空渲染器，截出来是空图）。走主场景里的 `main.gd --shot` 钩子：
     `godot --path <工程> -- --shot --shot-frames=150 --shot-hold=120 --shot-out=<绝对路径>`
   - **窗口化运行必须用 `start` 分离启动**（和 `04-Godot启动器/运行游戏.bat` 一样）：
     从受限 shell 里直接前台启动渲染同样会段错误，分离出去就正常
   - 别用 `| Select-Object -First N` 截 Godot 的输出：PowerShell 截断后会提前把 Godot 杀掉，
     日志只剩前几行，看起来像"启动失败"，其实是抓日志的方式错了
7. **`Curve3D.sample_baked(d)` 的 `d` 不是真实弧长**（这条是"起点旁边没封住"的真正根因）。
   实测本赛道：`d=1631.11` 与绕回的 `d=1635.12` 之间参数差 4.01 m，
   而两个采样点的**实际距离是 23.63 m** —— 缝附近参数被严重压缩。
   所以"按 `d = i * step_len` 均匀步进"会在闭合缝处留下一个真实缺口。
   正确做法：从当前点出发逐渐加大 `d`，直到**实际位移**接近目标段长才落点（见 `_build_guardrails`）
8. **椭圆上弦长 ≠ 弧长**：护栏墙**不能**沿起点切线拉一条直弦。
   弯道外侧每段会短一截，实测每 ~21 m 就漏一个 0.1~0.8 m 的口子（射线探针 119 条打空）。
   正确做法：在**每个环点**上直接算墙的位置，相邻环点的墙点连线成条带 ——
   相邻段天然共用一条边，数学上不可能有缝
9. **小地图别给 SubViewport 单独开 World3D**：`own_world_3d` 在运行时拿到的 `world_3d`
   是空的；手动 `vp.world_3d = World3D.new()` 虽能生效，但渲染器会报
   `Parameter "scenario" is null`，主视角直接花掉（天空变橙、车看不见、屏幕一大块黑）。
   本工程改用**共用主世界 + cull_mask 分层**：小地图元素全放第 17 层，
   小地图相机只渲染该层、主相机剔掉该层
10. **改地面层要小心**：把 `Ground` 的 `collision_layer` 挪到别的层，车会**直接掉进虚空**
    （四个轮子全部 `接地=false`）—— 车/射线的 mask 只查第 1 层。
    要让小地图里没有草地，只挪**视觉层**（`MeshInstance3D.layers`），碰撞层保持第 1 层
11. **车头在车体本地 `-Z`**。这一点代码注释里前后说反过四次（`chase_camera.gd` 说 +Z、
    `orientation_check.gd` 说 +X、`vehicle.gd` 一处说 X 负一处说 -Z），是"镜头朝向和车头
    不一致"的根源。三条独立证据：
    `race_car.tscn` 的 `WheelFront*` 在 z=**-1.05**、`WheelRear*` 在 z=+1.05；
    `race_car.glb` 里 `Nose_Wing` 在模型 x=**-1.66**、`Wing_Main` 在 x=+1.68；
    `CarModel` 的 90° 旋转把模型 -X 映射到车体 -Z。
    推论：摄像机必须在车体 **+Z** 侧；按检查点复位时朝向要 **+PI**（检查点门是本地 +Z 朝前）
12. **物理帧率是 120 Hz**（`project.godot` 的 `physics_ticks_per_second`）。
    自检里"等 N 个 `physics_frame`"是 `N/120` 秒 —— 我第一版按 60 算，等少了，
    把正常的无敌帧误判成"没恢复"
13. **`var x := load(...).new()` 会直接解析错误**：`load()` 返回 Variant，
    GDScript 推断不出类型 → **整个脚本加载失败**。症状极具误导性：
    关卡参数不生效、赛道不生成、车一路掉到 y=-27000、天空变棕。
    正确写法：`var s: GDScript = load(...)` 再 `s.new()`（实测踩过）
14. **`HTTPRequest.set_http_proxy()` 在 4.4 只接受 2 个参数**（host、port）。
    多传第三个（用户名）也是解析错误，而且会**连坐**所有依赖它的脚本编译失败
15. **赛道是"延迟构建"的，别按 ready 顺序猜**：`Track` 是 `track.tscn` 的实例场景，
    它的 `_ready()` 一定早于 `main.gd` 的 `_ready()`（Godot 按节点顺序触发，跟脚本优先级无关）。
    所以关卡参数由 `main.gd` set 后**显式** `call_deferred("build_world")` 驱动；
    车辆/小地图/自检都必须 `await track.await_world_ready()` 再用赛道数据，
    否则会出现"车放在世界原点""检查点连不上""起跑自检误报越线 54m"
16. **`--check=` 那套自检依赖主场景是"关卡"**：主场景改成菜单后，菜单里必须识别
    `--check=` / `--level=` 并 `call_deferred` 跳过菜单，否则所有验收全部失效
17. **质心必须手动压低**。`race_car.tscn` 不设质心时 Godot 按碰撞盒 AUTO 算出约 y=0.55，
    而轮距只有 ±0.68，侧倾力矩一超过轮距就翻（按住 A/D 几秒必翻）。
    `vehicle.gd` 的 `center_of_mass_height`（默认 0.2）在 `_ready` 里以
    `CENTER_OF_MASS_MODE_CUSTOM` 应用；再加上 `_roll_guard_factor()` 的侧倾收转向

---

## 01-参考/

`GitHub赛车项目调研报告.md` —— 6 个开源 Godot 赛车项目的核验与源码级发现。

关键结论：`adrianm/Starter-Kit-Racing` **不存在**（404），真身是 `KenneyNL/Starter-Kit-Racing`；
6 个仓库里**只有 2 个**真用 `VehicleBody3D`，其余是自定义 Raycast 车辆。

---

## 02-Blender建模/

| 文件 | 说明 |
|---|---|
| `build_racecar_3d.py` | Blender 脚本：按参考线稿几何生成 3D 赛车 |
| `racecar-3d.blend` | Blender 工程（37 个对象，轮子/悬挂独立命名） |
| `export_glb.py` | 导出给 Godot 的 glb（删地面、保轮子独立、Y-up） |
| `racecar-3d-render.png` | 渲染预览图 |

**重新生成**：
```
& 'E:\blender\blender.exe' --background --factory-startup --python build_racecar_3d.py
```

---

## 03-2D赛车图/

最早那一步的产物：按参考线稿重建的 2D 上色图（黑轮廓 + 红车身 + 黑轮胎）。

| 文件 | 说明 |
|---|---|
| `draw_racecar.py` | 生成脚本。几何直接从参考图**程序化提取**（连通域分割 + 半径直方图定轮心） |
| `racecar-colored.png` | 成品 335×444 |

---

## 04-Godot启动器/

| 文件 | 用途 |
|---|---|
| `launcher.bat` | **正式入口**（ASCII 文件名 + ASCII 内容）。双击进菜单 |
| `启动器.bat` | 同上，中文名孪生入口，只转调 `launcher.bat` |
| `launcher-menu.ps1` | **中文菜单**：游玩 / 跑全部验收 / 跑单项（列出 15 项检查）/ lint / 生成用例（离线·联网）/ 启动诊断 / 打开日志 / 清理临时日志。支持 `-Action` 做非交互调用，所以可自动化测试 |
| `运行游戏.bat` | 直接开游戏（不进菜单）。带 lint 闸门 + 启动期段错误自动重试 |
| `打开Godot编辑器.bat` | 进编辑器改场景/调参 |
| `诊断Godot启动.bat` | 启动不了时跑，依次试 3 种配置并报告哪种可行 |
| `run-check.ps1` | 跑单项验收。自带 lint preflight 与解析失败闸门；每项检查有自己合理的最短超时 |
| `run-all-checks.ps1` | 按顺序跑完全部验收并汇总成一张表（`-Quick` / `-Only x,y`） |
| `lint-gdscript.ps1` | 静态检查：① 中文串里的 ASCII 直引号 ② `.bat` 行尾必须是 CRLF |
| `shoot.ps1` | 抓游戏实机截图（带启动期重试） |
| `test-openrouter.ps1` | OpenRouter 独立探针（分层报告：配置 → DNS → 代理端口 → 真实请求） |
| `install_godot.ps1` | 重装 Godot 用（当前装在 `E:\godot`，4.4.1） |

**为什么启动器要带 `--log-file`**：Godot 在无法创建 `user://` 目录时会走异常分支并空指针崩溃
（`0x60 内存不能为 read`），把日志重定向到可写位置即可绕开。

**为什么用 `.bat` 而不是 `.lnk`**：`.lnk` 里存的是绝对路径，文件夹一改名/移动就失效；
`.bat` 用 `%~dp0`（自身所在目录）定位，整条命令没有写死路径，所以整个 `data-analysis`
文件夹随便改名、剪切、换盘都不会坏。

**为什么菜单在 PowerShell 而不是 `.bat`（三个编码坑，都踩过）**：

1. **`.bat` 内容必须是纯 ASCII**：`cmd` 按**控制台代码页**解析 `.bat`，而这台机器的代码页
   不保证是 UTF-8。中文字节被误解析时会吞掉后面的 ASCII，把 `echo` 变成 `ho`、
   把 `if` 断掉，整个脚本散架。→ 所有 `.bat` 的非 ASCII 字节数现在是 **0**，
   中文界面全部放在 `launcher-menu.ps1` 里。
2. **用 ASCII 编码写 `.bat` 时，里面的中文文件名会被静默替换成 `?????`**
   （实测 `启动器.bat` 5 个、诊断脚本 8 个）→ 所以脚本引用一律用 ASCII 文件名
   （`launcher.bat` / `launcher-menu.ps1` / `run-all-checks.ps1`）。
3. **`.bat` 必须是 CRLF 换行**：`cmd` 按 CRLF 切行，只有 LF 会把多行黏成一条命令，
   双击就是"窗口一闪而过"。仓库里 `.gitattributes` 锁了 `*.bat text eol=crlf`，
   但那只管**检出时**的换行——用工具/脚本直接写文件时仍要自己写 CRLF。
   → 这条已经写成 `lint-gdscript.ps1` 的第二类检查，机器拦，不靠人记。

**为什么给 `.ps1` 加 UTF-8 BOM**：Windows PowerShell 5.1 按 ANSI/GBK 读 `.ps1`，
没有 BOM 时中文全乱码、括号引号齐断。所以含中文的 `.ps1` 都带 **单一** UTF-8 BOM
（注意别写双 BOM：读文件时 `UTF8.GetString` 会把 BOM 保留成 `U+FEFF` 字符，
再写入时又加一个，于是 `\uFEFF#` 不再是注释行，报"'#' 不会被识别为 cmdlet"）。
`.bat` 里优先用 `pwsh`（PowerShell 7，原生 UTF-8），没有才退回 `powershell`。

---

## 环境事实（重装/换机时需要）

| 项 | 位置 / 值 |
|---|---|
| Godot | `E:\godot\Godot_v4.4.1-stable_win64.exe`（4.4.1 stable） |
| Blender | `E:\blender\blender.exe`（4.3.2） |
| Python | `E:\PyCharm\Python\python.exe`（3.12，PIL + scipy + numpy） |
| Godot 命令行 | `--headless --path <工程> --quit` 正常（exit 0）；**`--headless --script` 必崩**，见「已知的坑」第 6 条 |
| 本机网络 | **不是"完全断网"**，但被 Steam++ 拦了一层，见下面三行 |
| Steam++ 中间人 | Watt Toolkit（装在 `D:\watt`）在 `127.0.0.1:443` / `:80` 做本地反向代理；`hosts` 里 27 条 github 域名 + 18 条 steam 域名都被指向 `127.0.0.1`；根证书库里有 5 张 `SteamTools Certificate`（其中 4 张已过期） |
| git 走 HTTPS | **必须**信任 Steam++ 的根证书，否则报 `unable to get local issuer certificate (20)`。已设全局 `http.sslCAInfo = C:\Users\Administrator\.git-ca-bundle.crt`（= Git 自带 CA 包 + 5 张 SteamTools 证书）。**Steam++ 换证书后要重新合并** |
| TLS 后端 | **只能用 openssl**。本机 Windows 的 schannel 是坏的（`AcquireCredentialsHandle failed: SEC_E_NO_CREDENTIALS`），curl 与 Godot 读根证书库失败都是这个病根 |
| harness web_fetch | `github.com` 等被 hosts 指到 `127.0.0.1`，会被判成「非公网地址」而拒绝 |
