# P0-2-REAR-VERIFY-001：隔离候选专项验证

日期：2026-10-23（Asia/Shanghai）。用户批准仅建立隔离副本、新证据并执行后视专项；不修改原工作区，不提交、不 push，不修改判据或发布冻结带。

## 基线与候选

- 基线 HEAD：`7c6ee5c5543422862a169caf8a03d4da4032b3cd`。
- 引擎：Godot `4.4.1.stable.official.49a5bc7b6`，Windows，headless。
- 两个副本来自 `git archive HEAD godot-racer` 的 Git blob 字节，不复制原工作区的其他 UI、BGM、相机外改动、冻结带或 `.godot` 缓存。该方法是提交源码快照，不是完整 Git 工作树或跨平台干净检出证明。
- 候选只改变 `project.godot`（新增 camera_rear 五行）、`scripts/chase_camera.gd`（现有后视增量）、`scripts/menu_overlay.gd`（仅一行后视帮助）。精确差异为 `production-candidate.patch`；不包含菜单 UID 场景变化。
- 运行材料复制原 `menu_interactions_test.gd`、`interaction_capture.gd` 及其 UID，不改任何断言。本轮只运行前者的 `--interaction=rear` 分支，未执行截图脚本。
- 红绿测试源码 SHA256 均为 `b46325d27ded46f1c66fc8ea792cae7a973239873fff5cb9e1875db3effc18f4`。
- 已提交检查器、UID 判据和本地未提交的 REAR 门均未改动；本轮未运行源码门，不以它替代运行结果。

## 实测结果

| 项目 | 最终断言 | 真实进程退出 | 限制 |
|---|---|---|---|
| 候选 lint | 通过 | 0 | 原 lint 脚本，目标仅隔离副本 |
| 基线 60 FPS 红测 | 0 PASS / 1 FAIL | 1 | 正确拒绝缺失 camera_rear；未进入后续断言 |
| 候选 60 FPS | 24 PASS / 0 FAIL | 0 | 无 SCRIPT ERROR；存在下述 ERROR/WARNING |
| 候选 120 FPS | 24 PASS / 0 FAIL | 0 | 无 SCRIPT ERROR；存在下述 ERROR/WARNING |

两档引擎日志均确认对应 60/120 FPS 设置。每次最终汇总唯一，均有 24 条非空 PASS 回执，未超时；不是通过总进程 exit 0 推断断言通过。基线与候选使用完全相同的原测试源码，没有新增或放宽验收规则。

每次运行保存完整 engine/stdout/stderr 日志和 `.result.json`（命令、实际退出、超时、错误、警告、源码哈希与副本漂移）。`verify.py` 的编排本身不替代逐项结果；外层 Python 正常结束不等于内部所有运行通过。

## 保留的错误与警告

1. 三次 rear 运行均有 `ERROR: Failed to read the root certificate store.`，不能称零错误运行。
2. 候选双档均复现 `Target and up vectors are colinear` WARNING，出现在原竖直翻滚断言附近。该断言仍通过；警告说明存在旋转方向风险，不能直接断言已发生镜头故障，也不能把它隐去。
3. 首轮基线导入 exit 0，但存在编辑器数据/配置目录访问失败、空路径保存和 headless dummy texture 错误，记录原样保留，不算干净导入。
4. 候选导入把 APPDATA、LOCALAPPDATA、TEMP、TMP 重定向到副本内的独立 profile，消除了前述编辑器目录/保存错误；仍有根证书与 dummy texture 错误，不算无错误导入。
5. HEAD 配置启用了未入库的 Godot MCP 插件；副本导入日志报告插件目录不存在。导入使用 `--recovery-mode --import`，没有启动用户现有编辑器或更改原项目插件配置。
6. 两个副本各有 71 个 `.import` 字节变化，已逐个核实均仅为 CRLF/LF；其他初始文件没有漂移。细节登记在运行收据及 `*-import-drift-classification.json`。这些副本生成物未带回原仓库，也不视为已批准发布内容。

## 覆盖与未覆盖

原 24 条覆盖 C 绑定、三视角后视方向、松开恢复、后视期间 V/环视优先级、暂停/失焦解除、恢复输入、真实 InputMap 分发、车辆姿态未被修改及竖直姿态朝向。

未覆盖：新增帮助行的真实排版；非 RACING 阶段的 V 与常规跟随行为完整矩阵；五关驾驶；GUI；真人 U；全量 suite；AC-13；音频听感；新导出包；冻结带校准/正式回放。两档短测试不是物理性能或长期稳定性验收。

候选相机的状态门确实改变了非比赛阶段行为，这部分需要先明确预期并另行批准补充判据；本轮不通过新增断言或修改生产代码扩大范围。

## 工作区保护与状态

原仓库保护结果见 `source-before.json` 与 `source-after-audit.json`：HEAD、完整 status、暂存清单以及原已跟踪/未跟踪文件的逐文件 SHA256 全部未变，包括既有删除状态。新副本和证据均位于被忽略的本目录。原 status 仍为 17 修改、2 删除、50 未跟踪，暂存区为空。

C：仅本地三文件候选已存在，未提交。T：原后视 24 条在隔离候选双档通过，保留全部引擎错误/警告。U：未验。未据此关闭 P0-2、历史 phys、访问冲突或冻结带发布问题。

后续最小动作：确认非比赛阶段相机行为的预期及竖直姿态警告的处置要求，展示并批准相应最小判据后再实施；不直接批量提交首页、BGM、相机和冻结带。

## 复现与归档

`verify.py`、`setup.json`、候选补丁、原始运行日志与逐项收据保留在本目录。`setup.json` 记录导入前副本逐文件哈希。原脚本的 snapshot 字节漂移同时包含导入副产物，不能把 `.import` 漂移误说成生产源码修改。

验证已执行的命令和完整路径见每个 `.result.json`。如需复跑，使用新目录/新 tag，禁止覆盖原日志或固定名截图。证据 ZIP 仅用于本地验证归档，含指定候选/测试源码和日志；不含完整资产或运行缓存，不是独立游戏发布包。

## 用户追加暂停与证据推送授权

上述“未提交、不 push”为验证阶段边界。专项结束后，用户明确要求“可以开始准备暂停收尾了，并push”。本次收尾仅提交本报告、暂停交接和证据 ZIP/SHA256 共四个文件；后视三个生产候选、检查器、本地 UI/BGM/冻结带及所有其他原工作区修改均不纳入。

原始目录：`godot-logs/p0-2-rear-verify-20261023-1233/`。已归档 `evidence/p0-2-rear-verify-20261023.zip`，SHA256=`a1922855b957398c357c538a809e868249c2ac319a49cd003581dc41e149f9c1`；包内47项清单全部逐文件核验，无遗漏。包内原报告保持验证结束时的原始状态，收尾授权由本节补记，不覆盖旧证据。

不再启动新游戏验证；仅完成文档门、精确暂存复核、常规 commit/push及实时远端核验。最终提交以暂停交接、本次提交说明和最终回复为准。

收尾两道原文档门均实测exit0：`check-docs.ps1`、`check-readme.ps1`。收据另存本地原始目录的`docs-closeout.*`与`readme-closeout.*`，执行时间晚于ZIP封存，未声称它们包含在该ZIP中。
