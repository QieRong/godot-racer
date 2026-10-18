# REL-DIST-VERIFY：Windows 首版交付包 · 独立目录验证报告

- 验证人：路远行（release-final-verify / 游戏发布与运营管理师）
- 任务：REL-DIST-VERIFY（P1）
- 报告时间：2026-10-18 01:30 +0800
- **总判定：PASS（2 项 CONCERNS，均不阻塞交付，见 §6）**

---

## 0. 必读：本次验证证明了什么、没证明什么

> **本次验证只证明「这个交付包在一台真实 Windows 机器上、脱离开发目录与 git
> 工作树之后，能正常安装/解压/启动/游玩」。**
>
> **绝对不能**写成「干净 Windows 已验证」。本机（Windows + 已装 Godot 4.4.1 +
> 显卡驱动齐全）不是干净环境：没有验证过「无 Godot、无 VC++ 运行库、无显卡
> 驱动、全新系统」的首启表现。用户已确认暂无干净 Windows 环境，此项**未验证**。
> README Q1/Q2 里对首启风险的处理建议（黑屏看显卡驱动 / 查 godot.log）仍然是
> 玩家侧的兜底，不是我们的验证结论。

### 版本口径（先说清，避免误读）

- 被验证的二进制构建自 **提交 `0e5430f7a1f5e4adfd25f886c4297550ac48b01d`（0e5430f）**。
- 仓库当前 HEAD 是 `518b8e59712da709d6c02a4e8aacc0d13776b6ad`。
- 我独立复核了 `git diff --name-status 0e5430f..518b8e5`，结果只有两个**文档**文件：
  `M godot-racer/docs/push-log.md`、`A plan/feature-race-start-results-1.md`
  （`git diff --stat`：2 files changed, 169 insertions，全部是插入，无代码）。
- **因此：验证 `0e5430f` 的二进制 ≡ 验证当前 HEAD 的代码。** 两者在可执行行为上没有差别。
- 包内 `BUILD-INFO.txt` 自报的提交号/引擎版本与 manifest 一致（§2）。

---

## 1. 验证方法（为什么这些证据可信）

