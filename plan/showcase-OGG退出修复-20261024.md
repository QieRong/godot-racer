# 菜单OGG退出：现场最小修复与续接

工单：SHOWCASE-OGG-DRAIN。开工HEAD `8f6049d3fd508f54186e7dc56938ae98a049f843`；origin/main本地追踪值 `3dbb9f1`。大量原有未提交首页/BGM、素材和冻结带文件保留；没有重做首页或修改车辆、AI、赛道、时钟公式及OGG素材。

## 本轮规则与实现

目标：正常确认退出、窗口关闭确认、CLI菜单截图、两类菜单测试，在树析构之前确认菜单OGG实际回收。取消确认仍可恢复播放；一旦确认开始收尾，重复确认、再次窗口关闭或取消不能启动第二条退出/续播链。

`menu_music.gd`新增 `shutdown_and_wait(timeout_ms=2000)`：先禁用续播，捕获复制流及各次stop前的播放实例ID，stop并断开stream，再按实例是否存活逐帧等待。只保存ID，不持有资源强引用。停止/重播前产生的旧回执也纳入检查；重复关闭幂等，不写音乐偏好。2秒是失败保护，实际回收才是成功条件；接口超时返回false，支持释放外部持有后重试。

`GameState.quit_after_menu_audio()`统一确认退出及自动化关闭分支；超时明确报错并退出1。`menu.gd`截图完成后使用相同协调入口。showcase和菜单交互测试改为等待实际回收，并添加清理失败断言；原有业务断言保留。新增cleanup用例仅验证展台测试的音频清理，不跑P0/台体/Logo/入场等已通过项目。

影响文件与行数：menu_music 86→128；game_state 512→530；menu 506→502；showcase_contract 478→481；menu_interactions_test 372→371，均≤1000。诊断探针和Python runner增加接口、实际路由、超时与调用方清理验证。

## 本轮真实验证

Godot 4.4.1，WASAPI。除实际截图一项使用Forward+外，其余headless显示驱动，无需窗口焦点。慢帧参数为 `--frame-delay 250`。每行均核对最终完成标记、引擎退出码和错误/泄漏，严格harness不因负例而放宽。

| 标签 | 最终完成标记 | 引擎退出 | 错误/泄漏与失败项 | 严格判定 |
|---|---|---:|---|---|
| ogg-api-red-01 | OGG_COMPLETE coordinated 5/1 | 1 | 缺少可等待关闭接口；另有沙箱根证书读取ERROR，无泄漏 | FAIL |
| ogg-api-green-01 | OGG_COMPLETE coordinated 11/0 | 0 | 无错误/泄漏；慢帧2帧501ms实际回收 | PASS |
| ogg-state-red-01 | OGG_COMPLETE state_confirm 6/2 | 0 | 确认后仍能取消、树析构前资源未回收；无引擎错误/泄漏 | FAIL |
| ogg-state-green-01 | OGG_COMPLETE state_confirm 8/0 | 0 | 无错误/泄漏；慢帧2帧502ms回收 | PASS |
| ogg-rapid-green-01 | OGG_COMPLETE rapid 16/0 | 0 | 快速取消重播4次，全部旧回执释放；无错误/泄漏 | PASS |
| ogg-timeout-green-01 | OGG_COMPLETE timeout 13/0 | 0 | 刻意持流时接口超时返回false，释放后重试成功；无错误/泄漏 | PASS |
| ogg-window-green-01 | OGG_COMPLETE state_window 8/0 | 0 | 发出真实close_requested信号进入确认，再确认退出；无错误/泄漏 | PASS |
| ogg-cli-route-green-01 | OGG_COMPLETE state_cli 6/0 | 0 | 带shot参数的窗口关闭走自动化分支；无错误/泄漏 | PASS |
| ogg-exit-timeout-negative-01 | OGG_COMPLETE state_timeout 9/0 | 1 | 刻意持流2秒，明确ERROR且released=false；无泄漏 | FAIL（预期负对照） |
| ogg-showcase-cleanup-green-01 | SHOWCASE_COMPLETE cleanup 2/0 | 0 | 仅新清理入口，慢帧2帧501ms回收；无错误/泄漏 | PASS |
| ogg-menu-music-green-01 | INTERACTION_DONE music 21/0 | 0 | 真实循环/解码、偏好、取消退出、切页和返回菜单、新清理；无错误/泄漏 | PASS |
| ogg-real-menu-cli-green-01 | OGG_COMPLETE state_menu_cli 6/0 | 0 | 实际menu截图函数save_png=0，PNG有效，2帧8ms回收；无错误/泄漏 | PASS |

