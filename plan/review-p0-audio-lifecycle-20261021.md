# P0-AUDIO-LIFECYCLE · 2026-10-21

用户要求继续完成进度评审报告，承接 `e744884`。本工单属于 P0-1/P0-2 的退出与回归收尾。

- 玩家问题：结算/重开专项有历史访问冲突；本轮首个详细日志复跑退出 0，但明确泄漏 `AudioStreamGeneratorPlayback`。崩溃根因尚未确认，不把泄漏与崩溃画等号。
- 目的：场景离树时停止旧引擎声并释放模块持有的续填回执，防止旧模块持有失效音源。
- 现状：`engine_audio.gd` 只 setup/tick，无离树清理。模块可以在音源离树后继续持有 playback。
- 最小规则：EngineSound 离树 → stop → 模块 playback 置空；后续 tick 安全空操作。无音源场景仍安全。
- 影响：`scripts/engine_audio.gd` 和独立生命周期测试。原音色、续填频率、输入、GO、物理/AI/验收阈值均保持原规则。
- 判据：3 次真实 AudioStreamGenerator 创建/离树循环，检查接入、续填、停止、引用释放、离树后不续填；修复前必须红。再跑 lint/parse、结算双 FPS 和退出链双 FPS。
- 风险/回退：只回退本工单新增清理接线；不恢复/清理用户原有文件。历史随机崩溃保留为未定位，除非得到独立复现和因果证据。
- U：听觉与真实退出、连续重开仍待用户操作；自动化不能替代。
- 批准：用户本轮已授权继续报告未完成项；此为既有模块生命周期修复，无体验取舍或核心公式改变。

基线：HEAD/现场远端 `e74488428a741665da057244d83832210853e547`，原有脏工作区；证据前缀 `godot-logs/review-p0c-20261021-`。

## 实测与结论

Godot 4.4.1 / Windows / headless，均为原工作区加本修复，物理测试串行。

| 项目 | 结果 | 真实进程退出 |
|---|---|---:|
| 原实现生命周期红测 | 10 PASS / 6 FAIL，3 次均离树未停止、未交还回执 | 1 |
| 修复后生命周期 | 16 PASS / 0 FAIL | 0 |
| 修复前 finish_results 60 / flow 120 详细日志 | 57/57 / 67/67；前者泄漏 AudioStreamGeneratorPlayback，后者无该泄漏 | 0 / 0 |
| 修复后 finish_results 60 / 120 | 各 57/57，均无脚本错误/实例泄漏 | 0 / 0 |
| 修复后 rel_final_finish_flow 60 / 120 | 各 67/67，均无脚本错误/实例泄漏 | 0 / 0 |
| lint / parse | 78 个 gd 引号扫描 / 53 个源码聚合解析通过 | 0 / 0 |

修改：engine_audio.gd 72 → 81 行；新测试 61 行，均 ≤1000。全库仍有 ai_opponent.gd 1686 行的历史债，未增长。

**生命周期缺陷 C/T 已修；U 待验。历史 0xC0000005 本轮修复前也未复现，根因未定，继续保留红项，不能称访问冲突已修。** 根证书环境错误和 `servers` 静态 StringName 提示仍在；不隐藏、不计为音频实例泄漏。

相关上游背景：[Godot #92349](https://github.com/godotengine/godot/issues/92349) 描述生成器退出时音频线程使用已释放 stream 的情形；[Godot #95484](https://github.com/godotengine/godot/issues/95484) 描述播放中退出的 playback 泄漏。仅供诊断假设参考，不作为本机历史崩溃的因果证明。

原始日志与进程收据归档 `godot-logs/review-p0c-20261021-audio-evidence.zip`，附 SHA256；保留前轮全部红证据。机器通过不替代完整 20 / AC-13 18-run / 真人 / 独立包。
