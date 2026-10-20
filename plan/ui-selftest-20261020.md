# UI-20261020 实施与秒级自测记录

状态：代码已写入工作区；只有自测结果，正式T与真人U均待本机验证。没有git commit/push。

基线HEAD：4135f86b5e95e01eb4e0e8b567b9d5e8a7d3e223。修改四个原页面/HUD脚本，增加共用令牌、菜单弹层、专项断言和离屏预览工具。没有修改main、GameState、物理、AI、几何、关卡、场景、旧测试或runner。原工作区冻结带、导入文件、未跟踪素材/文档/工具保留。

## 实现内容

- 首页：大关卡卡片、真实赛事参数、推荐极速标记和偏离提示；默认值沿用effective_speed/speed_user_set；独立设置/帮助/退出及完整键盘焦点。
- 根据用户本轮截图补充：首页信息板右上直接显示“AI 对手：开启/关闭”。与设置弹层共用GameState.ai_enabled；点击立即更新有效台数；Tab链包含快捷开关；退出确认期间下层焦点禁用，取消后恢复。
- 倒计时：主题色面板、三灯、数字缩放。COUNTDOWN_SECONDS=3.0、GO_HOLD_SECONDS=0.5、现有finished信号与main回调保持不变；新动效无await。菜单原CLI辅助协程逐代码行保留。
- 结算：快照结果/名次/圈数/总时间/末圈/最快圈、只用last-best的差距、参赛表和三个真实出口；练习也显示差距。缺字段不伪造对手/名次/零圈；不显示无数据来源的历史纪录、分段、名次变化。
- HUD：原位置/数据路径不动；六标签白字#F3F6FA、黑描边4px、底衬#0B0D11 alpha0.86；逆行提示原6px保留。

原首页/结算内部布局函数和过时样式注释已随本次重做替换；功能迁移到对应页面/共用模块，非删除设置能力。所有修改/新增gd均小于1000行，无新class_name；新gd均有手写且无撞号的13位UID。

## 文件、最终行数和工作区SHA256

| 文件 | 行数（含注释/空行） | SHA256 |
|---|---:|---|
| godot-racer/scripts/menu.gd | 374 | dd0293a013e4ad8a0a7ba8b137f65ab97e84a5aae05fbf6efc897638f020f5b2 |
| godot-racer/scripts/start_countdown.gd | 141 | 79fc9f4770bc37683a1bb18df6b96dc3e8bf0c8706d52f22fc6c9db7b6240938 |
| godot-racer/scripts/finish_menu.gd | 199 | 1eee3fa8a9fe2a892787c83ec540a56f6e73c635a6b8edb49fb8f2ceb55399d0 |
| godot-racer/scripts/hud.gd | 469 | a5f2f2f3c69a9fb9c6a3a3a9cabfb309ca459e4e863e96010ce2e8a5cbf11698 |
| godot-racer/scripts/ui_theme.gd | 144 | 4510aa2b5d87b08d843a13447dde378e87d67bf6eb88f475dba062fcafaa9bc2 |
| godot-racer/scripts/ui_theme.gd.uid | 1 | 1dc95011bc9bfcd72acf9ff098ce09de5582f1724a7f79dc08cad2a18fb39816 |
| godot-racer/scripts/menu_overlay.gd | 65 | 8779d095e2f9abe260712610efcf77e05359e0c0baf18700d6328f400d444737 |
| godot-racer/scripts/menu_overlay.gd.uid | 1 | 753020cbb58ced925f503cdbb06a851e62f74179edf8f28692af04fb4e0cf29e |
| godot-racer/tests/check-ui-pages.py | 85 | 866c1718d06089a632a003c764777a117d822f42acaa15cc3b9217ab7067b128 |
| godot-racer/tests/ui_pages_test.gd | 388 | 680666a6071a36b4841b98306fa46b6a10b049c4f49ef5bf85ac9e4876964005 |
| godot-racer/tests/ui_pages_test.gd.uid | 1 | b36a7b219147c2be16788311e64ff1f11a3e60e14344ca4f18b179c863dd34de |
| godot-racer/tests/ui_pages_preview.gd | 70 | 1d8d9623fe965670c3cd9076892a63f88f3d79c791a0738e4813b23074303e4a |
| godot-racer/tests/ui_pages_preview.gd.uid | 1 | 808b69fc32030ff6ec26708e0910dd94f08b07b89d0a44ae47f61727a95d7d43 |
| plan/ui-spec-20261020.md | 179 | ade92363818e5f333a62c0b81254d10522fcb51cf8c055923f7894f03b7a1da0 |
| plan/ui-selftest-20261020.md | 110 | 本报告不自算哈希 |

## 真实命令与退出码

在仓库根目录执行；PowerShell输出UTF-8，Python输出UTF-8。

```powershell
$env:PYTHONIOENCODING='utf-8'
python godot-racer/tests/check-ui-pages.py
& 'E:\godot\Godot_v4.4.1-stable_win64_console.exe' --headless --path godot-racer --script res://tests/ui_pages_test.gd --log-file ../godot-logs/ui-pages-runtime-20261020.log
& 'E:\godot\Godot_v4.4.1-stable_win64_console.exe' --path godot-racer --resolution 1366x705 -- --shot-menu=30
```

