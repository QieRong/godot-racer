# 第四轮修复 · TDD 交接文案（ENG-2026-10-19-03 · v1.0 · 2026-10-19 17:25）

> **用途**：复制下方 §1 开场白全文，粘贴到新对话的第一条消息。新对话读完开场白后
> 会先读 §2 两份计划文件，然后从「先红」开始按 A/B/C/D 实施。
> **上游产物**：`plan/round4-implementation-diff-20261019.md`（执行 diff 清单 v1.1）+
> `plan/countdown-timing-ai-grid-gantry-20261019.md`（完整修复计划，§7 决策记录）。
> **纪律**：TDD 先红后绿；自动化路径逐字节不变；验收项数不变；每步提交须用户批准。

---

## 1. 新对话开场白（复制以下全文）

```
【项目】Godot 4.4.1 赛车游戏 godot-racer。仓库根 D:/桌面/DSH-Work/data-analysis，工程根 godot-racer/，引擎 E:\godot\Godot_v4.4.1-stable_win64.exe，关卡索引 0 起（-Level 3 = 荒漠 L4）。remote = github.com/QieRong/godot-racer.git。

【HEAD】0cb669d（chore(assets): 入库环境资产包 models/environment，125 文件）。工作区仅 2 个 .import CRLF 噪声（godot-racer/assets/audio/rain_loop.ogg.import、godot-racer/models/race_car.glb.import，diff 为空，勿动）；plan/ 下三份未跟踪文件（本轮两份计划 + five-levels-excel-pipeline，均未提交）。

【本轮任务】修复用户 2026-10-19 试玩反馈：①「起步时间」缺陷——总时间从「出发！」起算（R15）但本圈从首次压线起算（R6），出生点在起跑线后 2.77m，两个口径差出一段「起步」段，hud.gd 的「起步」行只是把差值摆出来、没解决「对不上」；②「AI 出现时机」——经只读调查实际已满足（AI 装配期生成、早于倒计时），用户截图里疑似滞后的根因是①的总时间与圈速对不上。附带：起点龙门架（desert_ruin_gate.glb）骑线而立 + 带碰撞。

【已拍板决策（2026-10-19 17:08）】D1 统一计时原点：总时间 ≡ 各圈之和，修订已批准的 R6——圈速亦从「出发！」起算、首圈含起跑段（真实赛车静止起步逻辑）；D2 冻结带重冻结：批准 1 次 calibrate + 1 次 freeze + 3~4 次 aidiag 复跑（20~40 分钟机时）；D3 龙门架确认 desert_ruin_gate.glb 即所指模型、跨线而立、立柱在路肩带内且必须带碰撞（撞上不穿模）；D4 AC-13 双帧率回归降级为关键项各一次（lap×1 + opponents L4×1 + L5×1），完整 18 次留发布前。

【关键结论：零改动项】用户清单里的「加 3 秒倒计时状态机」「改 AI 生成时机」两项现行代码已成立，零代码改动、只补回归断言：倒计时四重锁死（game_state.gd:27 COUNTDOWN 相位 + enter_countdown() 树暂停 + vehicle.gd 装配期 start_locked=true + ai_opponent.gd:417-420 armed=false 早退）；AI 在装配期生成（main.gd:316-322）早于 enter_countdown()（main.gd:345）。因此 game_state.gd / start_countdown.gd / opponent_spawner.gd / ai_opponent.gd / scripts/checks/*.gd / data/levels/*.tres / project.godot / race_car.tscn 全部明确不碰。

【必读文件（先读这两份再动手）】
1. plan/round4-implementation-diff-20261019.md —— 执行用 diff 清单：A/B/C/D 提交边界、每个文件的精确 hunk、十步验证链、龙门架观感核对清单
2. plan/countdown-timing-ai-grid-gantry-20261019.md —— 完整修复计划：问题分析、修改方案、模块清单、验证步骤、风险、§7 决策记录

【实施边界（四个提交）】A 统一计时原点（vehicle.gd + race_position.gd + main.gd + tests/countdown_scene_test.gd + tests/race_position_test.gd，必须原子提交）；B 删「起步」行（hud.gd −45 行 + chase_camera.gd 注释同步）；C 起点龙门架（新建 scripts/start_gantry.gd ~140 行带碰撞 + 手写 scripts/start_gantry.gd.uid + main.gd 文件头 preload 与 L322 后挂载）；D 文档 4 处（plan/racing-system-design-20261018.md v1.2 修订 + README.md:25 + godot-racer/docs/portfolio-design.md:11/:26 + godot-racer/docs/testing.md 新增小节）。

【TDD 纪律】第 1 步先红：只改 A-4/A-5 两个测试文件，新断言必须红、旧断言必须绿，红日志归档 godot-logs/round4-*-red.log；然后最小实现转绿；回归；提交。不得为变绿放宽判据/删测试/改阈值。自动化路径（aistart/aidiag/lap/stress/--shot）逐字节不变——begin_lap_timing 门控在 GameState.start_race() 返回值上（该函数仅 COUNTDOWN→RACING 返回真，自动化路径相位早已 RACING 故返回假、圈钟保持「首次压线」旧口径）。验收项数不变：Quick 15 / 全量 20。

【项目铁律】① TDD 先红后绿，验收绑定 commit + 工作区状态；② 验收顺序 lint-gdscript.ps1 → parse-check.ps1 → 专项 → run-all-checks.ps1 -Quick；③ racing_line.gd / track_layout.gd 是几何与限速唯一真相源，禁止复制公式；④ 单文件 ≤1000 行向前约束（vehicle.gd 1413 行属登记在册历史遗留，不阻塞修复性提交）；⑤ 每步完成必须 git push，本地 main 与 origin/main 始终一致（用户要发网页端 DeepSeek 对照）；⑥ 提交/发布/删除须用户人工批准——每步把改动清单和验证结果摆出来再 commit；⑦ 冻结带：main.gd/vehicle.gd/autopilot.gd/game_state.gd/race_car.tscn/project.godot/level_1.tres 源码哈希绑定（main.gd:650-652 initial_state_contract），本轮 D1 改 vehicle.gd 与 main.gd → 必须重走 calibrate + freeze（D2 已批准机时）。

【环境坑（Windows + Git Bash）】Bash 不能调 pwsh（安全策略拦）→ 用 PowerShell 工具；该工具不回传 stdout 且长任务被内部超时掐断（表现 exit 1 + 后续不执行）→ 长验收必须 run_in_background:true，输出 Set-Content 落文件再用 Read 看。UTF-8：本机 gb2312，✔(U+2714) 不可表示 → 不加 UTF-8 强制会全线假红（run-all-checks.ps1 顶部已自带）。shoot.ps1 的 -Out 必须绝对路径（相对必败 err=7）。headless 跑 Godot 不生成 .uid → 新模块 .uid 手写（uid:// + 13 位不碰撞，实施时 grep 确认，照 start_countdown.gd.uid 先例）。core.autocrlf=true：git show 还原后 status 可能报 M 而 diff 为空 → 以 git diff 为准。git push 502：会话环境注入 http(s)_proxy=http://127.0.0.1:10409 对 github.com 的 CONNECT 回 502 → 绕过它再推：env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY git push origin main（curl 直连探测显示 000 不可信，git 推送实际成功）。lap check 是双稳态（同代码依机器负载稳定产出 12956/13460/17092 三种日志规模）→ A/B 前先跑「同代码两跑」定模式再同模式比对；打印物理浮点的类（wallslide/stuck 及所有 L4 族）跨进程不可复现 → 只比结构（AGENTS §4.3），允许 ±1 帧相位差。

【两道文本闸门（提交 D 前必看）】check-docs.ps1 = README + godot-racer/docs/*.md（非递归）+ godot-racer/AGENTS.md；check-readme.ps1 = README + docs/*.md（不含 AGENTS、不含仓库根 .md）。误伤类型①「全部 N 项」：全部\s*(\d+)\s*项 全文档扫并与 runner 实际项数比对 → 引述旧措辞也判红，一律用占位式「全部 N 项」；类型②反引号路径：带 scripts|scenes|tools|assets|data|docs|models/ 前缀 + .gd|.tscn|.tres|.json|.py|.png|.glb|.md 后缀的反引号串要求磁盘存在 → 已删路径不加反引号且不带前缀。plan/ 与仓库根 .md 不在任何闸门扫描集内 → 可写实数。

【验收 runner】20 项：docs / readme / enclosure / wallslide / minimap / obstacles / aistart / aidiag / avoid / pause / flip / layout / reverse / weather / friction / phys / stress / opponents×2 / lap（Quick 15）。aistart 断言全集（scripts/checks/ai.gd:813-890）只读 armed / start_locked / 车速 / 车距，不碰圈速——本轮不命中它，但全量跑时 --check=aistart -Level 3 单独留证。aidiag 指标窗口口径：AI 离玩家 ≥30m 之后 22s（贴身阶段由避让逻辑限速，不是测量对象；停顿/超速两项仍全程）。

【验证链（diff 清单 §5 十步）】1 先红（只改 A-4/A-5 测试，红日志归档）→ 2 提交 A（两个测试转绿 + race_position_scene_test / finish_results_test / release_flow_scene_test 复跑绿 + lint + parse）→ 3 提交 B（finish_results_test + tests/ 全部门复跑 + lint + parse）→ 4 提交 C（parse-check 新模块可编译 + --check=minimap 龙门架不进小地图 + 截图三张：L1 宽路 / L5 窄路 / L4 穿门，观感核对 6 项见 diff 清单 §6）→ 5 提交 D（check-docs.ps1 + check-readme.ps1 全绿）→ 6 冻结带重冻结（tape-preflight.ps1 退出码 0、--check=aidiag 10 断言 0 失败且 measurement_status=COMPLETE、阈值一个不改）→ 7 run-all-checks.ps1 -Quick（15）→ 全量 20 项 60 FPS（20/20、RUNALL_EXIT=0）→ 8 AC-13 降级三项（D4）→ 9 lap 双稳态同代码两跑定模式 → 10 试玩确认（用户实机：L5 倒计时 → GO → 本圈/总时间同时起走、无起步行、AI 并排、龙门架跨线，截屏留证后才可称「试玩缺陷已修复」）。

【已知偏差（用户已确认可接受）】L1 宽路（14m）立柱外侧面会越过护栏线 ~0.9m（唯一旋钮是模型腿厚，属资产改动，不再议）；立柱厚度实测失败时走兜底值 0.5m（日志会声明，截图核对）。

【工作方式】每步提交前把改动清单和验证结果摆给用户看，批准后才 commit + push；A 必须原子提交（vehicle.gd 与 race_position.gd 拆开必红 race_position_scene_test.gd:63——故意为之，证明联动必要）。从第 1 步先红开始；若用户想先把 plan/ 三份未跟踪文件提交归档也可以先做那步（需批准）。
```

