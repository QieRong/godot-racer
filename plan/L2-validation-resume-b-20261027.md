# L2 随机组合续作 B：补齐玩家比赛与回归

用户于2026-10-27明确要求按上一轮建议继续，机器验证与修复收尾后再集中真人体验。当前工单为 L2 随机坡度/障碍验证；不将其余四关随机化或真人U记为完成。

- 基线：候选为无Git元数据的源码快照；原仓库HEAD `9bd956dabe286a12671008d23a8c244effe150c6`，本次只读查询远端main `1b5227d718ecdf64a991861cb9af427a447a4636`，暂存空，原混合改动与未跟踪文件保留。
- 目标：九组合玩家正式Input比赛及真实AI的必要双档验证；独立核对逐门、车身、位置/弧长、高度、障碍接触。先跑组合0、4，任何失败停队列定位。
- 新增只读接触观察测试 `tests/variant_player_test.gd`，沿用原玩家驾驶控制、正常比赛与结算；不改车辆、AI策略、几何核心或阈值。
- 独立APPDATA/LOCALAPPDATA，物理120Hz；真实渲染60/120目标档不带fixed-fps，不宣称持续目标帧率。
- 并列调查L1旧贴墙失败，先保留原判据并测量世界AABB与直接变换局部八角点的差异；未经证据不修改旧测试。
- 补跑旧check=lap同口径、必要回归；原始失败、证书/资源诊断均保留。不运行旧打包收尾脚本，不逐轮导出、不重冻、不上传。
- C/T/U：C已有；T进行中；U待用户集中体验。源码验证结果归档到控制目录 `random-upgrade-20261027/evidence/resume-source-20261027-b`。

风险：旧贴墙失败、旧lap未闭环、完整回归/AC-13、持续FPS、长期稳定性和外机尚无完整证据。发生核心公式或体验规则取舍时按项目契约单独处理，不能放宽判据制造通过。

## 本轮已取得的证据（滚动记录）

- `player-combo-{0,4}-rendered-{60,120}-resume-b`：四次均8/0、exit0，独立轨迹与高度通过，玩家和AI路障接触均0，玩家恢复0；均为真实Compatibility渲染目标档，非持续FPS或真人U。
- L1旧wallslide并列只读观察：世界轴对齐包围盒最大11.6241m；局部包围盒八角点直接变换投影最大10.3205m，原边界10.57m。原12个驾驶用例均能继续开。
- 有效投影红例 `projection-unit-valid-red-resume-b`：解析几何应为9.3m，旧方法测成11.0m，1/2、exit1。修正 `scripts/checks/env_phys.gd` 的投影顺序后 `projection-unit-green-resume-b` 2/2、exit0；实际越界5cm反例仍拒绝。阈值、车辆与护栏规则未变。可复用测试在 `tests/env_visual_projection_test.gd`。
- `wallslide-L1-correct-projection-resume-b`：原专项12/12，原始OUTCOME失败断言0、exit0；复用项目原 `Get-CheckResult` 判定器通过。原judge包装器读取timed_out而runner输出timeout，采用外部适配器读取实际字段，保留原receipt与判定器。
- `tests/check-track-trace.py` 只纠正图表标题：实际actor与道路Y范围；原先固定“Real AI/flat”不适用于玩家/坡道。轨迹判定算法与阈值未改。
- 无日志路径的直接check-only发生启动期signal11；后读项目解析脚本确认必须传log-file。独立APPDATA且带日志的正式测试正常。首个投影红夹具因过早preload导致GameState不可见，已保留并终止，不计有效红；延后load后取得有效红例。
- 本轮读取两道文档闸门均exit0；完整lint及最终源码绑定仍需收尾核验。所有初始失败与证书/资源诊断保留。

## 用户追加：雨夜路灯与五关开放边界

用户要求左右路灯对称朝道路内部、真实照亮路面，并确认五关隐藏高红色围挡，保留原位空气墙，增加间隔低矮反光桩。该视觉工单依次完成后才恢复串行物理矩阵；不更改路宽、碰撞、车辆或AI核心。

