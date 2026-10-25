# 首页展台：录像、实际CLI与最终解析

基线：`df09dbe5931136fd62c024dc566e0b59636e4133`；开工本地/远端一致、0/0、暂存区空。两份AGENTS内容一致。五小时共享额度开工剩余83%，归档前剩余12%；剩余1%必须暂停。原混合工作区未清理，不碰物理、AI、比赛时钟、赛道、冻结带及无关音频。

## 进度口径

原计划S0～S5六包，S0～S4核心已落地。按阶段等权的保守进度约83%（5/6），不是正式工时权重，也不是C/T/U综合通过率。S5证据继续补齐，整体仍未完成；真人U不能由自动录像替代。最新前置记录为 `showcase-三尺寸与CLI入口-20261025.md`，其中已通过且源码未变的项目未重跑。

## 本轮实现边界

只改测试采集：`tests/showcase_contract.gd` 474→526行，记录OS焦点、Window焦点、_focused、suspended、intro.running、dragging、pointer、angle；capture不再合成FOCUS_IN，要求实际焦点及连续四个有效渲染帧，落定后额外检查所有车网格透明度≤0.001。采集时临时CONFINED鼠标，完成或前置失败后恢复原模式。新增显式合成FOCUS_OUT负对照。没有改产品交互。

`tests/run-showcase.py`新增负对照参数。该GD本来含未提交的OGG cleanup/回收改动，本轮原样保护；归档分别保存开工前patch、本轮增量patch及最终源文件，不把既有混合改动直接提交。新增 `showcase_scene_probe.gd`（65行）、`run-showcase-scene.py` 和 `showcase_parse_probe.gd`（30行），两个UID均取自实际引擎输出且唯一。

## 最终结果与红证据

渲染：Godot4.4.1、Forward+、GeForce920MX；实际CLI场景检查使用headless显示驱动、真实WASAPI、--aioff，不冒充图形/驾驶端到端验收。

| 标签 | 完成标记 | 引擎最终退出码 | 失败/错误/泄漏 | 判定 |
|---|---|---:|---|---|
| 旧showcase-demo | capture 8/3 | 1 | 3拖拽断言失败；旧日志不含焦点取证 | 继续保留FAIL |
| capture-diagnose-20261025-01 | capture 12/0 | 0 | user://缓存权限、系统证书错误；设置保存警告 | 严格FAIL，不能算成功 |
| capture-diagnose-20261025-02 | capture 12/0 | 0 | 无错误/泄漏，实际焦点始终有效 | PASS，旧失败未复现 |
| capture-blocked-20261025-01 | capture 1/1 | 1 | 前置断言失败；OS焦点true而内部焦点false/suspended=true；无错误/泄漏 | 合成阻断负对照按预期拒绝 |
| capture-ready-20261025-01 | capture 13/1 | 1 | 拖拽后段被打断，指针被原生事件改变；无错误/泄漏 | FAIL，不能冒充成功 |
| capture-ready-20261025-02 | capture 14/0 | 0 | 无错误/泄漏；全过程DRAG、角度变化>TAU，释放后恢复AUTO | PASS，成功自动录像 |
| real-level-01 | ready 7/1、complete 7/1 | 1 | 夹具错用Car节点名；harness打印另遇GBK编码错误；无引擎错误/泄漏 | FAIL，已保留 |
| real-level-02 | ready 8/0、complete 8/0 | 0 | 无失败/错误/泄漏 | PASS，实际main装配至COUNTDOWN |
| real-autostart-01 | ready 8/0、complete 9/0 | 0 | 无失败/错误/泄漏；BGM回收通过 | PASS，实际main装配至COUNTDOWN |
| real-check-01 | ready 8/0、生产[CHECK]完成退出 | 0 | 无失败/错误/泄漏；实际minimap分派/跟随检查；本关无障碍分支跳过 | PASS，真实检查入口 |
| final-parse-01 | 缺失最终完成标记 | 124（watchdog） | CACHE_MODE_IGNORE重复加载执行中的探针自身，引擎Internal script error | FAIL，保留日志；初版harness未生成JSON |
| final-parse-02 | FINAL_PARSE_COMPLETE PASS=93 FAIL=0 | 0 | 无错误/泄漏 | PASS，自有GD；排除addons/.godot及生成聚合文件 |

旧录像没有状态日志，仍不能断言其唯一根因是失焦；本轮证明了正常焦点时可成功，阻断时应拒绝，并观察到原生指针事件可打断未约束的自动输入。CONFINED仅属采集夹具，不改变玩家鼠标规则。

CLI探针不覆写menu._enter_game，真实change_scene_to_file(menu.tscn)后由生产菜单切换到main.tscn，等待_setup_done，检查目标关卡、Track、RaceCar、对手为空及首页实例释放。level/autostart使用0基关卡1；check使用默认关卡0和真实--check=minimap，继续由生产检查自行完成退出。没有验证真实驾驶、倒计时全程/完赛、AI或导出包。

解析每次使用新引擎进程，autoload就绪后首次加载各自有脚本；缓存复用避免重新替换正在执行的探针。Python AST通过；最终资源复核：race_car.glb/icon.svg与旧保护基线相同；menu/homepage/car_showcase/showcase_podium/showcase_intro/menu_music/game_state与matrix-03 SHA256全部相同。新增及修改GD均≤1000。不是全库历史行数债务清零，也不是完整资源依赖发布证明。

完整日志：`godot-logs/showcase-capture-20261025/`；capture原始引擎日志/AVI/PNG在 `godot-logs/showcase-20261023/`，全用新标签。精选证据 `showcase-capture-evidence-20261025/`，含红绿日志、JSON、三张已查看的关键PNG、patch及哈希清单。成功MP4：`godot-logs/showcase-capture-20261025/showcase-demo-success.mp4`；ffmpeg转码退出0、完整解码退出0且无错误。705高只补1像素为偶数，不裁切。失效WinGet链接和PowerShell重定向失败日志保留，最终用已安装包的实际ffmpeg完成。

## 精确下一步

1. 先读实时额度及本文件，本轮收尾回执另见完整日志目录；不可重跑已通过且代码未变的项目。
2. 单独核对并白名单发布完整首页依赖：menu/homepage/BGM/OGG回收、菜单场景、主题/覆盖层、音频及许可、关联测试。当前远端仍不等于完整本地首页。project.godot还有无关camera_rear输入，chase_camera及冻结带等已有修改不得混入。不能直接暂存全部工作区。
3. 请用户本机运行工程，确认“台面自转不停止、汽车悬停停止、拖拽/松开、设置/帮助/失焦恢复、先空台后车辆、重进0.35秒、点击开始即时有效”。记录真人U结论；机器录像不代签。

复测仅在相关源码变化或需要新证据时执行，并使用新标签：

```powershell
python godot-racer/tests/run-showcase.py capture NEW_TAG --graphics --renderer forward_plus --movie
python godot-racer/tests/run-showcase.py capture NEW_NEGATIVE --graphics --renderer forward_plus --capture-blocked-control
python godot-racer/tests/run-showcase-scene.py level NEW_LEVEL
python godot-racer/tests/run-showcase-scene.py autostart NEW_AUTOSTART
python godot-racer/tests/run-showcase-scene.py check NEW_CHECK
```

状态：C核心已实现；T上述专项通过、红证据保留；U待用户。S5未完成，完整首页未发布。
