---
name: racer-dev
description: Godot 赛车游戏开发代理，专精物理引擎、AI 对手与自动化测试
---

## 📋 项目概述

这是一个基于 **Godot 4.4.1** 的 3D 赛车游戏，包含 5 个递进难度的关卡。
核心模块：赛道生成（`track_generator.gd`）、车辆物理（`vehicle.gd`）、
AI 对手（`ai_opponent.gd`）、HUD（`hud.gd`）、AI 测试（OpenRouter 集成）。

**技术栈**：GDScript / Godot 4.4.1 / 物理帧 120Hz
**测试工具**：`run-check.ps1` + 自定义 `--check=` 参数通道

---

## ⚡ 核心命令

| 命令                   | 用途                                      | 何时运行                |
| ---------------------- | ----------------------------------------- | ----------------------- |
| `--check=enclosure`    | 围墙封闭性验证（每 0.1m 射线，100% 命中） | 修改赛道几何后          |
| `--check=wallslide`    | 卡墙测试（5°/10°/20° 怼墙，全油门 3 秒）  | 修改墙面摩擦/物理材质后 |
| `--check=stress`       | 3000 帧鲁棒驾驶，卡死事件必须为 0         | 每次提交前              |
| `--check=lap`          | 自动驾驶完整跑圈                          | 修改 AI 或赛道参数后    |
| `--check=elevation`    | 起伏、地形带、接缝、UV 密度验证           | 修改高度剖面或地形后    |
| `--check=elevation-ai` | AI 上坡保持率、冰面刹车距离、物理帧同步   | 合并前（约 90 秒）      |
| `--check=assets`       | 贴图存在、导入、配对、未染色、同 TILE     | 修改关卡贴图配置后      |
| `--check=layout`       | 路段 DSL、剖面解析、限速/刹车距离用例     | 修改赛道布局后          |

---

## 🚦 三层边界

### ✅ Always do（无需确认）
- 修改核心逻辑后按顺序跑 `enclosure → wallslide → stress → lap`
- 提交前运行 `git status`，确认 `openrouter.local.cfg` 未被追踪
- 每次提交附带对应的测试运行日志摘要
- 排查 Bug 使用射线探针、打印物理状态等“硬数据”，禁止靠读代码猜
- **测“车的位置/姿态”必须补截图**：日志里的坐标是数字，看不出车在不在路面上。
  “掉头后倒着开”“卡在护栏内侧”“贴着墙推头”“复位落点错误”这几类问题
  **只有一张图能一眼定案** —— 数字断言 + 一张图，两个都要。
  截图走主场景钩子（不能 headless）：
  ```powershell
  pwsh -File 04-Godot启动器/shoot.ps1 -Level 0 -Drive -Frames 400 -Out ..\shots\drive.png
  ```
  `-Drive` 让自动驾驶把车真开起来；不加 `-Drive` 只能“停着”或“按住 W 直冲”。
  ⚠ 现在截图会**顺带打印**“离中心线多少 / 车头与赛道夹角”，图和数一起看才作数。

### ⚠️ Ask first（必须先问）
- 修改 `AGENTS.md` 本身
- 新增验收命令或修改现有检查的判据
- 删除任何已通过的测试用例
- 修改 `LevelConfig` 契约或 `.tres` 数据结构
- 改变 `racing_line.gd` 的限速/刹车距离公式

### ❌ Never do（绝对禁止）
- **API 密钥零泄露**：绝不允许在代码、注释、日志输出中明文打印完整的 `sk-or-v1-` 密钥。必须通过 `OPENROUTER_API_KEY` 环境变量或 `openrouter.local.cfg` 读取。禁止硬编码。
- **版本控制防卫**：一旦发现 `openrouter.local.cfg` 有被提交的风险，立刻停止提交并向我报警。
- **代理隔离**：Clash Verge 的代理（`http://127.0.0.1:7892`）**仅允许**用于 AI 测试模块。严格禁止开启系统代理或 TUN 模式，防止本地服务（如 DSH）因梯子断线而不可用。
- **硬编码关卡参数**：严禁在代码中硬编码半径、路宽、圈数、高度剖面等。
- **AI 物理作弊**：严禁直接修改 `linear_velocity` 扣除重力分量。必须用引擎力补偿（≤1.35× 上限）。
- **运行时 AI 生图**：Agnes 素材仅限开发期生成并打包，禁止运行时实时调用。
- **无限等待**：任何 `HTTPRequest` 或 `await` 必须有截止时间，绝不允许永久挂住主循环。

---

## 📐 代码示例

### ✅ 正确：关卡参数走 LevelConfig

```gdscript
@export var elevation_profile := ""     ## 高度剖面 DSL（空 = 平地）
@export var grade_limit := 0.09         ## 坡度硬上限
@export var min_corner_radius := 15.0   ## 最小弯道半径
