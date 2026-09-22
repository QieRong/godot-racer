# P0 验收契约修复实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**目标：** 消除审计发现的 P0 验收与文档漂移问题，使启动器不会把缺失环境误报为通过，并为全量验收输出可追溯的版本信息。

**架构：** 不改赛车物理、赛道几何或 `LevelConfig` 结构。启动器继续以 PowerShell 为入口；为 `parse-check.ps1` 增加显式“允许缺失”的开关，并以 Pester 直接执行脚本验证退出码。全量 runner 以已有 `--check=aidiag` 为核心检查之一，打印并记录启动时的 Git HEAD 与工作区状态。

**技术栈：** Godot 4.4.1、GDScript、PowerShell 7、Pester 3.4、Git。

**依据：** `D:\桌面\DSH-Work\godot-racer-audit-2026-09-21.md`；用户已确认执行方案 A。

## 全局约束

- 保留用户当前未提交的 `godot-racer/AGENTS.md`，不得修改或暂存它。
- 默认缺少 Godot 或 Godot 工程必须返回非零；仅 `-AllowMissing` 可返回成功跳过。
- 不改变 Task 15 的 `racing_line.gd`、`ai_opponent.gd` 与现有阈值。
- `aidiag` 必须由真实 `run-check.ps1` 调用，而非文本伪造。
- 文档中的通过记录不得宣称为本次结果，除非实际运行得到新证据。
- `.bat` 文件本轮不修改，保留 CRLF 与 ASCII-only 约束。

## 审查重点

1. 传入不存在的工程路径时，`parse-check.ps1` 必须失败，不能因“跳过”返回 0。
2. 本机不存在 Godot 时，只有明确给出 `-AllowMissing` 才能成功跳过。
3. 全量 runner 的 `aidiag` 必须使用真实检查日志中的成功标记判定。
4. 版本输出必须区分干净工作区、脏工作区与非 Git 工作区，不能把三者都写成同一种“通过”。
5. README、`docs/testing.md` 与文档检查脚本的测试数量必须同源一致。

---

### 任务 1：修复 `parse-check` 的假绿并建立回归测试

**文件：**

- 新建：`04-Godot启动器/tests/parse-check.Tests.ps1`
- 修改：`04-Godot启动器/parse-check.ps1`

**接口：**

- 消费：`parse-check.ps1 -Project <path>`。
- 产出：`-AllowMissing` 开关和可选 `-GodotPath`；缺 Godot/工程时默认退出码 `2`，显式允许时退出码 `0`。

- [x] 先写 Pester 失败用例：不存在工程或显式指定不存在 Godot 时，默认模式均返回 `2`。
- [x] 运行 Pester，确认当前实现错误地返回 `0`。
- [x] 最小修改 `parse-check.ps1` 的参数与缺失分支。
- [x] 重跑 Pester，确认默认失败和显式跳过均通过。

### 任务 2：把 `aidiag` 纳入全量验收并绑定版本信息

**文件：**

- 新建：`04-Godot启动器/tests/run-all-checks.Tests.ps1`
- 修改：`04-Godot启动器/run-all-checks.ps1`
- 修改：`04-Godot启动器/check-docs.ps1`
- 修改：`04-Godot启动器/check-readme.ps1`

**接口：**

- 消费：`run-all-checks.ps1 -Only <check>` 与 `run-check.ps1 -Check aidiag`。
- 产出：全量 19 项、快速 15 项；汇总包含 `Git HEAD`、工作区状态和每项结果。

- [x] 先写 Pester 集成用例：用临时启动器夹具执行 `-Only aidiag`，验证真实子脚本被调用且 Git 信息写入汇总。
- [x] 运行用例，确认当前 runner 不识别 `aidiag`。
- [x] 最小修改 runner：加入慢速 `aidiag`，通过 Git 查询提供可追溯信息；无 Git 时明确标为不可用。
- [x] 两个文档检查脚本已从 runner 动态读取 19/15，无需改源码；文档将在任务 3 同步，并已运行 Pester 复核。

### 任务 3：同步产品与 Task 15 文档

**文件：**

- 修改：`data/levels/level_4.tres`
- 修改：`docs/plans/task15-ai-corner-speed.md`
- 修改：`docs/testing.md`
- 修改：`../README.md`

**接口：**

- 消费：实际 `ai_opponents = 1`、当前 HEAD 的 Task 15 三个实现提交、`aidiag` 正式判据。
- 产出：L4 文案为 1 台对手；Task 15 的唯一正式行为判据与实现/验证状态分离；所有套件计数一致。

- [x] 修改 L4 文案，不改变 `.tres` 字段或 AI 数量。（`3 台对手` → `1 台对手`，`ai_opponents` 保持 1）
- [x] 将 Task 15 的旧 v2 草案和冲突阈值标为历史证据，只保留当前 `aidiag` 的正式判据。
      （文件头写清「实现已完成 / 验证缺 commit 绑定」；§〇 订正 3 的 ≥80% 标为被取代，新增订正 4；
      `engineering-notes.md` 第 57 条与 `phase2-elevation-pipeline.md` 任务 15 行的旧口径同步标注）
- [x] 更新 README 与测试文档的 19/15 数量、Task 15 状态与版本证据口径。
- [x] 运行 `check-docs.ps1` 与 `check-readme.ps1`。（两者均 `✔`，退出码 0）

### 任务 4：验证与交付

**文件：**

- 修改：仅任务 1–3 的文件。

- [x] 运行 `lint-gdscript.ps1` 与 `parse-check.ps1`。（lint 三类检查 ✔；parse-check 退出码 0）
- [x] 运行 Pester 启动器回归测试。（`Invoke-Pester 04-Godot启动器/tests`：**4 passed / 0 failed**，20.0s）
- [x] 运行 `run-all-checks.ps1 -Only docs,readme`，以及 `run-check.ps1 -Check aidiag`。
      （docs ✔ / readme ✔；aidiag ✔ 退出码 0，读数见 `docs/testing.md` 的「一次带版本绑定的实测」）
- [ ] 检查 Git diff、未追踪文件与本地密钥的追踪状态；确认 `AGENTS.md` 未被本次修改。
      （⚠ 本次**只改文档与 `.tres`**，未触碰 `AGENTS.md`；但工作区里 `godot-racer/AGENTS.md` 是
      **任务 1/2 之前就有的未提交修改**，不是本次产生的）
- [ ] 报告实测结果与未处理的 L4 AI 静态障碍卡死问题。
