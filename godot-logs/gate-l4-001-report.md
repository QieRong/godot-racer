# GATE-L4-001 验收回执

- 授权：用户批准新增 opponents L4 门禁、分关卡日志、同步文档、独立提交推送；接受既有缺陷如实报红。
- 执行时间：2026-10-14 22:53–23:11（+08:00）；2026-10-15 完成复核与提交收尾。
- 执行基线：`18b2069507f38c14cedc2b986b7f9799f33984f2` + 本批工作区改动。
- 当时工作区：runner、README、testing 三个已跟踪文件有改动，另有两个未跟踪 Blender 中间产物。
  完整状态保存在 validation.log；后续只追加交接/验收文档，生产脚本未再改变。
- 本回执随本批独立提交保存；请使用 `git log -1 -- godot-logs/gate-l4-001-report.md` 获取内容提交号。
  runner 的归一化 Git blob 和原始日志 SHA256 另见 binding.log，可复核最终提交内容与实测版本。

| 验证 | 实测结果 | 证据（本目录） |
|---|---|---|
| 覆盖/失败传播检查，对旧 runner | EXIT=1；19 条断言中 14 条失败 | gate-l4-001-contract-red.log |
| 同一检查，对新增 L4 后 runner | EXIT=0；19/19 | gate-l4-001-contract-green.log |
| lint / Godot 聚合解析 / docs / readme / dup-source | 五项 EXIT=0；解析 31 个 gd | gate-l4-001-{lint,parse,docs,readme,dup}.log |
| Quick | EXIT=0；15/15 | gate-l4-001-quick.log |
| opponents 子集 | EXIT=1；L4 红、L5 本次绿 | gate-l4-001-opponents.log |
| L4 原始样本 | 15984 帧、1 圈、自救 11 次、离中心线 1.35m，FAIL | gate-l4-001-opponents-L4.log |
| L5 原始样本 | 10974 帧、1 圈、自救 0 次、离中心线 0.97m，PASS | gate-l4-001-opponents-L5.log |
| 收尾文档三道闸门 | 见各自 EXIT 标记 | gate-l4-001-final-docs.log |

运行方法（仓库根，PowerShell）：

```powershell
pwsh -NoProfile -File godot-logs/gate-l4-001-contract.ps1
pwsh -File 04-Godot启动器/run-all-checks.ps1 -Only opponents
pwsh -File 04-Godot启动器/run-all-checks.ps1 -Quick
```

覆盖脚本在独立临时夹具中执行真实 runner，模拟引擎子进程，分别注入 L4/L5 红灯；
验证覆盖、重试次数、独立日志、套件退出码及失败关卡标识。夹具会校验绝对路径后清理。
真实 Godot 样本为串行执行，完整日志分别复制为本批前缀，不依赖将来可能被覆盖的默认日志。
全量为 20 行，Quick 仍 15 行，检查入口仍 24 个；新增行延用原 opponents 判据与 slow 标志。

## 复核

- 目的：让 L4 进入日常全量验收，并保留可区分的两关结果。
- 需求符合：L4/L5 各一行；使用 run-check 已有 LogName；任一红灯使套件 EXIT=1；没有改判据。
- 代码质量：未发现阻塞问题或需修正的主要问题；复用现有接口，变更集中于 runner 与相关文档。
- 检查质量：旧 runner 确实跑红；模拟 L4/L5 分别失败均能被抓到；真实 L4 失败可传到总退出码。
- 正向观察：独立日志保留两关原始证据，mock 检查与真实 Godot 执行相互补充。
- 无需用户追加澄清；结论：本批覆盖改动可提交。L4/L5 游戏缺陷保持登记。

## 未解决与边界

- L4 本次已能完成 1 圈，但自救 11 次违反零自救要求；没有因完成跑圈而判过。
- L5 本次通过不能证明 BUG-L5-001 修复，检疫仍于 2026-10-19 到期，不自动续期。
- 本轮未修改 AI、物理、几何、游戏验收断言、超时或重试值。
- 全量 20 行未整套重跑；aidiag、stress、lap 本轮未单独运行，因游戏实现无变化。
- 未新增截图：本轮验的是门禁覆盖与失败传播，没有修改车辆姿态/位置实现，也不宣称缺陷修复。
