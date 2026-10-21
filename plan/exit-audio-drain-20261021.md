# EXIT-AUDIO-DRAIN：按真实回收状态结束文字专项

基线：`7e255c8b72a950e452df3178db4879f31d8f0ffd` 加原有脏工作区；承接 CD-READ-001 与 EXIT-AUDIO-OWNER。保护首页、展车、BGM、相机、冻结带及全部旧红证据。用户明确授权本轮普通提交推送。

## 问题、规则与影响

用户目标是五关准备文字清楚，并尽量避免退出访问冲突。本工单只修测试退场观测，不改变生产退出交互、声音、物理、场景亮度或 GO 时序。生产改动仍仅为上轮 `engine_audio.gd` 的 Playback 持有 Generator 所有权保护。

文字专项原先 `game.queue_free → process_frame → view.queue_free → process_frame → quit`，不能证明音频服务已经交还 Playback。官方 4.4.1 的 `stop_playback_stream()` 将回执置为待淡出删除，音频混音负责摘链、主线程 update 回收，停止播放和销毁回执并非同一时刻：

- [AudioServer 4.4.1 源码](https://github.com/godotengine/godot/blob/4.4.1-stable/servers/audio_server.cpp)（stop、混音摘链、主线程 update）。
- [播放器内部实现](https://github.com/godotengine/godot/blob/4.4.1-stable/scene/audio/audio_stream_player_internal.cpp)（stop 清播放器自身回执）。

最小规则：测试销毁场景前只保存实际回执的实例 ID，不以诊断强引用续命；销毁后逐帧检测 ID 是否仍有效，实际回收即返回，2 秒仅是失败上限。禁止固定 sleep、屏蔽 ObjectDB 或放宽判据。测试 runner 记录实际游戏 exe 的 PID、完整命令和真实 exit，并有独立 60 秒 watchdog；泄漏、缺最终汇总、脚本错误或超时均失败。

影响：新测试辅助 `tests/audio_exit_probe.gd`、文字专项和矩阵 runner；既有 `engine_audio_lifecycle_test.gd` 去掉 0.05 秒固定计时，保留原 16 条断言并增加三轮实际回收断言。回退只反向这些测试增量及本工单提交，不触碰原资产。

## 原始证据

本机原始日志：`godot-logs/exit-drain-20261021/`，所有证据绑定上述工作区，不能说成干净 HEAD 通过。

- 正确 ID 探针：L1/无 AI/Compatibility/Dummy/120 FPS，两帧后 Playback 仍有效（52 ms），继续运行到 82 ms 时已失效，exit 0。初版 WeakRef 探针可能因表达式临时强引用影响观测，不用其 2003 ms 作为回收耗时结论；文件原样保留。
- 相同新增验收红测：原两帧清理下，文字 43 条通过、回收 1 条失败，汇总 43/1、实际 exit 1、PID 5384。此红测退出时未报 ObjectDB，也说明一个退出警告不能代替直接观测回收状态。
- 首次绿测同一场景 44/0、exit 0，额外 8 帧/61 ms 实际释放，无 ObjectDB 泄漏。所有权 12/12；生命周期 19/19，均 exit 0。
- Forward+ L4/WASAPI/60、L5/Dummy/60 补测均 44/44、exit 0，无 ObjectDB 泄漏。前轮这两关 3/2/1/GO 共 8 张最终原图均已复看，标题/提示清楚、正常亮度保持；机器看图不是真人 U。

## 用户再次报告的访问冲突

用户本轮提供两张弹窗：Godot 4.4.1 指令地址 `0x00007FF78904C975` 读取 `0x60` 失败，JIT 弹窗 PID `20064`。用户明确当时只开编辑器供 MCP 连接，没有运行/停止/退出游戏。截图已保存本地证据目录。

实时核对：编辑器 PID 13784 正常响应，命令行为本工程 `--editor`；MCP `get_runtime_status` 成功返回 playing=false，编辑器 Output 无对应启动记录。PID 20064 已退出，没有取得其命令行或原生调用栈；本轮前两次诊断真实 exit 均为 0。不能认定截图来自它们，也不能认定是用户开编辑器造成。console 包装器可以启动同名 GUI exe，不能仅按 exe 名区分进程，后续 runner 因而记录实际 PID。

未修改 Windows 调试器、WER、证书、显卡或引擎版本；未关闭用户编辑器。旧矩阵 19/20 的访问冲突和本次截图均保留为未定位问题，不宣布所有权保护或测试等待彻底解决历史崩溃。

## 五关矩阵揭示的第二条退场链

只观测引擎Generator版本的新20格矩阵：每格44/44且20个实际进程均exit 0；但L3/720p/AI开有Ogg雨声Playback泄漏，runner严格判为 **19通过/1失败、exit 1**。完整结果保留于 `godot-logs/countdown-exit-drain-20261021-matrix/`，不以其余19格或进程exit 0抹掉该失败。

因此下一最小增量只扩展测试探针：销毁前递归捕获当前场景的全部实际AudioStreamPlayer/2D/3D回执ID，销毁后逐个确认已回收。仍不改 `environment.gd` 或生产雨声。独立真实引擎+雨声三轮专项14/14、exit 0；缺回执ID、空捕获列表不能冒充回收成功。雨关按720p/1080p、AI开关做定向补测，不能把补测与前一批矩阵拼成同一次20/20。

最终上述雨关四次定向补测均44/44、实际exit 0，无ObjectDB泄漏；1080p无AI一轮观测到雨声在追加6帧/95ms后回收。最终混合音源14/14、生命周期19/19，均exit 0。该结果证明测试按实际释放回执结束，不将测试辅助代码说成生产退出流程修复。

## 最终验收边界

C：所有权保护与测试退场观测已落地。T：以最终逐项收据为准；本轮完整核心回归、AC-13 18-run、新导出包未验。U：五关可读性、音量/听感及正常退出仍待用户实机确认。系统证书、shadercache 保存错误仍在日志中，不能写零错误或归因全部异常于环境。历史 120 FPS phys 红项、UI 源码门 menu.tscn UID 差异、默认冻结带未发布等边界继续保留。