| 项目 | 真实退出码 | 日志/事实 |
|---|---:|---|
| 最终源码自测 | 0 | UI_SOURCE_DONE PASS=24 FAIL=0；ui-pages-source-20261020.log |
| 最终引擎页面实例自测 | 0 | UI_RUNTIME_DONE PASS=191 FAIL=0；ui-pages-runtime-20261020.log |
| 计时采样（补首页AI开关之前一次） | 0 / 0 | 源码1.670秒、引擎3.644秒；该次运行时184个PASS，最终补测为191个PASS，不混用计数 |
| 原--shot-menu路径，含首页AI快捷开关 | 0 | save_png=0；ui-menu-final-1366x705.png |
| git diff --check（四个既有修改脚本） | 0 | 只有Git LF/CRLF提示，无空白错误 |
| 图形预览：1366×705结算夹具 | 0 | UI_PREVIEW_SAVE=0，ui-preview-finish-fixture-1366x705.png |
| 图形预览：1366×705倒计时夹具 | 0 | UI_PREVIEW_SAVE=0，ui-preview-countdown-fixture-1366x705.png |
| 图形预览：1366×705帮助 | 0 | UI_PREVIEW_SAVE=0，ui-preview-help-fixture-1366x705.png |
| 图形预览：1920×1080首页 | 0 | 离屏渲染，ui-preview-menu-fixture-1920x1080.png；此图在补AI快捷开关前生成，不冒充最终首页截图 |

最终运行时日志含一条预期WARNING：HUD夹具未注入minimap，因此小地图不启用；没有SCRIPT ERROR/Parse Error。夹具只实例化UI与四个HUD标签，不装配赛道、不模拟真实完赛。

## 判据自测明细

下表统计最终原始日志的断言次数。PASS是自测标签，不是正式验收结论。详细每条输入/期望见ui-spec-20261020.md，逐行结果见两个原始日志。

| 判据ID | PASS断言数 | FAIL断言数 |
|---|---:|---:|
| CD-01 | 2 | 0 |
| CD-02 | 3 | 0 |
| CD-03 | 1 | 0 |
| CD-04 | 14 | 0 |
| CD-05 | 4 | 0 |
| FIN-01 | 5 | 0 |
| FIN-02 | 7 | 0 |
| FIN-03 | 12 | 0 |
| FIN-04 | 2 | 0 |
| FIN-05 | 12 | 0 |
| FIN-06 | 31 | 0 |
| HUD-01 | 7 | 0 |
| HUD-02 | 1 | 0 |
| MENU-01 | 6 | 0 |
| MENU-02 | 15 | 0 |
| MENU-03 | 11 | 0 |
| MENU-04 | 3 | 0 |
| MENU-05 | 17 | 0 |
| MENU-06 | 9 | 0 |
| MENU-07 | 1 | 0 |
| MENU-08 | 4 | 0 |
| MENU-09 | 30 | 0 |
| MENU-10 | 4 | 0 |
| UI-01 | 14 | 0 |

MENU-07的加载失败文案为源码核查，未故意移除真实赛道资源测试失败；MENU-08仅--shot-menu真实启动，check/level/autostart由原_ready与原辅助函数的逐代码行一致性检查保护，真实进赛道路径留本机。MENU-09/FIN-06为尺寸、边界与按钮高度断言，不代表截图/鼠标全流程验收。CD为手动delta实例断言，不代表玩家/AI真实物理发车专项。

## 红项与判据变更如实记录

1. 改生产代码前：源码12 PASS/8 FAIL，退出1；运行时9 PASS/16 FAIL，退出1。原始记录为ui-pages-source-red-20261020.log和ui-pages-runtime-red-20261020.log。新建测试UID初稿多一位，被原长度判据识别后修UID，没有改格式判据。
2. 首轮运行时虽退出0，但人工复查发现MENU-09只检查“不出界”，缩小成极小画布仍会PASS。收紧为同时断言预期1366×705等比尺寸，得到91 PASS/2 FAIL，退出1；记录ui-pages-runtime-layout-red-20261020.log。修menu初始化为set_anchors_and_offsets_preset后再测，不放宽尺寸容差。
3. 增补主题色断言时，测试误以为当前关卡仍是L1，实际上前一测试已选L5，产生177 PASS/1 FAIL，退出1。记录ui-pages-runtime-fixture-red-20261020.log。修测试前置条件显式选择L5并按已批准#A8C4DC断言；未改生产色值迁就错误预期。
4. 用户反馈首页缺AI开关后，新增MENU-10与Tab链/按钮尺寸检查；追加验证首页开关和设置弹层状态同步。
5. 没有放宽验收阈值，没有删除旧测试，没有修改runner/旧验收判据。新专项判据有上述收紧、测试前置修正及覆盖增补，因此初始与最终断言总数不同；不把它们描述成完全同一冻结测试集。

## 未运行与已知限制

- 未运行run-all-checks（包括Quick）、aidiag/lap/stress/opponents、D2双帧率、正式lint/parse链及旧长场景专项；按用户分工留本机。
- 没改godot-racer/docs或README，未触发check-docs/check-readme；计划与报告放plan。
- 未测试真实油门按住/AI同步发车、完整完赛/连续重开、真实check/level/autostart入口、雪山亮背景实赛HUD对比；main/GameState/物理源码无diff不能替代这些运行证据。
- 已查看1366×705原菜单和UI夹具、1920×1080离屏首页。未做1920×1080原生窗口实测，未采集胜/负/练习实赛截图与真人录像。
- UI图片来自Godot实际渲染。finish夹具快照是合成测试输入，不能当作真实成绩；countdown夹具没有实际赛道/AI。没有用概念图代替游戏截图。
- 正式T结论、本机独立复跑、真人U均待完成。本工单文件未提交，用户既有改动未暂存。
