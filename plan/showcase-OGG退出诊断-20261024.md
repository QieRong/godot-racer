# 菜单OGG退出生命周期与测试清理诊断

> 续接状态：[本轮现场修复与验证](showcase-OGG退出修复-20261024.md)。下文保留原诊断时的产品未修状态及红证据，不代表最新现场。

基线：`3dbb9f15882814f1a6faf21a43a8ce7c6051bb9e`。本轮仅新增音频诊断及证据，**没有修改menu_music、menu、game_state、既有测试或OGG素材**；快照哈希逐项核验一致。不重跑已通过的性能、P0、间隙、台体、Logo或入场专项。

## 已证实的两类缺口

1. **仅在树析构时清理不能保证无泄漏。** 不加载首页/展台/车型的最小音频探针，在音乐播放时直接quit，复现与旧日志相同的四类泄漏：OggPacketSequence、AudioStreamOggVorbis、AudioStreamPlaybackOggVorbis、OggPacketSequencePlayback。该次5/0、引擎退出0，但严格harness FAIL，8条错误/泄漏匹配。不能只看断言或退出码。
2. **固定0.2秒不是音频服务回收凭证。** 相同源码、WASAPI及清理调用下，正常帧速7/0、退出0；引擎每帧延迟250ms时，0.2秒计时结束仍有流及Playback存活，6/1、退出1。相同慢帧改为按实例ID等待实际释放，2帧566ms后7/0、退出0，无错误/泄漏。这个负例没有引擎泄漏错误；失败项是资源仍在服务中，不能将它冒充另一条实际泄漏日志。

这证明了退出协议/清理前置条件存在风险，不是OGG资源无法播放。**尚不能断定历史s4/s5每次偶发泄漏都只有这一根因，也尚未修复产品退出协调。**

## 实测方法与结果

Godot 4.4.1；`--display-driver headless --audio-driver WASAPI`，实际驱动断言为WASAPI。无GPU，不需要窗口焦点。每次均确认真实循环OGG、播放进度实际推进、流和Playback实例ID非零。复用现有 `tests/audio_exit_probe.gd` 按ID逐帧等待；2秒仅为失败保护，不是成功条件。诊断不持有资源强引用。

入口：`python godot-racer/tests/run-menu-music-lifecycle.py <mode> <新tag> [--frame-delay 250]`。新标签不能覆盖已有JSON。

| 标签 | 最终OGG_COMPLETE | 引擎退出 | 错误/泄漏 | 严格判定 |
|---|---|---:|---|---|
| ogg-shutdown-original-01 | shutdown 7/0 | 0 | 无；2帧33ms回收 | PASS |
| ogg-free-original-01 | free 6/0 | 0 | 无；3帧65ms回收 | PASS |
| ogg-confirm-original-01 | confirm 6/0 | 0 | 无；单次样本，不证明所有确认时序安全 | PASS |
| ogg-tree_exit-original-01 | tree_exit 5/0 | 0 | 上述四类真实泄漏 | FAIL |
| ogg-cancel-original-01 | cancel 10/0 | 0 | 无；旧回执2帧32ms，新回执2帧30ms回收 | PASS |
| ogg-legacy-normal-01 | legacy_timer 7/0 | 0 | 无；固定0.2秒正常帧对照 | PASS |
| ogg-legacy-slow-01 | legacy_timer 6/1 | 1 | 无引擎错误；固定等待后回执/流仍存活 | FAIL |
| ogg-drain-slow-01 | shutdown 7/0 | 0 | 无；慢帧下2帧566ms实际回收 | PASS |

完整原始证据和快照在 `godot-logs/ogg-exit-20261024/`；选择性原始JSON/引擎日志与未修改音乐源码快照在 `plan/showcase-ogg-evidence-20261024/`。原红日志保留，不改写为绿。

检查：lint扫描90个gd通过，新探针真实解析与Python AST通过。全量暂存diff空白检查只命中原始泄漏日志中空的 `Resource path: ` 行尾空格；为保留原字节，不修剪引擎证据。代码与文档范围单独检查，不能把全量检查写成通过。

## 下一步直接执行的最小修复

1. 在 `menu_music.gd` 增加可等待且幂等的关闭接口：同步捕获自有复制流和Playback的实例ID，禁止续播、stop并清空stream；按ID逐帧确认回收，带有界超时。不要保留诊断强引用，不要改OGG素材、音量、循环或菜单偏好。
2. 将 `showcase_contract.gd` 的0.2秒、`menu_interactions_test.gd` 的0.15秒清理迁移到实际回收判定；保留全部旧业务断言。仅跑音频清理验证，不重跑已通过展台专项。
3. 最小接入真实退出协调：先只读确认窗口关闭路由，再接入 `GameState.confirm_exit` 和 `menu.gd` 的CLI截图退出；成功回收后才quit，超时明确失败，确认退出期间防止重复/取消竞争。只改退出相关hunk，不碰比赛时钟/物理/AI。
4. 用本轮树退出红例、固定计时慢帧红例做负对照，再验证受协调退出、取消恢复、偏好保存和CLI音频收尾。不能用一次干净运行就关闭竞态。

以上修复尚未实施。menu_music及部分调用方仍是原有未提交依赖；后续提交必须区分已有首页/BGM基础和修复增量，禁止混合暂存。

本轮C：诊断工具已实现，产品未修；T：上述路径已实测且保留两个红例，整体OGG退出门未通过；U：未真人听感验收。用户要求五小时额度剩余1%时暂停；续接先核对本记录、Git及当前余量，不重读整套历史资料。
