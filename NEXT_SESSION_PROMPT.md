# 新对话开场提示（直接复制下方内容）

接手 godot-racer，始终用中文。仓库根 D:/桌面/DSH-Work/data-analysis，Godot 工程 godot-racer/（res://），Godot 4.4.1，路径见 HANDOVER.md。

先读根及工程 AGENTS.md、HANDOVER.md §0/§6/§7/§8/§10、godot-logs/l4-current-report.md、godot-racer/docs/plans/l4-reachability.md、docs/testing.md 最新 L4 段。先核对 Git HEAD/status、远端和生产脚本 blob；不要覆盖、回滚或重复实现现有修改。当前最终内容提交与推送回执以 HANDOVER、push-log 和现场 Git 为准。

已验证的修复内容提交为 d845ff5295bb18b517836cf2810088c7309840d1，之后仅交接文档收尾。实际最新 HEAD 仍要现场读取；不要把后续文档提交当作生产逻辑变化或干净提交复跑。

已完成：L5 BUG-L5-001；L4 AI 曲率跟踪与实测偏差带选道/排队。L4 opponents 三次均 7968帧、零自救；L5 三次10526/10544/10534帧、零自救，均1圈未出界。L1 aidiag通过，Quick15/15、DONE EXIT=0。三份生产 blob 及“工作区实测而非干净提交复跑”的边界见回执，不重跑整个修复流程。

重启恢复发现的三项紧急问题已处理：开发回执不再被中途✔掩盖最终✘（六条先红后绿）；玩家圆弧夹具无脚本错误地稳定跑红；AI有效截图先跨起点再到arc260.47、121.69km/h、0自救。旧误报进度、夹具报错、出生点误拍和中断记录都保留，不能当作通过证据。

下一目标是 L4 玩家自动驾驶：当前 lap 实际卡住3次、疑似复位5次，仍FAIL。正式 autopilot 未改。先评估 godot-logs/l4-autopilot-control-proposal.md：只替换有障碍自动驾驶分支为共享曲率连续输入、速度×时间前瞻，无障碍分支与手动驾驶保留。HANDOVER §6 禁止收紧死区/打舵门限，绕过旧±0.06门限的例外尚未获明确签字；先展示最小具体差异与影响，由我确认后实施，不能默认已有授权。

继续遵守单一真相源、TDD、数值+截图。L4/L5物理验收严格串行，不放宽判据、不删自救、不改关卡数据或用速度篡改造假。后台长任务落独立日志，必须看最终EXIT/DONE。每个完成步骤显式路径git add、提交、fetch（落后先rebase）、push，并核对本地/origin/实际远端。两个Blender中间产物和原工程未跟踪models/environment用户资产包保留、不混入修复提交；忽略的证据用显式git add -f。

按实际任务用 godot-dev-guide、systematic-debugging、TDD、lint-and-validate、code-reviewer、verification-before-completion；收尾用handoff。不因重启重复a_brake测量；雪地100km/h抱死未被默认通过覆盖。雨声接线排在L4之后，用户SoundDino音频不擅换，第三方不套MIT。

WorkBuddy三批资产独立位于 D:/桌面/DSH-Work/godot-racer-assets-staging，8个新GLB+L3湿路材质包，报告见staging/reports/DELIVERY_REPORT.md和DELIVERY_REPORT_BATCH3.md。资产任务对原工程只读，产出只写staging，不自动集成或git写入。风格冻结为硬边平涂、纯albedo、零法线、metallic0、多材质分件；GLB≤5000三角、米制Y-up、底部Y=0、嵌入贴图≤1024²、无碰撞体。既有8个用户GLB不重复造。资产完成须纯Python解析+Godot4.4.1无头导入+运行时实例化退出0；本轮只核对既有报告，未重新实测资产。

请先报告实际完成状态和下一步最小动作，再继续已有授权内的工作。
