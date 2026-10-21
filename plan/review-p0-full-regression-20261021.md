# P0 · 全量回归记录（2026-10-21）

状态：**60 FPS 全量 20/20 通过、exit 0；120 FPS 19/20、exit 1，phys 真实失败**。

## 版本与实测口径

- Windows / Godot 4.4.1-stable official / Jolt Physics，物理固定 120 Hz；图形 runner 串行运行。
- HEAD `01122dfb69b89e9fafc9f1f897c383bbe5dede6e`，加原有脏工作区与本轮默认冻结带接入。不是干净提交、换机器、Windows 导出包或真人验收。
- 每项沿用现有 `run-all-checks.ps1` / `run-check.ps1`；未修改检查项、阈值或控制律。全量为 20 项（2 文档 + 18 引擎），Quick 仍是 15 项。

| 批次 | 最终结果 | 退出 / 边界 |
|---|---|---|
| 原沙箱 full60 | enclosure 被判失败，后续到 minimap 附近由本轮中止，未完成全量 | exit -1；不能计为全量通过 |
| 正常权限 enclosure 环境探测 | COMPLETE、零失败 | process / runner 0 / 0；仅环境探测，启动时与原测试收尾有重叠，不能作为正式串行物理验收 |
| 正常权限 full60 | **全部 20 项通过**；18 个引擎最终 OUTCOME 均 COMPLETE、零失败、断言数自洽、FPS 绑定正确 | **runner 0**，归档引擎日志无 ERROR / SCRIPT ERROR 行 |
| 正常权限 full120 | **19/20，phys (L5) 失败**；其余含 aidiag、stress、L4/L5 opponents、lap 均通过 | **runner 1**；phys 最终 COMPLETE / 1 FAIL，不能计为全量通过 |

正常权限全量两批启动前确认无其他游戏进程，保留用户编辑器（识别 `--editor` 与 `-e` 两种参数）。两批之间核对冻结带绑定的六个源文件原始 SHA256 未变化。

### 新红项：120 档物理步频

`env_phys.gd::run_phys()` 原规则为最低实际物理步频 ≥ 120−2 = **118 Hz**。full120 实测最低 **117.176148560608 Hz**，平均/峰值物理读数 8.26/11.92 ms，最终失败断言 `env_phys.run_phys.002`。full60 为 **119.96461043992 Hz**，物理读数 6.29/7.63 ms。前后均为两台车、8 个轮子、3 个赛道静态体。

这是测量完整的真实性能失败，不是初始化未完成。现有日志不足以区分渲染负荷、机器波动或其他原因；不凭单次结果改物理代码或阈值。拟做一次独立 120/60 对照，使用新日志名保留结果；用户最新第四关门架反馈先作尺寸/取景核查，对照尚未执行。首轮 full120 永久保持红，不因后续复跑销号。

## 失败证据与限制

沙箱首跑出现 user:// 缓存/配置目录不可写等环境错误；enclosure 虽有 COMPLETE/零失败，却被 runner 判红。现有 run-all 不保留子 runner 的完整 stdout，因此首跑未保全该项真实进程数值，不补造退出码或把它归咎为单一原因。后续正常权限通过只证明该次运行成功，不能证明历史所有崩溃都是权限问题。

首跑日志、旧检查日志、中止说明、环境探测与正常权限日志分别保存，不能拿正常权限结果覆盖原失败档案。历史结算 `0xC0000005` 仍未定位；音频生命周期修复与其因果关系未建立。

AC-13 的固定 18-run（多轮 lap/opponents）矩阵仍未执行；不能用 full20 的单次覆盖替代。90 分钟真人 U、音频听感、五关驾驶与新 Windows 包也仍未验。

## 证据与复跑

本节原始文件统一封装在 `godot-logs/review-p0c-20261021-verification-evidence.zip`，附 SHA256；全量失败也包含在内。

- `godot-logs/review-p0c-20261021-normal-full{60,120}.runner.log`：完整父 runner 输出。
- 同名前缀 `.runner-exit.txt`：真实父 runner 退出码。
- 同名前缀 `-checklogs.zip`：各批结束立即封存的 18 份原始引擎日志，防止下一批覆盖。
- 同名前缀 `-audit.json`：只读审计，核对最终 OUTCOME、ASSERT、RUNID 中 FPS/物理档位及原始日志 hash。
- `review-p0c-20261021-audit-full.py` 为日志审计脚本，不启动引擎、不改生产规则。
- `review-p0c-20261021-full60-runtime-bindings.json` 为六个绑定文件原始字节核对记录。

各子进程真实退出由已有 run-check 检查；run-all 要求子 runner exit 0 才能记通过。因为现有全量脚本只打印子结果，逐项退出证据通过该控制链与最终全量退出关联，不另造未保存的子 stdout 收据。

从仓库根目录复跑前先封存 `check*.log`，使用新的父日志名：

```powershell
pwsh -NoProfile -File ./04-Godot启动器/run-all-checks.ps1 -RenderFps 60
pwsh -NoProfile -File ./04-Godot启动器/run-all-checks.ps1 -RenderFps 120
```

物理测试须串行，不同时运行游玩、另一个专项或重任务。若沙箱无法写用户配置目录，使用经过授权的正常权限运行，不放宽游戏判据。
