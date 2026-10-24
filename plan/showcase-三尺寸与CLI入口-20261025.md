# 首页三尺寸与CLI入口证据

基线HEAD：`9bf35dd02eb5eb1a7bf7255d261cfc182d666968`。本轮只增加 `showcase_delivery_probe.gd`、实际引擎生成且唯一的UID、`run-showcase-delivery.py` 及证据；没有修改产品脚本、资源、物理、AI、时钟或赛道。共享五小时额度由多个项目使用，最后读取剩余15%；本轮到归档推送为止，不启动录像或扩大回归。

## 实际结果

Godot 4.4.1，渲染使用Forward+ / GeForce 920MX，真实WASAPI。三尺寸均为**SubViewport离屏渲染**，不是对应尺寸的系统窗口；1920×1080亦同。显式启用离屏渲染的焦点状态，不冒充操作系统前台焦点。

| 标签 | 最终完成标记 | 引擎退出 | 错误/泄漏与审查结果 | 判定 |
|---|---|---:|---|---|
| matrix-01 | DELIVERY_COMPLETE matrix 0/0 | 0 | 测试夹具提前继承menu，autoload未就绪导致编译错误；严格harness捕获 | FAIL |
| matrix-02 | DELIVERY_COMPLETE matrix 31/0 | 0 | 引擎无错误/泄漏；机器PASS，但查看1366截图发现半透明过渡帧 | 最终截图不接受 |
| matrix-03 | DELIVERY_COMPLETE matrix 34/0 | 0 | 三尺寸真实纹理、PNG、5按钮边界、完整可见车体和像素变化通过；无错误/泄漏；严格PASS | PASS（离屏截图） |
| check-01 | DELIVERY_COMPLETE check 4/0 | 0 | 真实--check参数跳过首页，只请求一次路由；无错误/泄漏 | PASS（入口边界） |
| level-01 | DELIVERY_COMPLETE level 4/0 | 0 | 真实--level=2传到目标关卡；无错误/泄漏 | PASS（入口边界） |
| autostart-01 | DELIVERY_COMPLETE autostart 7/0 | 0 | 先展示选关，1.5秒后直接请求一次关卡2路由，不经双击；音频实际回收，无错误/泄漏 | PASS（入口边界） |

matrix-01修正：改为autoload就绪后动态编译路由夹具。matrix-02修正：原先只等待入场running=false及两次frame_post_draw，仍不足以保证截图稳定。新增“所有车网格transparency≤0.001，且连续四个渲染帧均不在入场”的条件，6秒只作失败watchdog；没有改演出时间、材质或产品代码。matrix-03日志记录三个尺寸均透明度0、连续4帧；三张最终PNG已逐张查看，未见matrix-02的透明车体或明显裁切。原因尚未进一步区分时间线状态更新和渲染提交延迟，不把采集条件修正冒充引擎根因定论。

CLI夹具执行真实menu._ready、参数解析及autostart协程，仅覆写 `_enter_game()` 在调用change_scene_to_file前记录路由。**没有装配实际赛道，因此不代表--check实际检查分派、level/autostart进入比赛的端到端通过**。后续完整入口集成仍待补，避免低额度下跑无关AI/物理重型回归。

`--shot-menu`复用此前 `ogg-real-menu-cli-green-01`：实际截图函数save_png=0，6/0、退出0、无错误/泄漏；本轮重新核对其记录的menu_music/game_state/menu直接源码SHA256未变，不重复启动该测试。最终三尺寸由matrix-03重新渲染。

验证：Python AST通过；原lint扫描91个gd通过，采集条件修正后仅复核修改的探针。新gd 120行，≤1000；新UID来自matrix-02实际ResourceUID.create_id输出，唯一性计数1。真实引擎运行同时完成脚本解析。没有执行全工程parse矩阵。

完整日志、PNG在 `godot-logs/showcase-delivery-20261025/`；精选原字节日志、JSON、matrix-02旧图和matrix-03最终图在 `showcase-delivery-evidence-20261025/`。visual-review.json明确区分机器结果与截图审查，不覆盖旧红/不合格证据。发布仅新增本轮文件，不混合既有未提交首页/BGM和测试修改。

复测入口（这些标签已有证据，必须另取新标签）：

```powershell
python godot-racer/tests/run-showcase-delivery.py matrix matrix-03
python godot-racer/tests/run-showcase-delivery.py check check-01
python godot-racer/tests/run-showcase-delivery.py level level-01
python godot-racer/tests/run-showcase-delivery.py autostart autostart-01
```

状态：C：采集/入口夹具已实现；T：三尺寸离屏截图与CLI入口边界通过，完整端到端及全工程parse未补齐；U：待真人确认，S5整体未完成。

直接下一步：先核对本轮发布回执和共享额度；只读检查旧失败录像中的真实焦点、暂停及入场状态，再修录像采集前置条件，生成成功录像。随后用最小无AI路径补CLI实际场景切换和最终全工程parse/资源哈希；最后单独白名单发布完整首页依赖并请用户实机验收。不重复本轮绿色项目，剩余1%暂停。