超时负对照的9/0表示“负分支按预期触发”，不是产品退出成功：严格harness仍FAIL。探针在树开始析构时才释放自己刻意保留的引用，日志中的最终资源检查发生在释放探针引用之后，不得作为“产品超时也已回收”的证据。

API首条红例在沙箱内执行，有独立根证书环境错误；后续真实引擎专项以正常权限执行，无该错误。没有重跑已经转绿的接口/路由。parse工具曾在沙箱Forward+环境报告shader缓存权限ERROR和已知autoload假阳性；工具最终退出0、6个脚本通过，但不能把其原始日志说成无ERROR。真实运行专项同时覆盖实际autoload编译。最后lint扫描90个gd退出0，Python AST检查退出0。

本轮没有性能测量。此前已通过的同机A/B与展台专项结果不重复运行；没有将音频专项当成全菜单/三尺寸/录像或真人验收。

## 源码保护、发布边界与回退

上述5个文件的修复**已应用在当前工作区**。menu_music和menu_interactions_test原本未跟踪，menu本来就有大量首页改动；为遵守“不混合提交”，本次发布仅包含诊断工具、记录、精选证据与针对开工快照的修复增量补丁，**不把整份旧首页/BGM基础混入提交**。远端收到补丁不等于产品源码已经接入，也不等于完整首页可试玩。

增量：`showcase-ogg-fix-evidence-20261024/menu-ogg-exit-fix.patch`。前后原字节SHA、行数及补丁SHA：同目录 `repair-manifest.json`。补丁和隔离应用副本按标准LF生成；独立临时Git仓库apply --check退出0，应用后5文件文本逐项匹配。现场CRLF/LF保持各自原状。发布补丁的空白上下文行按统一diff格式保留，不能把原始补丁空白当成产品代码错误。

回退仅恢复 `godot-logs/ogg-fix-20261024/` 中5份本轮before快照，须先核对当前after哈希，避免覆盖后续编辑；禁止reset/clean或恢复整棵旧工作区。其余既有修改、未跟踪素材及原红证据保护。

暂存白名单审计31项，没有暂存上述5个产品/既有测试文件。代码、文档和JSON的暂存diff空白检查退出0；全量检查退出2，全部命中修复补丁本身的统一diff上下文（前置空格与tab、空上下文行及补丁尾部上下文），原格式保留。没有把全量检查写成通过。

精选JSON、原字节engine日志副本（扩展名txt）和汇总位于 `showcase-ogg-fix-evidence-20261024/`。完整原证据仍在 `godot-logs/ogg-exit-20261024/`；实际CLI测试图 `ogg-real-menu-cli-green-01.png`在该目录，旧menu.png按原字节备份并恢复。

## 当前状态与直接下一步

C：现场修复已实现；T：本轮受影响音频路由/清理专项通过，红例及超时负对照保留；U：未真人听感/体验验收。绕过协调直接SceneTree.quit或强杀进程仍无异步回收保证；没有声称穷尽历史所有偶发音频问题。

本轮普通push因Git凭据助手路径执行错误失败，最终提交/远端结果以收尾回执为准，不改系统网络/代理/认证配置。额度窗口已刷新，最新读取剩余83%，继续保留“剩余1%暂停”的约定。

下一步：先核对最终提交与远端回执；继续整单时从旧UI契约迁移（HOME-10台体名、专用拾取层、稳态交互等待）开始，随后补未完成的尺寸/CLI回归与成功录像。不要重复本轮绿色音频测试或已通过性能/展台专项。完整首页依赖发布应作为独立白名单工单，不与修复增量混提。
