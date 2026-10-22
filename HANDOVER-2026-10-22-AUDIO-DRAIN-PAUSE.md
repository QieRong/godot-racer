# 音频专项退场收尾后暂停

用户要求：“做完这个可以准备push暂停了，要没有额度了”。本轮只收尾CD-CLOCK-AUDIO-DRAIN-001，推送后暂停。

- 起始本地/实时main：`ab30904645e27ec372ef01a0d300be99ff75eae6`；最终提交见Git日志最新`test(audio): drain countdown and race clock scene playbacks`和最终回复。
- 仅两份测试接入已有回执ID回收探针，覆盖重开前/结束时场景；非空捕获、实际回收才通过，断言31/42，生产音频与计时规则未改。
- 有效红测：倒计时30通过/1失败、exit1及泄漏。原两帧圈钟对照本次通过，不作为有效红测。
- 最终自然8次严格通过：倒计时双FPS各31/31、圈钟双FPS各42/42、契约21/21、混合音源14/14、生命周期19/19、所有权12/12，真实exit均0，无脚本错误/泄漏/超时。
- 人工负载30通过/1失败、exit1，仅耗时门红，连续性与回收通过。根证书错误仍在。
- 方案/命令：`plan/countdown-audio-drain-20261022.md`；本地日志：`godot-logs/countdown-audio-drain-20261022/`；归档：`evidence/countdown-audio-drain-20261022.zip`及SHA256，ZIP不含完整资产/缓存。
- C已接入；T限本批；U未验。未重跑Quick、全量suite、AC-13、GUI、真人听感及新导出包。历史访问冲突、phys、冻结带发布、UI UID源门及旧红项均未关闭。
- 既有首页、BGM、相机、冻结带、旧交接删除及未跟踪资产原样保护，禁止reset/clean/stash或混入提交。

下次先读两份AGENTS、上述方案、实时HEAD/main和工作区，再由用户决定下一最小工单。不要自动继续生产音频修复或长时回归。
