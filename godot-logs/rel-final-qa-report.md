# REL-QA-GATE · Windows 首版最终 QA 门控报告（B / C 阶段）

> 作者：严守真（quality-lead） · Task ID: REL-QA-GATE
> 引擎：Godot 4.4.1 stable · 工程根：`godot-racer` · HEAD：518b8e5
> 阶段状态：A 已 PASS（见 `rel-final-full20-20261018-001316.log`）· **B 已 PASS** · **C 已 PASS** · D 未做（本轮按指令跳过）

---

## 0. 先回答 team-lead 点名要判的那一条：资源泄漏告警

### 现象
`rel-final-finish-green2.log` 末尾出现过一次：
```
WARNING: ObjectDB instances leaked at exit (run with --verbose for details).
   at: cleanup (core/object/object.cpp:2378)
ERROR: 2 resources still in use at exit (run with --verbose for details).
   at: clear (core/io/resource.cpp:614)
```

### 判定：**测试脚本自己的收尾问题，不是产品缺陷。不阻塞交付。**

三条独立证据：

**① 不可复现 → 追它本身追不出结论**
同一份代码 + 同一份脚本，跑 5 次只出现 1 次：

| 日志 | 告警 |
|---|---|
| rel-final-finish-green.log | 无 |
| rel-final-finish-green2.log | **有** |
| rel-final-finish-red-B5.log | 无 |
| rel-final-leak-verbose.log（带 `--verbose`） | 无（想抓细节，结果它没出现） |
| rel-final-leak-probe.log | 无 |

**② 逐轮量：根本没有"一轮一轮累积"这回事**
这才是真正该回答的问题（玩家反复「完成 → 返回选关 → 再玩一局」会不会越跑越占）。
我写了 `tests/rel_final_leak_probe_test.gd`，跑 5 个完整循环，每轮量四个计数器：

```
[LEAK] baseline  nodes=   2 orphan=  0 resources=  11 objects= 1438
[LEAK] cycle1    nodes=   2 orphan=  0 resources=  311 objects= 1820
[LEAK] cycle2    nodes=   2 orphan=  0 resources=  312 objects= 1822
[LEAK] cycle3    nodes=   2 orphan=  0 resources=  312 objects= 1822
[LEAK] cycle4    nodes=   2 orphan=  0 resources=  312 objects= 1822
[LEAK] cycle5    nodes=   2 orphan=  0 resources=  312 objects= 1822
[LEAK] 第1轮 → 第5 轮增量：resources=+1 nodes=+0 orphan=+0 objects=+2
```

第 1 轮的 +300 是关卡资源首次 load（一次性）；**第 2 轮起完全持平**（312/312/312/312）。
节点数每轮结束都回到 2，**孤儿节点恒为 0** —— 残弹窗、残播放器都无处可藏。
→ 不累积，就不存在"玩家反复重开会越跑越占内存"的缺陷。

**③ 定位并修掉测试侧收尾后，告警 3/3 消失**
根因：`_free_scene()` 原来只等到"弹窗计数归零"就返回（通常 1 帧），而 `queue_free` 是**帧末**才真正摘除 —— 场景还在"待删"状态脚本就 `quit()` 了，引擎把它算成退出期泄漏。
改成显式等 `is_instance_valid(victim) == false`（对象真的销毁）+ 退出前空转 10 帧后：

| 日志 | 用例 | 告警 |
|---|---|---|
| rel-final-leak-fix1.log | 67/67 PASS | 无 |
| rel-final-leak-fix2.log | 67/67 PASS | 无 |
| rel-final-leak-fix3.log | 67/67 PASS | 无 |

⚠ **必须写进交付报告的一条**：这条告警出现在 `rel-final-finish-green2.log` 里，是**已修的测试脚本问题**的历史记录，不是产品遗留项。产品代码在本轮结束后 `git diff --name-only` 为空，未做任何改动。

---

## 1. B 阶段 · 结算与退出专项：**PASS**

### 1.1 覆盖与结果
`godot-racer/tests/rel_final_finish_flow_test.gd`（B1–B6，**67 条断言**）+ `tests/rel_final_mode_guard_test.gd`（B7，真实带 `--check=` / `--shot` 起进程）。

| 组 | 用例 | 条数 | 结果 |
|---|---|---|---|
| B1 | 重复完成信号只触发一次结算（含"圈数不足不许结算"负对照） | 7 | 全过 |
| B2 | 完成瞬间仍按住 5 个驾驶键 → FINISHED 后全部释放 | 5 | 全过 |
| B3 | 三个出口（再玩一局 / 退出游戏 / 返回选关）各自状态正确 | 17 | 全过 |
| B4 | 结算态 ESC → 返回选关，而不是恢复比赛 | 5 | 全过 |
| B5 | 退出取消回到进入前的精确状态（含"结算态取消不能恢复比赛"） | 17 | 全过 |
| B6 | 重开：清弹窗 / 清输入 / 解暂停 / 成绩重初始化，**设置保留** | 16 | 全过 |
| B7 | `--check` / `--shot` 不连交互结算、绕过退出确认 | 见下 | 全过 |

