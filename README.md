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

**操作**：`W` 油门 · `S` 刹车/倒车 · `A` `D` 转向 · `空格` 手刹 · `R` 复位 · `鼠标右键拖动` 环视

| 内容 | 说明 |
|---|---|
| 赛道 | 1635 m 椭圆环道，曲率连续（直线+圆弧的接点会把车弹飞，所以用椭圆） |
| 护栏 | 视觉高 1.8 m + **隐形空气墙 12 m**（车翻不出去、飞不出去） |
| 车辆 | `VehicleBody3D` + 4 个 `VehicleWheel3D`，后驱、前轮转向 |
| 限速 | 100 km/h（按赛道弯道半径反推：μ=1.0、r=150 m → 上限约 138 km/h，取保守值） |
| 计时 | 4 个检查点 + 顺序校验，防止抄近道刷圈速 |
| HUD | 车速 + 本圈 / 上圈 / 最快圈 |
| 脱困 | 翻车或"想动却动不了"时自动回位到最近检查点 |

**文件**：
- `scenes/main.tscn` 主场景（赛道 + 车 + 相机 + HUD）
- `scenes/track.tscn` 赛道生成器入口
- `scenes/race_car.tscn` 车辆（含四个轮的参数）
- `scripts/track_generator.gd` 用一条 Curve3D 生成路面/碰撞/护栏/检查点
- `scripts/vehicle.gd` 车辆控制（含起跑位计算、限速、脱困）
- `scripts/chase_camera.gd` 第三人称跟随相机
- `scripts/checkpoint.gd` / `scripts/hud.gd` 计时与 UI
- `scripts/orientation_check.gd` 启动自检（朝向、起跑位、车轮数）
- `scripts/physics_monitor.gd` 诊断用监控（可用命令行参数驱动自动化测试）
- `models/race_car.glb` 从 `02-Blender建模` 导出的模型
- `shot_game.gd` 截图工具（让 Godot 渲染一帧存 PNG，用于验证画面）

**已知的坑（改代码前务必看这个）**：
1. **`Transform3D(...)` 前 9 个参数是按行给基向量**，按列填 = 填了转置矩阵
2. **`VehicleWheel3D.position` 是"悬挂塔顶"不是轮心**，静止时高度 = `轮半径 + rest_length`
3. **前进用的是负 `engine_force`**（与直觉相反，实测得出）
4. **场景里给导出节点变量赋值必须在 `[node]` 行写 `node_paths=PackedStringArray("xxx")`**，否则是 null
5. 改赛道形状后，车的出生点会**自动重算**（读白线位置/厚度），不用手填
6. **`godot --headless --script xxx.gd` 会直接段错误**（signal 11，输出里连引擎横幅都没有；
   `extends SceneTree` 和 `extends MainLoop` 两种写法都崩，与脚本内容无关）。要做自动化校验
   请改用 `godot --headless --path <工程目录> --quit`——它照常跑一遍主场景再退出，实测 exit 0，
   而且能读到赛道生成、车辆出生点、起跑自检的全部日志

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

---

## 环境事实（重装/换机时需要）

| 项 | 位置 / 值 |
|---|---|
| Godot | `E:\godot\Godot_v4.4.1-stable_win64.exe`（4.4.1 stable） |
| Blender | `E:\blender\blender.exe`（4.3.2） |
| Python | `E:\PyCharm\Python\python.exe`（3.12，PIL + scipy + numpy） |
| Godot 命令行 | `--headless --path <工程> --quit` 正常（exit 0）；**`--headless --script` 必崩**，见「已知的坑」第 6 条 |
| 本机网络 | **shell 完全无法联网**（TLS 凭证错误），只有 harness 的 web_fetch 能出网 |
