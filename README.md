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

**操作**：`W` 油门 · `S` 刹车/倒车 · `A` `D` 转向 · `空格` 手刹 · `R` 复位 · `V` 切换视角 · `鼠标右键拖动` 环视

| 内容 | 说明 |
|---|---|
| 赛道 | 1635 m 椭圆环道，曲率连续（直线+圆弧的接点会把车弹飞，所以用椭圆） |
| 护栏 | 视觉高 1.8 m + **隐形空气墙 12 m**（车翻不出去、飞不出去） |
| 车辆 | `VehicleBody3D` + 4 个 `VehicleWheel3D`，后驱、前轮转向 |
| 视角 | `V` 循环切换：第一人称（车头）/ 第二人称（车尾后 2.8 m）/ 第三人称（车尾后 5.2 m），切换时左上角提示 1.8 秒 |
| 车轮 | 模型里的 `Tire_*/Rim_*/Hub_*` 手动驱动自转与前轮转向（`VehicleWheel3D` 只有物理、没有视觉） |
| 限速 | 100 km/h（按赛道弯道半径反推：μ=1.0、r=150 m → 上限约 138 km/h，取保守值） |
| 计时 | 4 个检查点 + 顺序校验，防止抄近道刷圈速 |
| HUD | 车速 + 本圈 / 上圈 / 最快圈 |
| 脱困 | 翻车**原地扶正**（保留位置与朝向）；真正"想动却动不了"超过 4 秒才退回最近检查点 |

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
6. **自动化校验与截图的正确姿势**（这条踩了很久，写清楚）：
   - `godot --path <工程> --script xxx.gd` **必崩**（signal 11，连"只 print 然后 quit"的
     空脚本都崩）；而 `godot --script <绝对路径>`（**不带** `--path`）是正常的。
     所以崩溃来自 **`--path` 与 `--script` 的组合**，不是脚本内容，也不是 Godot 装坏了
   - 只做加载校验用 `godot --headless --path <工程> --quit`：跑一遍主场景再退出，实测 exit 0，
     能读到赛道生成 / 车辆出生点 / 起跑自检的全部日志
   - 要**截图**不能用 `--headless`（空渲染器，截出来是空图）。走主场景里的 `main.gd --shot` 钩子：
     `godot --path <工程> -- --shot --shot-frames=150 --shot-hold=120 --shot-out=<绝对路径>`
   - **窗口化运行必须用 `start` 分离启动**（和 `04-Godot启动器/运行游戏.bat` 一样）：
     从受限 shell 里直接前台启动渲染同样会段错误，分离出去就正常
   - 别用 `| Select-Object -First N` 截 Godot 的输出：PowerShell 截断后会提前把 Godot 杀掉，
     日志只剩前几行，看起来像"启动失败"，其实是抓日志的方式错了
7. **车头在车体本地 `-Z`**。这一点代码注释里前后说反过四次（`chase_camera.gd` 说 +Z、
   `orientation_check.gd` 说 +X、`vehicle.gd` 一处说 X 负一处说 -Z），是"镜头朝向和车头
   不一致"的根源。三条独立证据：
   `race_car.tscn` 的 `WheelFront*` 在 z=**-1.05**、`WheelRear*` 在 z=+1.05；
   `race_car.glb` 里 `Nose_Wing` 在模型 x=**-1.66**、`Wing_Main` 在 x=+1.68；
   `CarModel` 的 90° 旋转把模型 -X 映射到车体 -Z。
   推论：摄像机必须在车体 **+Z** 侧；按检查点复位时朝向要 **+PI**（检查点门是本地 +Z 朝前）
8. **质心必须手动压低**。`race_car.tscn` 不设质心时 Godot 按碰撞盒 AUTO 算出约 y=0.55，
   而轮距只有 ±0.68，侧倾力矩一超过轮距就翻（按住 A/D 几秒必翻）。
   `vehicle.gd` 的 `center_of_mass_height`（默认 0.2）在 `_ready` 里以
   `CENTER_OF_MASS_MODE_CUSTOM` 应用

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