1. 把 `dist/Godot-Racer-0e5430f/` **完整复制**到 `E:\godot\dist-verify\`（脱离开发目录、
   脱离 git 工作树、脱离 `--path` 指向的工程），所有运行都在这个目录里做。
2. ZIP 另解压两份：`E:\godot\dist-verify-zip\`（Info-ZIP unzip）与
   `E:\godot\dist-verify-ps\`（Windows 自带 Expand-Archive，即资源管理器同一套解码路径）。
3. EXE 运行全部带 `--log-file <日志>` 落盘，退出码用 `$?` 逐一记录；
   全程**串行**执行（一次只起一个 Godot），刻意避开 lap / stress / opponents
   这类长时物理验收（另有一位成员在并行跑结算/音频专项，避免抢 CPU 失真）。
4. 涉及画面的项用包内自带的 `--shot` / `--shot-menu` 模式出 PNG，本报告直接看图判读。
5. **判据纪律**：没有为了让某项变绿而改判据、改阈值、跳过失败项；
   凡是只能人手操作的项，一律标「需人工确认」，没有写成自动验证通过。

---

## 2. 包完整性与 ZIP 可解压性 —— 自动验证 ✔

### 2.1 ZIP 本体

| 项 | 值 | 结果 |
|---|---|---|
| `Godot-Racer-0e5430f.zip` SHA256 | `715fde01d28d8f3323a98a64c76dfd9a6fcf345331d37638223fa01177c11040` | **与 `.zip.sha256` 逐字符一致 ✔** |
| ZIP 条目数 | 7 | 与 manifest 一致 ✔ |
| ZIP 内 UTF-8 文件名标志位 | README 条目 `flag_bits=0x0800`（bit 11 已置位） | 符合 ZIP 规范 ✔ |

### 2.2 三条路径解压/复制的逐文件 SHA256（对照 manifest）

manifest 里的 7 个哈希，在以下三份产物里**全部逐字符一致**：

| 产物 | 结果 |
|---|---|
| `E:\godot\dist-verify\`（整目录复制） | 7/7 一致 ✔ |
| `E:\godot\dist-verify-zip\`（unzip 解压） | 7/7 内容一致 ✔（见 2.3 文件名问题） |
| `E:\godot\dist-verify-ps\`（Expand-Archive 解压） | 7/7 一致 ✔ |

> **结论：「玩家拿到的压缩包」＝「我们构建的包」，逐字节成立。**

### 2.3 发现：README 文件名在老解压器下会乱码（非缺陷，建议项）

- 用 Git Bash 自带的 Info-ZIP `unzip` 解压后，`README-玩家版.txt` 的文件名变成了
  `README-þĮիÂþëê.txt`（字节级实测：期望 `e7 8e a9 e5 ae b6 e7 89 88`，实际
  `c3 be c4 ae d5 ab c3 82 c3 be c3 ab c3 aa`）。
- 根因在**解压器**不在包：ZIP 里该条目的 UTF-8 标志位（bit 11）**已正确置位**
  （python zipfile 实测 `flag_bits=0x0800`），Windows 自带解压路径（Expand-Archive，
  与资源管理器同一套解码）解出的文件名逐字节正确（证据 `rel-final-dist-verify-ps-extract.txt`）。
- **影响面**：只有文件名，文件内容 SHA256 不受影响；游戏运行与该文件无关。
  顶多让「用老解压工具的玩家」看到一个乱码文件名。
- **建议（给后续打包脚本，非本轮）**：把玩家文档改名成 ASCII（如 `README.txt`），
  一行改动就能消灭这一类「解压器差异」客诉；或保持现状并在 README 里提一句。
  本轮**未改动任何 dist 产物**。

### 2.4 附赠实测：VC++ 运行库依赖（README Q2 的开放问题可以直接关掉）

README Q2 目前写的是「**这一条待实测，先别当成结论**」。我解析了
`Godot-Racer.exe` 的 PE 导入表（证据 `rel-final-dist-verify-pe-imports.txt`）：

- PE32+（x64），共导入 22 个 DLL，全部是 Windows 系统库
  （KERNEL32 / USER32 / d3d(dxgi) / DWrite / WS2_32 / msvcrt / ntdll …）。
- **没有** `MSVCP140.dll`、`VCRUNTIME140.dll`、`VCRUNTIME140_1.dll`、`UCRTBASE.dll`、
  `CONCRT140.dll` —— 即 MSVC 运行时为**静态链接**。
- **实测结论：玩家不需要安装 Visual C++ 2015-2022 可再发行组件。**
  建议下一版打包时把 README Q2 从「待实测」改写成这条实测结论（本轮不改 dist）。

---

## 3. 逐项验证结果

图例：✔=自动验证通过（有日志/截图/退出码证据）；◐=部分自动验证；✋=需人工确认（本轮未验证）

### 3.1 五个关卡都能进入 —— ✔ 自动验证

每关跑一次 `--check=enclosure --level=N`（会真正装配场景、建赛道、发车、沿中心线
每 0.1m 打射线 2.6~4.5 万条），全部 exit=0、围墙全周无缺口：

| 关卡 | 关卡名（日志原文） | exit | 用时 | 缺口 |
|---|---|---|---|---|
| L1 | 新兵训练营（简单）椭圆 320×200 路宽 14 抓地力 ×1.00 极速 160 | 0 | 19s | 0 |
| L2 | 阳光竞速场（普通）椭圆 420×300 路宽 16 抓地力 ×1.00 极速 180 | 0 | 16s | 0 |
| L3 | 雨夜街道（困难）椭圆 300×190 路宽 12 抓地力 ×0.70 极速 200 | 0 | 25s | 0 |
| L4 | 荒漠遗迹（极难）椭圆 340×220 路宽 10 抓地力 ×0.85 极速 220 | 0 | 16s | 0 |
| L5 | 极地挑战（地狱）椭圆 230×150 路宽 8 抓地力 ×0.50 极速 240 | 0 | 14s | 0 |

每次运行都打印 `[GameState] 已加载 5 个关卡配置` —— 证明 REL-STEP2A 修的
「PCK 内关卡枚举」在**导出包里**成立（不是只在开发目录成立）。

### 3.2 中文显示正常（菜单 / HUD / 关卡名）—— ✔ 自动验证（截图判读）

打包版实机截图（PNG 在本目录，均已人工看图确认，无豆腐块、无乱码）：

- **菜单** `rel-final-dist-verify-menu-first-60fps.png`：
  「Godot 赛车」、操作提示、5 个关卡（新兵训练营/阳光竞速场/雨夜街道/荒漠遗迹/
  极地挑战 + 难度标签）、极速滑条、AI 对手开关、帧率开关、底部关卡描述，中文全部正常。
- **L1 关卡内** `rel-final-dist-verify-shot-L1.png`：HUD「本圈/上圈/最快/圈 1/2」、
  小地图图例「■检查点 ●你 ◎对手 M隐藏」，正常；起跑线上玩家车与 AI 并排发车可见。
- **L3 关卡内** `rel-final-dist-verify-shot-L3.png`：雨夜场景 + 图例含「□障碍」，正常。
- **L4 关卡内** `rel-final-dist-verify-shot-L4.png`：沙尘场景，正常。
- **L5 关卡内** `rel-final-dist-verify-shot-L5.png`：雪地场景，正常。
- L2 `rel-final-dist-verify-shot-L2.png`：正常。

每张截图对应一次 `--autostart=N --shot` 运行（exit=0），即**走的是「菜单里真实点
第 N 关按钮」这条 UI 链路**进的游戏，不是 `--level=N` 直连。菜单→关卡这条玩家主路径
在打包版里成立。

### 3.3 驾驶可操作 —— ✔ 自动验证（逐键拆开说）

| 键 | 输入动作 | 证据 | 判定 |
|---|---|---|---|
| W 油门 | `accelerate` | `--check=reverse` 端到端①：车头朝后、全油门 3.0s，**从静止加速到最高 48 km/h**；且 `--check=layout`/enclosure 等每次启动车辆物理都正常 | ✔ |
| S 刹车/倒车 | `brake_reverse` | 同上端到端②：按 S 3.0s，车辆诊断显示速度 9.56→8.90→8.48 m/s 持续衰减、四轮接地、提示按要求 0/360 帧不亮 | ✔ |
| A / D 转向 | `steer_left` / `steer_right` | `--shot --shot-steer=±60` 三连对照：不按 = `steering=0.000 rad`；按 A = `steering=+0.499 rad`（≈满舵 0.50）；按 D = `steering=-0.499 rad` —— **A/D 键确实打通到前轮转角** | ✔ |
| 空格 手刹 | `handbrake` | `--check=brakebench`：`Input.action_press("handbrake")` 注入即全轮制动，4 档初速 ×3 次重复全部实测出减速度（a_brake 12.17~12.98 m/s²，重复间零漂移），exit=0 | ✔ |

证据：`rel-final-dist-verify-{reverse,brakebench,steer-none,steer-left,steer-right}.log`
+ `.png`。

### 3.4 暂停可用 —— ✔ 自动验证

`--check=pause --level=2`（L3 雨夜街道），exit=0，日志判定行：

- `[自检] 暂停验收：ui_cancel 绑定 ESC = true`
- `✔ 再按 ESC 已恢复`
- 阶段 2（重开后的新场景）：`✔ 重开后未处于暂停`、`✔ 计圈状态已清零`、
  `✔ 暂停菜单已隐藏`
- 总判定 `暂停验收 ✔ ESC 暂停 → 选「重新开始」→ 新场景状态干净`

附带：`--check=escape`（L1）exit=0，原点复现 2880 帧内最大偏离 6.51m（护栏 8.2m），
未能穿出 —— 出界兜底在打包版里也成立。

### 3.5 结算可达 —— ✋ 需人工确认（本轮未验证，见 §5）

**本轮没有验证。** 原因与证据路径见 §5，不写成通过。

### 3.6 设置持久化 —— ◐ 部分自动验证 + 1 项需裁决

实测手段：备份并删除 `%APPDATA%\Godot\app_userdata\Godot Racer\settings.cfg`，
让打包版从零开始跑，再手写 `render_fps=120` 复跑（全程时间线在
`rel-final-dist-verify-settings-timeline.txt`，原始存档已备份并还原）。

| 子项 | 实测 | 判定 |
|---|---|---|
| 打包版能否**写** user:// | 删除 settings.cfg 后首启，文件被自动重建，内容 `[display] window_size=Vector2i(1280, 720)`（首启默认尺寸） | ✔ |
| 帧率能否**读**回 | 手写 `render_fps=120` 后重启打包版，菜单按钮显示 **120 FPS**（对比首启无存档时的 **60 FPS** 截图）；且该次启动后存档里 `render_fps=120` **没有被窗口保存覆盖**（符合「先 load 再 save、include_fps=false」的设计） | ✔ |
| 帧率「玩家在菜单里点按钮 → 重启 → 保持」 | 写路径（`set_render_fps` → `_save_display_settings(true)`）与读路径都已分别实测可用，唯一没自动化的环节是**真实点击按钮**（无运行时注入手段） | ✋ 建议人工点一下确认 |
| **极速滑条重启后保持** | **代码事实：不持久化。** `game_state.gd` 的 settings.cfg 只有 `render_fps` / `window_size` 两个键；`max_speed_kmh` 只在内存（跨关卡保留，跨进程不保留）。**README 五、Q5 明确写了「极速只在当次运行有效」** —— 实现与交付文档一致 | 见 §6 CONCERN-2 |

### 3.7 退出确认 —— ✋ 需人工确认（本轮未验证）

- ESC 暂停（含恢复/重开）已自动验证（§3.4）。
- 但「**点窗口 X / ESC 触发退出确认浮层 → 取消 → 游戏继续；→ 确认 → 进程干净退出**」
  这条链路依赖真实鼠标/键盘点击，`exit_confirm.gd` 没有对应的 `--check` 项，
  24 个验收族里也不含它。本轮**未验证**，不写成通过。
- 代码侧事实（只作参考，不当代验证）：`GameState.request_exit()` 挂在
  `root.close_requested` 上，浮层「取消，返回游戏」默认抢焦点，`ui_cancel` 也能取消。

### 3.8 附加自动验证（本轮顺手做的）

| 项 | 命令 | 结果 |
|---|---|---|
| 赛道布局/解析器全族 | `--check=layout` | exit=0，「解析用例 68 个全过 + 本关布局全部达标」 |
| 小地图 | `--check=minimap --level=3` | exit=0，障碍 8 个标记 8 个，全部在小地图图层与视野内 |

---

## 4. 最终退出码（全部 17 次运行）

全部 **exit=0**，没有任何一次被超时掐断（没有 124）。

| # | 运行 | exit | 用时 |
|---|---|---|---|
| 1 | `--check=layout` | 0 | ~20s |
| 2-6 | `--check=enclosure --level=0..4` | 0 ×5 | 19/16/25/16/14s |
| 7 | `--check=pause --level=2` | 0 | 19s |
| 8 | `--check=escape --level=0` | 0 | 45s |
| 9 | `--check=minimap --level=3` | 0 | 17s |
| 10 | `--shot-menu=40`（首启，无存档） | 0 | 27s |
| 11 | `--shot-menu=40`（存档 render_fps=120） | 0 | 34s |
| 12-16 | `--autostart=0..4 --shot ...`（五关截图） | 0 ×5 | 24/24/22/21/22s |
| 17-19 | `--shot --shot-steer=0/+60/-60` | 0 ×3 | 16/15/13s |
| 20 | `--check=reverse --level=0` | 0 | 20s |
| 21 | `--check=brakebench --level=0` | 0 | 40s |

（运行目录均为 `E:\godot\dist-verify\`；逐条原始记录见
`rel-final-dist-verify-runs-summary.txt` 与 `rel-final-dist-verify-runs2-summary.txt`。）

---

## 5. 未验证项与原因（明说，不含糊）

| 项 | 为什么没做 | 建议 |
|---|---|---|
| **结算可达（跑满目标圈数出结算页）** | 唯一自动化路径是 `--check=lap --level=0`（≈2~3 分钟纯物理）。主理人明确交代不要与并行的结算/音频专项抢 CPU（4 核机器，lap 对负载双稳态敏感），我到收尾时那位成员的 Godot 进程仍在跑（PID 14868，01:27 仍存活），所以**没有硬跑** | 等 qa-final-gate 的结算专项出结果后引用其证据闭环；或机器空闲时补跑一次 `--check=lap --level=0`（约 2 分钟）。已发消息向 qa-final-gate 协调 |
| 退出确认浮层的确认/取消 | 依赖真实鼠标点击，无自动化入口 | 人工点一次：游戏中点窗口 X → 「取消」应回到游戏、「确认退出」应退出 |
| 帧率「点按钮 → 重启 → 保持」 | 同上（写/读两条路径已分别实测可用） | 人工点一下 120 FPS → 重启 |
| 手刹/转向/刹车的**手感** | 自动验证只证明「输入通路 + 物理响应」成立，不证明手感好坏 | 人工试驾（本来就不该由自动验收下结论） |
| **干净 Windows 环境** | 本机不是干净环境，用户确认暂无干净机器 | 见 §0。**报告与任何对外话术都不得写「干净 Windows 已验证」** |

---

## 6. 是否阻塞交付

**结论：不阻塞。**

- **CONCERN-1（结算未实机验证）**：这是「未验证」，不是「失败」。核心闭环的实机
  证据目前由 qa-final-gate 的并行专项负责；在他们的结算证据落地之前，**首版交付
  报告里「结算可达」这一项必须保留「待确认」字样，不得写通过**。若 qa-final-gate
  的结算专项失败，则升级为 Blocker。
- **CONCERN-2（极速滑条不持久化 vs 本次验收清单措辞）**：代码事实 + 玩家 README
  都明确「极速只在当次运行有效」，这是**交付规格内的既定行为，不是缺陷**。但本次
  任务的验收清单写的是「极速滑条改了以后重启仍保持」，两者矛盾。**需要主理人裁决
  二选一**：(a) 按交付规格，把验收清单这条改成「极速仅当次运行有效（README 已写明）」
  —— 我的推荐，因为它与已出货的 README 一致；(b) 改产品，把 `max_speed_kmh`
  加进 settings.cfg 并同步 README —— 那就是新的开发任务 + 重新打包 + 重新验证，
  不该塞进本轮验证。
- **建议项（非阻塞）**：① README 文件名改 ASCII，消灭老解压器乱码（§2.3）；
  ② README Q2 按本报告 §2.4 的实测结论改写「不需要装 VC++ 运行库」；
  ③ README 六·已知限制里「60/120 FPS 双档验收仍在进行」这句现在已过时
  （全量 20 项验收已 PASS），下一版文档同步时一并改掉。这三条都涉及改 dist 产物，
  本轮一律没动，留给打包/文档侧。

---

## 7. 证据清单（全部在 `godot-logs/`，前缀 `rel-final-dist-verify-`，共 60 份）

- 汇总：`runs-summary.txt`（阶段1）、`runs2-summary.txt`（阶段2）、
  `settings-timeline.txt`（设置持久化时间线）
- 判定日志：`layout` / `enclosure-L1..L5` / `pause-L3` / `escape-L1` / `minimap-L4` /
  `reverse` / `brakebench`（各配 `.stdout`）
- 截图：`menu-first-60fps.png`、`menu-fps120.png`、`shot-L1..L5.png`、
  `steer-none/left/right.png`
- 专项证据：`pe-imports.txt`（PE 导入表）、`ps-extract.txt`（Windows 解压路径文件名字节）、
  `settings-backup.cfg`（玩家原存档，已还原）
- 复现脚本：`runs.sh`、`runs2.sh`

### 复现命令（任何人可重跑）

```text
# 1) 独立目录
cp -r dist/Godot-Racer-0e5430f E:/godot/dist-verify
# 2) 跑（在 E:/godot/dist-verify 下）
./Godot-Racer.exe --log-file <log> -- --check=enclosure --level=0
./Godot-Racer.exe --log-file <log> -- --shot --shot-frames=150 --shot-hold=90 --shot-out=<png>
# 3) 哈希
certutil -hashfile Godot-Racer-0e5430f.zip SHA256     # 对比 .zip.sha256
```

---

## 8. 一句话结论

交付包在**本机独立目录**里：哈希全对、ZIP 规范正确、5 关全进、中文全对、
油门/刹车/转向/手刹四条输入通路实测可用、暂停可用、帧率持久化读写两条路径可用、
21 次运行零非零退出码。**唯一没拿到实机证据的是结算页（因 CPU 协调主动不跑），
干净 Windows 环境依旧未验证。** 判定 PASS（附 2 项 CONCERNS），不阻塞交付。