**B7 用"进程是否被 quit()"当判据**：日志文件里出现 `B7_<MODE>_EXIT_CALLED=1` 而**不出现** `B7_<MODE>_STILL_ALIVE=1`，即证明 `request_exit()` 直接退出了、没有弹交互确认框。
- `rel-final-finish-b7-check.log`：`MODE_ACTIVE_CHECK=1 / FINISH_UNWIRED=1 / SIGNAL_INERT=1 / PRECHECK_FAIL=0 / EXIT_CALLED=1`，STILL_ALIVE **0 命中**
- `rel-final-finish-b7-shot.log`：`MODE_ACTIVE_SHOT=1 / FINISH_UNWIRED=1 / SIGNAL_INERT=1 / PRECHECK_FAIL=0 / EXIT_CALLED=1`，STILL_ALIVE **0 命中**
- 还原后复跑：`-b7-check2` / `-b7-shot2` 同样全绿

**"暂停专项仍走真实暂停逻辑"没有被绕过去**：`--check=pause` 走的是 `PauseMenu._unhandled_input → GameState.pause_race()`（真实 ESC 按键 + 真实按钮回调），证据在 A 阶段的 `rel-final-full20-20261018-001316-pause.log`（`暂停验收 ✔`）。B7 只要求自动模式**不接交互结算**、**绕过退出确认**，暂停那条链路原样保留。

### 1.2 注入缺陷清单（"证明测试不是空转"的方法说明）