---

## 2. 开场白引用的两份计划文件（新对话先读）

| 文件 | 内容 | 何时读 |
|---|---|---|
| `plan/round4-implementation-diff-20261019.md` | 执行 diff 清单：§0 零改动清单、§1 提交 A 五个精确 hunk、§2 提交 B、§3 提交 C 龙门架全文、§4 提交 D、§5 十步验证链与回退点、§6 观感核对 6 项 | **动手前必读**，每个提交照着做 |
| `plan/countdown-timing-ai-grid-gantry-20261019.md` | 完整修复计划：问题分析（含用户四因素核对）、修改方案、模块清单、验证步骤、风险与 D1–D4、§7 决策记录 | 动手前通读一遍，理解为什么 |

---

## 3. 交接 checklist（新对话开场后逐项打勾）

- [ ] 读 §1 两份计划文件
- [ ] 确认 HEAD = `0cb669d`、工作区仅 2 个 .import 噪声（`git status --short`）
- [ ] 向用户复述四个提交边界与十步验证链，确认无异议
- [ ] 第 1 步：先红（只改测试）→ 归档 `godot-logs/round4-*-red.log`
- [ ] 第 2 步：提交 A（原子）→ 批准后 commit + push
- [ ] 第 3 步：提交 B → 批准后 commit + push
- [ ] 第 4 步：提交 C（含截图三张 + 观感 6 项）→ 批准后 commit + push
- [ ] 第 5 步：提交 D（两道闸门全绿）→ 批准后 commit + push
- [ ] 第 6 步：冻结带重冻结（D2，阈值一个不改）
- [ ] 第 7 步：Quick 15 → 全量 20（60 FPS）
- [ ] 第 8 步：AC-13 降级三项（D4）
- [ ] 第 9 步：lap 双稳态同代码两跑
- [ ] 第 10 步：试玩确认，用户截屏留证

---

## 4. 上游决策留档（防新对话反复追问）

- D1 为什么修订已批准的 R6：用户原话「总时间必须严格等于各圈之和，这是赛车游戏的常识硬伤，绝不能留。既然玩家和 AI 都是 3 秒倒计时后同时起步，首圈包含起步反应时间是完全合理的」。
- D2 为什么必须重冻：加了倒计时后起步状态的帧序列变了，旧冻结带作废；`tape-preflight.ps1` 会冻结优先、缺带/作废秒级失败（`f309132`）。
- D3 为什么带碰撞：用户原话「必须确保有足够的宽度，不会撞到车。确保物理碰撞体设置正确（撞上去不穿模即可）」→ 缩放公式 + 同址同厚 BoxShape3D。
- D4 为什么降级：用户原话「完整 18 次太耗时。先降级为关键项各一次……把全量 18 次留给发布前的最终验收（或者你后台挂着慢慢跑，不阻塞其他进度）」。
