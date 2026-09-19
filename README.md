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

**怎么玩**：双击 `04-Godot启动器/运行游戏.bat`

**操作**：`W` 油门 · `S` 刹车/倒车 · `A` `D` 转向 · `空格` 手刹 · `R` 复位 · `V` 切换视角 · `M` 隐藏/显示小地图 · `鼠标右键拖动` 环视

| 内容 | 说明 |
|---|---|
| 赛道 | 1635 m 椭圆环道，曲率连续（直线+圆弧的接点会把车弹飞，所以用椭圆） |
| 护栏 | 视觉高 1.8 m + **隐形空气墙 12 m**（车翻不出去、飞不出去），全周**逐 0.1 m 射线验证无缺口** |
| 车辆 | `VehicleBody3D` + 4 个 `VehicleWheel3D`，后驱、前轮转向 |
| 视角 | `V` 循环切换：第一人称（车头）/ 第二人称（车尾后 2.8 m）/ 第三人称（车尾后 5.2 m），切换时左上角提示 1.8 秒 |
| 车轮 | 模型里的 `Tire_*/Rim_*/Hub_*` 手动驱动自转与前轮转向（`VehicleWheel3D` 只有物理、没有视觉） |
| 限速 | 100 km/h（按赛道弯道半径反推：μ=1.0、r=150 m → 上限约 138 km/h，取保守值） |
| 计时 | 4 个检查点 + 顺序校验，防止抄近道刷圈速 |
| HUD | 车速 + 本圈 / 上圈 / 最快圈 + **右上角实时小地图**（赛道轮廓 + 起终点 + 检查点 + 车点） |
| 脱困 | 翻车**原地扶正**（保留位置与朝向）；真正"想动却动不了"超过 4 秒才回到赛道 |
| 出界兜底 | 离中心线超出通道就自动拉回赛道；**速度越快阈值越低**（≥8 m/s 时余量收到 0.3 m、零延迟） |
| R 键保护 | 离中心线 < 3 m 且未翻车时，`R` **只扶正、不传送**；否则按中心线切线复位 |
| 复位无敌 | 复位后 2 s 内不与其它车辆碰撞、不触发检查点，避免刚回赛道就被顶飞/刷圈 |

**文件**：
- `scenes/main.tscn` 主场景（赛道 + 车 + 相机 + HUD + 小地图）
- `scenes/track.tscn` 赛道生成器入口
- `scenes/race_car.tscn` 车辆（含四个轮的参数）
- `scripts/track_generator.gd` 用一条 Curve3D 生成路面/碰撞/护栏/检查点；对外提供 `nearest_on_centerline` 等查询
- `scripts/vehicle.gd` 车辆控制（含起跑位计算、限速、脱困、出界兜底、中心线复位）
- `scripts/chase_camera.gd` 第三人称跟随相机
- `scripts/checkpoint.gd` / `scripts/hud.gd` 计时与 UI
- `scripts/minimap.gd` 右上角小地图（从中心线现搭地图内容，分层渲染）
- `scripts/level_config.gd` + `data/levels/*.tres` **关卡数据驱动**：加关卡只丢一个 .tres
- `scripts/game_state.gd` autoload：在"主菜单 ↔ 关卡"之间传关卡选择与玩家调的极速
- `scripts/menu.gd` / `scripts/pause_menu.gd` 主菜单与 ESC 暂停菜单（UI 代码构建）
- `scripts/ai_test_driver.gd` 本地确定性压测器（固定种子可复现）
- `scripts/openrouter_client.gd` OpenRouter 预留接口（默认关闭，缺 key 自动降级）
- `scripts/orientation_check.gd` 启动自检（朝向、起跑位、车轮数）
- `scripts/physics_monitor.gd` 诊断用监控（可用命令行参数驱动自动化测试）
- `models/race_car.glb` 从 `02-Blender建模` 导出的模型
- `shot_game.gd` 截图工具（让 Godot 渲染一帧存 PNG，用于验证画面）

**验收自检（改完代码先跑这个）**：

```powershell
# 在 04-Godot启动器 目录下
pwsh -File .\run-check.ps1 -Check enclosure   # 围墙全周封闭：32704 条射线，缺口必须为 0
pwsh -File .\run-check.ps1 -Check escape      # 原点复现：起点满舵满油冲 12 秒，不许穿墙
pwsh -File .\run-check.ps1 -Check wallslide   # 12 组怼墙，要求都能继续开（不卡死）
pwsh -File .\run-check.ps1 -Check stress      # 本地确定性鲁莽驾驶压测：卡死事件必须为 0
pwsh -File .\run-check.ps1 -Check lap         # 自动驾驶跑多圈：计时正常、无意外重置
pwsh -File .\run-check.ps1 -Check reset       # 8 个赛道外方位按 R，必须 8/8 回到路面
pwsh -File .\run-check.ps1 -Check oob         # 界外静置必须被自动拉回
pwsh -File .\run-check.ps1 -Check resetkey    # R 键保护 + 复位无敌帧
pwsh -File .\run-check.ps1 -Check minimap     # 小地图搭起来了、车点在跟随

# 多关卡：任何自检都能指定关卡（0~4）
pwsh -File .\run-check.ps1 -Check enclosure   # 默认关卡 0
#   godot --path godot-racer -- --level=4 --check=enclosure
```