做法：临时改 `scripts/game_state.gd` / `scripts/environment.gd` → 跑 → 必须变红 → 从备份还原 → 必须变绿。
备份放在仓库外（`%TEMP%\relfinal-backup\`），每次还原后用 SHA256 + `git diff --name-only` 双重校验；**最终 `git diff` 为空，产品代码零改动**。

**红灯轮 1 · `rel-final-finish-red-B1B2B4.log`（67 中 13 条失败）**

| 注入的缺陷 | 触发的红灯 |
|---|---|
| `finish_race` 去掉 `phase != Phase.RACING` 守卫 | `B1-4 重复完成信号不叠加结算面板（实际 2）`、`B1-5 第二次 finish_race 返回 false`、`B1-6 重复信号未改写成绩快照（last=1.00，应 42.5）` |
| `finish_race` 去掉 `release_drive_input()` | `B2-3 进入 FINISHED 后全部驾驶输入已释放（仍按住：["accelerate","brake_reverse","steer_left","steer_right","handbrake"]）`、`B2-4 6 帧后仍保持释放` |
| `back_to_menu()` 变空操作 | `B4-2 结算态按 ESC → MENU（实际 FINISHED）`、`B4-3/4/5`、`B3-3b/3c/3d/3e` |

**红灯轮 2 · `rel-final-finish-red-B3B6.log`（67 中 6 条失败）**

| 注入的缺陷 | 触发的红灯 |
|---|---|
| `restart_race` 不再 `reload_current_scene()` | `B3-1f 再玩一局 → 圈数归零（实际 2）`、`B3-1g 结算面板已清理（实际 1）`、`B6-2e 重开 → 成绩重新初始化（圈数=3 上圈=40.000）`、`B6-2h` |
| `restart_race` 顺手重置 `max_speed_kmh` | `B6-3b 重开后极速设置保留（实际 180.0，应 200.0）` |
| `begin_race` 不清退出确认弹窗 | `B6-2i 重开 → 退出确认面板已清理（实际 1）` |

**红灯轮 3 · `rel-final-finish-red-B5.log`（67 中 5 条失败）**

| 注入的缺陷 | 触发的红灯 |
|---|---|
| `cancel_exit` 一律退回 `RACING` 并解除暂停 | `B5-2d 结算态取消后仍是 FINISHED（实际 RACING）`、`B5-2e 树仍然暂停`、`B5-2i`、`B5-3b`、`B3-2e` |

**红灯轮 4 · `rel-final-finish-red-B7.log`**

| 注入的缺陷 | 触发的红灯 |
|---|---|
| `request_exit` 去掉命令行绕过分支 | `B7_CHECK_STILL_ALIVE=1` + `REL_FINAL_MODE_GUARD_FAIL`（进程没被 quit，会被交互弹窗卡住） |

**还原后绿灯**：`rel-final-finish-green2.log`（67/67 PASS）、`rel-final-leak-fix1/2/3.log`（各 67/67 PASS）。

### 1.3 本轮我自己发现并修掉的两个**测试侧**缺陷（不是产品缺陷，但要披露）
1. `_expect()` / 部分 `_check()` 的标签写成了"失败原因"，通过时也会打印出来，日志出现 `PASS MODE_ACTIVE 命令行缺少 --check=...` 这种**看着像红灯实际是绿灯**的行。已改成通过只打 tag、失败才带原因。
2. `--script` 跑 SceneTree 时 `GameState` 不是编译期标识符（实测 `Compile Error: Identifier not found: GameState`），已全部改为 `root.get_node_or_null("GameState")` + `call/get/set`（与 `release_settings_test.gd` 既有写法一致）。

---

## 2. C 阶段 · 音频专项：**PASS（机器可验部分）**

### 2.1 机器验证结果 · `rel-final-audio-green3.log`：**37/37 PASS**

| 项 | 判据 | 实测 |
|---|---|---|
| C1 总线 | SFX / BGM / Ambient 挂 Master 下，初始 0 dB | `idx=1/2/3 send=Master volume_db=0.00`，Master 是 0 号 ✔ |
| C2 循环 + 长度 | `rain_loop.ogg` 导入后 `loop == true`，长度约 204.55 s | `loop=true length=204.553 s` ✔ |
| C3 挂载 | 雨天挂 `RainAmbient` → `Ambient` 总线 → 正在播 | `bus=Ambient playing=true loop=true`，播放器计数 1 ✔ |
| C3b 切关释放 | 晴天关卡（雨→晴）播放器计数归 0、`mounted=false` | 计数 0 ✔ |
| C4 暂停 | `set_paused(true)` → `stream_paused == true` | ✔ |
| C4 恢复续播 | 恢复后 `stream_paused=false` **且** `playing=true` **且**位置不回到 0 | 暂停时 1.128 s → 恢复后 1.685 s（**续播，不是重头**）✔ |
| C5 不叠音 | 同车重复 apply×3、换模块实例 apply×2 → 播放器计数恒 1，**且逐帧采样最大值恒 1** | 计数 1、max_seen 1 ✔ |
| C6 真场景 | 雨关 1 个 / 晴关 0 个 / 树暂停跟着停 / 恢复接着播 / 重进不增长 / 场景释放归 0 | 全部 ✔ |
| C7 引擎声 | `EngineSound` 走 SFX | `bus=SFX`，`volume_db = -6.0` ✔ |

### 2.2 叠音检测口径（这里踩了一个坑，值得单独记）

第一版按**节点名**数 `RainAmbient`。注入缺陷那跑真的叠了两个播放器，但计数**仍然是 1** —— 因为 Godot 给重名子节点会自动改名（`RainAmbient` → `@RainAmbient@2`），按名字数根本抓不到叠音。
已改成按 **stream 资源路径**数（"树上有几个在放雨声素材的播放器"），并保留名字计数作参考指标。改完之后同一份缺陷立刻打出 `C5 同车重复 apply×3 后雨声播放器计数 = 4（应 1）`、`换模块实例 apply×2 后 = 6（应 1）`。

⚠ 口径边界（如实披露）：GDScript 没有 API 能枚举**已经脱离父节点且不在 root 子树内**的对象；我对这一层的覆盖是"**逐帧采样取最大值**"—— 只要它在某个瞬间还挂在树上（含 `queue_free` 待删那一帧、含无 owner 的节点，`find_children(..., recursive=true, owned=false)`），就会被抓到。真正被 `remove_child` 摘走后再也没入树的节点，GDScript 层面无法枚举。

### 2.3 `default_bus_layout.tres` 有没有进 PCK：**进了**（实际解析 PCK 文件表，不是看 `export_presets.cfg`）

用 `godot-logs/rel-final-pck-enum.py` 按 Godot 4 PCK 格式真解析 `dist/Godot-Racer-0e5430f/Godot-Racer.pck`（`magic=GDPC pack_version=2 engine=4.4.1`，126 项）：

```
default_bus_layout.tres.remap                  IN_PCK size=111
default_bus_layout.res（二进制化资源）            IN_PCK size=906
godot-racer-audit.html                         MISSING(预期)   ← 负对照
nonexistent-xyz.tres                           MISSING(预期)   ← 负对照
```

并把 `.res` 从 PCK 里抽出来验了内容：`contains AudioBusLayout True / Master True / SFX True / BGM True / Ambient True`；`.remap` 内容指向 `res://.godot/exported/133200997/export-<md5>-default_bus_layout.res`。

