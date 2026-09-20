# 测试与验收

本项目有一整套可自动化的验收检查，全部通过游戏主场景的 `--check=` 通道运行
（原因见文末"为什么不直接用 `--script`"）。

## 怎么跑

```powershell
cd 04-Godot启动器

pwsh -File .\run-all-checks.ps1            # 全部 15 项，最后汇总成一张表
pwsh -File .\run-all-checks.ps1 -Quick     # 跳过 lap/stress/opponents 等耗时项
pwsh -File .\run-all-checks.ps1 -Only avoid,pause
pwsh -File .\run-check.ps1 -Check <名称>   # 跑单项
```

启动器菜单里的「4/5/6」是同样的东西。每项的完整日志在 `godot-logs/check-<名称>.log`。

`-Level` 是**0 起**（不传就用默认关卡）；`-NoAi` 用于做"只差对手"的物理 A/B。

## 检查项

| 名称 | 验收标准 |
|---|---|
| `readme` | README 与 `docs/` 里提到的路径/检查项与项目实际一致（不启动 Godot） |
| `enclosure` | 沿中心线每 0.1 m 两侧各一条射线，**缺口必须为 0** |
| `wallslide` | 5°/10°/20° 内外两侧怼墙，**12/12 不卡死** |
| `stress` | 3000 帧鲁莽驾驶，**卡死为 0**，并跑完落盘的极端用例 |
| `lap` | 自动驾驶连续多圈，计时正常、**复位 0** |
| `minimap` | 标记数量/图层/是否在相机视野内（含障碍标记硬校验） |
| `opponents` | AI 能独立跑完 ≥1 圈、**零自救**、未出界 |
| `aistart` | 玩家不动则对手不动；玩家一动**同步发动** |
| `aidiag` | 走**真实游玩路径**采样 AI：不得抢跑、发车后不得有 >1.5s 的 <5km/h 停顿、自救必须 0 |
| `obstacles` | 障碍在路面内 / 射线命中 / 通行缝隙 ≥ 车宽+0.5 m / **静态障碍合并为 1 个物理节点** |
| `avoid` | 把玩家当路障摆在 AI 车道：**全程不接触**、真的横向绕开、能绕过去 |
| `pause` | ESC 暂停 → 四个选项 → 再按恢复 → 「重新开始」后新场景状态干净 |
| `flip` | 翻车恢复：**真实底朝天** ≤2s 扶正且四轮接地；**合成腹部贴地**（四轮全不接地+车身水平+还在动）≤2s 触发恢复，且夹具关闭后落回四轮接地 |
| `weather` | 粒子该有则有、该无则无，且**对比度 ≥ 0.25** |
| `friction` | 抓地力倍率**单调**影响侧向加速度 |
| `phys` | 实际物理步频稳在 120 Hz（用**实测步频**判定，不用逐帧耗时读数） |
| `openrouter` / `models` | 连通性探针 / 查询当前真实可用的免费模型（需梯子） |
| `reset` `oob` `resetkey` `escape` `stuck` | 历史检查：复位 8 方位、出界兜底、R 键保护+无敌帧、起点穿墙复现、卡墙诊断 |

## 最近一次完整结果

