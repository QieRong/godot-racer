# EXIT-AUDIO-OWNER：退出播放资源所有权

用户要求尽量避免历史 `0xC0000005` 退出崩溃。本工单承接五关文字验证，不改 UI 判据或核心玩法。

## 已有证据与边界

五关文字矩阵20次全部输出43/43，但L5/720p/AI开在汇总后进程退出 `-1073741819`，整体19通过/1失败。日志完整保留。另一次L1/无AI的verbose退出日志明确列出泄漏类型 `AudioStreamGeneratorPlayback`。Windows应用事件和当前用户CrashDumps未找到对应原生调用栈，因此不能直接宣布该泄漏就是全部历史访问冲突的唯一原因。

核对引擎官方4.4.1源码：`AudioStreamGeneratorPlayback` 用 `AudioStreamGenerator *generator` 裸指针，实例化只赋 `this`；混音/采样率/标记使用流时会解引用它。播放器stop后音频服务仍可能异步持有播放对象。前轮修复只清模块回执、停止播放器，没有覆盖生成器随播放器销毁后的所有权。

- [4.4.1 官方头文件](https://github.com/godotengine/godot/blob/4.4.1-stable/servers/audio/effects/audio_stream_generator.h)
- [4.4.1 官方实现](https://github.com/godotengine/godot/blob/4.4.1-stable/servers/audio/effects/audio_stream_generator.cpp)
- [同类上游 UAF 报告 #92349](https://github.com/godotengine/godot/issues/92349)仅作风险佐证，不等同本机已取得原生崩溃栈。

## 最小修复与验收

让每个实际播放回执通过metadata强引用它的生成器，生命周期随回执释放；生成器自身不持有回执，不构成循环。保留既有stop和模块回执清空。不加固定等待掩盖失败，不改音色、波形、按键、计时、引擎版本或系统调试器设置。

先用独立WeakRef专项验证：原实现音源销毁后，仍存活的播放对象已失去生成器（必须红）；修复后生成器保持有效，最后一个回执释放后生成器可回收（必须绿）。随后复跑既有音频生命周期、真实倒计时及图形退出专项，检查进程退出码和ObjectDB日志。有限复测只能报告本批未复现，不能承诺所有原生崩溃永不再现。

## 实测结果与未闭环问题

- 独立所有权专项：合法红测9通过/3失败、exit 1；修复后12/12、exit 0。更早的首跑为测试脚本类型推断错误，不计产品红测。既有音频生命周期专项16/16、exit 0。
- 真实场景回归：60/120 FPS各跑倒计时29/29、结算57/57、完赛流程67/67，六次均实际exit 0。本批没有复现访问冲突；倒计时120 FPS仍有ObjectDB警告。临时聚合器曾误认完赛标记，最终按实际 `REL_FINAL_FINISHFLOW_PASS` 审计，见 `exit-owner-regression-audit.csv`，不将聚合脚本错误计为产品失败。
- 图形补测四次均43/43且实际exit 0：L1无AI（Compatibility/Dummy/60）、L5（Compatibility/Dummy/120）、L4（Forward+/WASAPI/60）、L5（Forward+/Dummy/60）。后两次没有ObjectDB警告，前两次verbose日志仍列出 `AudioStreamGenerator` 和 `AudioStreamGeneratorPlayback` 泄漏，见 `owner-final-results.csv`。强引用保护使未退完的回执连同生成器存活，并未解决全部异步退场残留。
- 全部证据位于 `godot-logs/countdown-readability-20261021/`；旧20次文字矩阵19/20的访问冲突红证据仍在独立矩阵目录，未覆盖。没有原生调用栈，不能宣布历史0xC0000005彻底修复。
- 最终lint检查81个GD通过；既有解析器聚合53个scripts/scenes/tools源文件，聚合检查exit 0（过滤autoload已知假阳性，不等同53次独立运行，也不包含全部tests）。两道文档门通过，UI源码保护仍60/1、exit 1，原首页UID差异未放宽。

前轮交接状态：C已落地；上述T通过但资源退场仍未闭环；U未验。不要用固定sleep、隐藏ObjectDB、放宽判据或修改系统调试器来消除红项。

## 本轮独立收口

2026-10-21 续做重新核对当前脏工作区并运行独立所有权专项：12/12、实际 exit 0（PID 19784），未见 ObjectDB 泄漏，仍有根证书读取错误。仅提交本工单3行生产所有权保护、独立专项及其UID、本文和 `evidence/audio-owner-20261021.zip`，不吸入首页/BGM/相机/冻结带。ZIP保留合法9/3红测、12/12绿测、既有回归收据与本轮复测原始字节，旁附SHA256。普通推送与远端核对见Git历史及最终交接。

异步退场另见 `exit-audio-drain-20261021.md`：已证实原文字专项两帧后回执可仍存活。用户新提供PID 20064读取0x60崩溃截图，来源与调用栈未取得，继续登记为未定位；没有证据将它归因于用户开着编辑器。此提交仍不能称历史访问冲突彻底修复，U与新导出包未验。