⚠ 第一版判据我写成了查 `res://default_bus_layout.tres`，结果报 MISSING —— 那是**我的判据错了**：导出包里的 `.tres` 一律走 `.remap` + 二进制 `.res`（与 `level_*.tres` 完全同一机制）。按 remap 这一对判断才对。

→ **结论：导出游戏里 SFX / BGM / Ambient 三条总线都在，雨声不会退回 Master。**
（顺带：`rain_loop.ogg` 的导入产物 `rain_loop.ogg-...oggvorbisstr` 1,736,126 字节也在包里。）

### 2.4 ⚠ 只能人工听音的 6 项 —— **全部未验证，严禁写成通过**

| # | 项目 | 状态 | 现状（机器能看到的客观事实） |
|---|---|---|---|
| ① | 雨声与 −6 dB 引擎声的**音量比例**是否合适 | **需人工听音 / 未验证** | 三条总线都是 0 dB；`EngineSound.volume_db = -6.0`（SFX），雨声播放器未设 `volume_db`（即 0 dB，Ambient）。**比例一次都没调过**，只是"都出声了"。 |
| ② | 204.55 s 循环的**接缝有没有咔哒声** | **需人工听音 / 未验证** | 机器只证明了 `stream.loop == true` 和长度 204.553 s；Ogg Vorbis 循环点是否无缝、包络是否对齐，只能听。 |
| ③ | 雨声与占位引擎声**叠加的整体听感** | **需人工听音 / 未验证** | 引擎声是 `AudioStreamGenerator` 实时合成的**占位音**（22050 Hz / 0.5 s 缓冲），不是真实引擎采样。叠加后是否刺耳、是否糊，只能听。 |
| ④ | **暂停恢复的续播听感** | **需人工听音 / 未验证** | 机器证明了恢复后 `playing=true` 且位置从 1.128 s 续到 1.685 s；**有没有咔哒/爆音**听不出来。 |
| ⑤ | **雨天切晴天关卡后有无残留** | **需人工听音 / 未验证** | 机器证明了节点数归 0；但"耳朵里还有没有一瞬间余音"取决于音频线程的淡出，只能听。 |
| ⑥ | **导出包（EXE/PCK）内的实际表现** | **需人工听音 / 未验证** | 机器只证明了资源进了包（见 2.3）；**导出包里有没有真的出声、音量是否与编辑器内一致**，需要在真机跑起来听。 |

---

## 3. 判定汇总

| 阶段 | 判定 | 说明 |
|---|---|---|
| A · 全量 20 项 | **PASS** | 20/20，EXITCODE=0，18 份日志全部 FRESH |
| B · 结算与退出专项 | **PASS** | 67/67 + B7 双模式守卫；7 类用例**每类都有注入缺陷的红灯证据**；退出期泄漏告警已定位为测试侧收尾问题并修掉，产品侧逐轮计数持平、不累积 |
| C · 音频专项 | **PASS（机器可验部分）** | 37/37；PCK 内总线布局已实际验证；**6 项人工听音未验证**（上表） |
| D · 独立目录验证 | 未做 | 本轮按指令跳过 |

## 4. 需要写进交付报告的披露项

1. **全量套件汇总日志的控制台回显段有编码乱码**（外层未设 UTF-8，把子进程输出按 gb2312 解了）。逐项判据以归档日志原文 + 汇总表末尾的"人工复核汇总（UTF-8 干净版）"为准。
2. **`rel-final-finish-green2.log` 的退出期泄漏告警是已修的测试脚本问题**，不是产品遗留项（见第 0 节）。
3. **6 项音频听感未验证**（见 2.4），尤其是①音量比例从未调过、③引擎声仍是占位合成音。
4. 音频叠音检测第一版按节点名数会漏（Godot 自动重命名为 `@RainAmbient@2`），现按 stream 资源路径数；"完全脱离场景树的孤儿对象"GDScript 无法枚举，这一层只能靠逐帧采样覆盖。

## 5. 本轮新增文件（均为未跟踪，未提交）

- `godot-racer/tests/rel_final_finish_flow_test.gd`（B1–B6，67 条）
- `godot-racer/tests/rel_final_mode_guard_test.gd`（B7，需带 `--check=` / `--shot` 起进程）
- `godot-racer/tests/rel_final_audio_test.gd`（C，37 条）
- `godot-racer/tests/rel_final_leak_probe_test.gd`（资源累积探针）
- `04-Godot启动器/run-rel-final-test.ps1`（通用 runner：UTF-8 强制 + preflight + 崩溃重试 + 日志落盘）
- `godot-logs/rel-final-pck-enum.py`（PCK 文件表解析器）