| 检查项 | 结果 |
|---|---|
| `enclosure` | 缺口 **0**（含起终点缝）；赛道下静态物理节点 3 个 |
| `wallslide` | **12/12**（结束速度 51~66 km/h）；对照组去掉低摩擦墙材质只有 4/12 |
| `stress` | 3000 帧卡死 **0**，最大偏离 7.4 m；极端用例 10/10 兜底通过 |
| `lap` | 连续多圈计时正常、复位 **0** |
| `minimap` | 障碍 8 个 → 标记 8 个，全在 MAP_LAYER、全在相机视野内 |
| `opponents` | AI 独立跑完 ≥1 圈、**零自救**（含 6 静态 + 2 动态障碍） |
| `aistart` | 静止时对手 0.07 km/h 原地等待；玩家起步后 **0.19 s** 同步发动 |
| `obstacles` | 位置/射线命中/通行缝隙 ≥2.25 m/**合并为 1 个物理节点** 全通过 |
| `avoid` | 最小中心距 2.85 m（净距 +1.10 m）、横向绕行 3.06 m、**不接触** |
| `pause` | 重开后圈数 0、上圈 0.000、车在出生点 |
| `weather` | 对比度 雪 0.53 / 雨 0.73（判据 ≥0.25）；帧率 120 Hz |
| `friction` | 侧向加速度 36.4 → 11.2 m/s²（降 69%），**单调** |
| `phys` | **120.1 Hz**（1 台对手 + 6 静态 + 2 动态障碍全开） |
| `flip` | 用例 A 真实底朝天 0.51 s 扶正；用例 B 合成腹部贴地：状态持续 1.52 s → 触发恢复 1.52 s → 夹具关闭后 2.08 s 落回四轮接地 ✔ |
| 5 个关卡 | 关卡 1~5 全部 **0 缺口** |

## `run-check.ps1` 的两道闸门

都是踩坑之后加的：

1. **启动 Godot 之前**跑 `lint-gdscript.ps1`（中文串里的 ASCII 直引号、`.bat` 的 CRLF）
   与 **`parse-check.ps1`**（真·跑 Godot 解析器，能抓"类型推断"这类错误）。
   `main.gd` 一旦解析失败，症状是"赛道不生成、车一直往下掉、每个关卡都这样"——
   看起来像游戏坏了，其实是一行代码写错。`parse-check` 的用法：

   ```powershell
   pwsh -File .\parse-check.ps1              # 检查入口脚本（main.gd / menu.gd）
   pwsh -File .\parse-check.ps1 -Scripts res://scenes/main.gd
   ```

   > 为什么不用 lint 一把梭：`lint-gdscript.ps1` 是逐字符扫源码，只能发现引号类问题；
   > **类型推断错误**（对未标注类型的 `Node` 取属性、用 `:=` 接收 `Variant`）
   > 只有让 Godot 自己解析才知道。而这类错误在本项目已经犯过三次。
   > `parse-check` 会过滤 `--check-only` 的已知假阳性（autoload 在那种模式下未注册）。

2. **跑完后**扫日志里的 `Parse Error` / `Failed to load script` 并显式失败。
   因为 `main.gd` 挂掉时日志里**照样有大量正常的 `[自检]` 输出**（来自其它脚本），
   只看那些会以为一切正常。

另外每项检查有**自己合理的最短超时**（`lap` 内部允许跑 6 分钟）。
曾经只给 260 秒，它在第 2 圈就被杀掉，日志只剩 1 圈圈速，
于是"上圈 == 最快"被误判成圈速异常——看起来像代码回归，其实是脚本把进程掐了。

## 为什么不直接用 `--script`

- `godot --path <工程> --script xxx.gd` **必崩**（signal 11，连只 print 然后 quit 的
  空脚本都崩）；而 `--script <绝对路径>`（不带 `--path`）是正常的。
  所以崩溃来自 **`--path` 与 `--script` 的组合**。
- `--headless` 在 4.4.1 里不是有效参数，传了会被忽略并**直接去跑主场景**。
- `--script` 方式本身也不稳，而且启动期偶发段错误。

所以验收一律走主场景自检：`godot --path <工程> -- --check=<名称>`
（在 `main.gd` 里实现，写完日志自动退出；外层 `run-check.ps1` 带重试）。

截图不能用 headless（空渲染器，截出来是空图），走 `main.gd --shot` 钩子：

```powershell
pwsh -File .\shoot.ps1 -Level 4 -Frames 430 -Hold 430 -Out ..\screenshots\shot.png
```

> **注意**：这台机器上 Godot 4.4.1 **启动期**偶发 signal 11（空场景也会），
> 与项目代码无关。所有脚本都内置重试；如果手动跑命令，失败一次请重试。

## 测试用例生成器

`tools/test_generator.py` 在**开发期**生成极端驾驶用例，落盘成 `data/ai_test_cases.json`。
压测**优先读这个文件**（不联网、可复现、能进版本库），现问 LLM 只作补充。

```powershell
cd godot-racer
python tools\test_generator.py --offline --level 4      # 由赛道几何算，不需要梯子
python tools\test_generator.py --count 12 --level 4     # 联网生成，需要梯子
```

密钥只从环境变量 `OPENROUTER_API_KEY` 或 `openrouter.local.cfg` 读，**不入库**，
日志里只打印前 6 位 + `***`。