**AI 测试接入（可选，默认关闭且不联网）**

`scripts/openrouter_client.gd` 是预留接口，`scripts/ai_test_driver.gd` 是**本地确定性**
压测器（固定种子可复现）。AI 只做两件事：生成极端用例参数、归因失败日志；
**不用它逐帧开车** —— 免费额度下延迟几秒，车早就撞墙了，而且每次结果都不同、测不出回归。

启用方式（三选一，密钥**都不入库**）：

```powershell
# ① 环境变量（推荐）
$env:OPENROUTER_API_KEY = "sk-or-v1-..."
$env:OPENROUTER_PROXY   = "http://127.0.0.1:7897"   # 可选：只给该模块挂代理
# ② 复制 godot-racer\openrouter.cfg.example 为 openrouter.local.cfg 填值（已 gitignore）
# ③ 导出后放 user://openrouter.cfg
```

**为什么要"智能分流"**：`OPENROUTER_PROXY` 只作用于这一个 `HTTPRequest`，
游戏其它部分与本地工具（含 DSH 的 `127.0.0.1` 回环）都不走代理。
所以**不需要**开系统代理或 TUN；开全局代理反而会把正常请求也带进去，梯子一断全断。

没有 key 或连不通时，`available=false`，压测自动退回本地随机（固定种子），
日志会打印 `[OpenRouter] 状态：未配置（将使用本地确定性测试）`，不会报错、不会卡住。

当前实测结果（全部通过）：

| 检查项 | 结果 |
|---|---|
| `enclosure` | 32704 条射线，缺口 **0**（含起终点缝） |
| `escape` | 起点满舵满油 12 秒，最大偏离 6.46 m < 8.2 m，**没穿出去** |
| `wallslide` | 12/12 通过；对照组（去掉低摩擦墙材质）只有 4/12、8 处卡死在 0.5 km/h |
| `stress` | 3000 帧鲁莽驾驶，卡死事件 **0**，最大偏离 7.4 m |
| `reset` | 8 个方位 **8/8** 落回中心线 |
| `oob` | 界外静置 2.0 s 被自动拉回 |
| `resetkey` | 近距 R 只扶正（位移 0.30 m）；界外 R 回赛道；无敌帧 2.8 s 后自动解除 |
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
     `godot --path <工程> -- --check=<enclosure|reset|oob|resetkey|minimap>`
     （在 `main.gd` 里实现，写完日志自动退出；外层 `04-Godot启动器/run-check.ps1` 带重试）
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
| `运行游戏.bat` | **双击玩**。带 `--log-file`，规避 Godot 启动期因无法写 `user://` 而崩溃 |
| `打开Godot编辑器.bat` | 进编辑器改场景/调参 |
| `诊断Godot启动.bat` | 启动不了时跑，依次试 4 种配置并报告哪种可行 |
| `install_godot.ps1` | 重装 Godot 用（当前装在 `E:\godot`，4.4.1） |

**为什么启动器要带 `--log-file`**：Godot 在无法创建 `user://` 目录时会走异常分支并空指针崩溃
（`0x60 内存不能为 read`），把日志重定向到可写位置即可绕开。

**为什么用 `.bat` 而不是 `.lnk`**：`.lnk` 里存的是绝对路径，文件夹一改名/移动就失效；
`.bat` 用 `%~dp0`（自身所在目录）定位，整条命令没有写死路径，所以整个 `data-analysis`
文件夹随便改名、剪切、换盘都不会坏。

**`.bat` 必须是 CRLF 换行（踩过的坑，双击没反应先查这个）**：`cmd` 按 CRLF 切行，只有 LF
会把多行黏成一条命令，报 `'xxx' 不是内部或外部命令` 和 `文件名、目录名或卷标语法不正确`，
窗口一闪而过。实测：LF 版 `exit=1`，**只把换行改成 CRLF 就 `exit=0`**。
仓库里 `.gitattributes` 锁了 `*.bat text eol=crlf`，但那只管「检出时」的换行——
**用工具/脚本直接写文件时仍要自己写 CRLF**，否则本地这份又会被写坏。

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