- `track_scenery.gd`：路灯成对布置，右侧旋转180度朝内，雨天路面roughness调整为0.72；添加路灯池与反光桩子模块。
- `street_lighting.gd`：最近8盏无阴影真实聚光灯，每0.2秒随车辆更新，场景释放时回收。
- `environment.gd`：雨夜使用明确的基础环境光0.65及日光0.20，保留夜色。
- `track_generator.gd`：仅默认隐藏Guardrails视觉，保留诊断显示开关；原AirWall和RoadBody生成未改。
- `boundary_delineators.gd`：约24米间距、0.72米高暗色杆与红白反光带，直接使用原空气墙横向位置；只有MultiMesh视觉，无新增碰撞。
- 路灯有效红例 `street-light-valid-red-b-resume-b` 保留；修复后最终 `street-boundary-final-gl-resume-b`（Compatibility）与 `street-boundary-final-forward-resume-b`（Forward+，候选godot-logs/five-fixed内）均9/0、exit0。106盏模型全部朝内、镜像完整、8盏真实灯瞄准有效、随车更新和释放通过。720p/1080p截图已生成，真人感受未验收。
- 五关原红例 `boundary-five-red-resume-b` 10/15；最终真实渲染 `boundary-five-realrender-a-resume-b` 25/0、exit0、源码无漂移。所有实际桩位置通过射线与原空气墙匹配；五关均保留红白路缘且无新增碰撞体。
- 逐值比较改前后五关 `road_collision` / `wall_collision` SHA256与road_width/wall_half/length完全一致。无窗口dummy后端读取MultiMesh实例变换得到单位矩阵，导致早期两次射线检查20/5；原记录保留，真实渲染读回定位成功，未放宽0.2米位置阈值。
- 最终画面与碰撞检查仅证明本工单对应行为；不是完整性能、AC-13、外机或真人U。证书读取错误仍保留。

旧45米追线L2三圈专项已按Forward+、60/120目标档重跑，均exit0、原判定器严格通过；不把此专项称为真实AI验证。初始四次玩家比赛发生于本视觉工单之前，分版本记录，不能混称同一最终源码的18次矩阵。

## 本轮交接时的最新状态（覆盖前述八灯阶段）

最终真实路灯池改为4盏，单灯亮度和环境光保持。`street-four-light-final-visual-resume-b` 9/0、exit0，源码无漂移，720p/1080p截图已生成并检查。五关边界与原碰撞一致，用户尚未进行本轮真人U验收。

用户随后明确要求修复4个BAT换行并push、更新README。四个BAT仅转换为CRLF，逐字节证明其余内容和编码不变；最终完整lint、生产脚本聚合解析、check-docs、check-readme均exit0。原红日志保留。

性能未全通过：最终单进程雨夜Compatibility为119.8Hz，通过原118Hz门槛；四灯Forward+为116.54Hz，失败。雪地Compatibility为116.25Hz，失败；旧固定EXE同机120Hz通过；当前雪地隐藏桩体后117.46Hz仍失败，尚未确定原因。不能将目标帧档写成持续FPS，不能放宽阈值或把exit0当作原断言通过。

早期灯光成本对照含诊断夹具问题：冻结AI但保留控制器会触发自救；另一次空场景夹具超时后，启动器没有清掉GUI子进程。已终止本轮自建残留进程、补齐fixture装配，并用原生父子进程树清理替代失效taskkill。`timeout-tree-proof-resume-b` 为故意超时红例，确认两个自有进程均终止、无源码漂移。残留窗口期间的组件对照不作性能归因；所有原日志保留。

用户要求快速收尾并新开对话，因此本轮不再开始耗时矩阵，也没有再次导出EXE/ZIP。L2真实渲染AI九组合×60/120的18次矩阵尚未开始；玩家矩阵已有组合0/4四次通过（早于最终视觉源码），其余14次待跑。现有暂停门和失败前置条件保留，先定位天气性能差异，不能直接删门伪造完成。

原仓库最终HEAD/status/暂存输出与开工逐字节一致，原HEAD为9bd956d；远端读取时main为1b5227d。候选工程内车辆、AI、关卡配置、随机catalog和冻结相关文件与本轮开工哈希一致；本轮改动GD均≤1000行，唯一历史超限AI为1686行，未增加。固定ZIP SHA256仍为a481ad3ad08a6941a6ba30090cb0e49b02daf407015b0599b919a91cfc3e5d83。

本地原始证据位于 `racer-five-fixed-session-20261026/random-upgrade-20261027/evidence/resume-source-20261027-b/`；证据不随源码push。发布采用独立Git检出，以远端main为底复制候选源码及必要文档，不改原混合工作区、不包含本机导出配置或EXE、ZIP、日志。实际分支与提交以新交接文档为准；push不代表已合入main或通过完整验收。
