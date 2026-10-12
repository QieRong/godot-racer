# ADR-001：main.gd 永久居民（分派表 / 计数常量 / 入口签名）

- Status: Accepted（2026-10-12，决定人：用户）
- 关联：ARCH-MAINGD-001（main.gd 只读架构分析）；AGENTS.md §18（"大规模重构 main.gd" 属 Review-first）
- 事实基线（2026-10-12 针对性复核）：main.gd 共 6171 行；`match _check:` 位于 L416，当前 26 个检查项

## Context

godot-racer/scenes/main.gd 达 6171 行，需拆分（ARCH-MAINGD-001：函数体可迁出；第一步最小动作 = L246-382 环境/天气整块 → scripts/environment.gd，唯一调用点 L239、零共享成员）。但两道文档验收闸门直接对 main.gd **原文**做正则解析，不认 AST、不认 GDScript 语义：

1. `04-Godot启动器/check-readme.ps1` L57-86：`IndexOf('match _check:')`（L67）定位分派块，截取到下一个 `^func` 前（L71-73），用 `(?m)^\s+"([a-z][a-z0-9_]*)":`（L74-75）解析检查项名（当前 26 项），并反向要求 README 以反引号提到每一项（L80-84）。
2. `04-Godot启动器/check-docs.ps1`：L47-51 显式登记表（LAYOUT_ELEV_CASES 期望 10 / LAYOUT_RACING_CASES 期望 6 / REVERSE_CASES 期望 6）+ L59 正则 `const\s+<NAME>\s*:=\s*(\d+)` 从 main.gd 原文取值；L114-119 再解析 `match _check:` 块核对 run-all-checks 注册项。

## Decision

main.gd **永久保留**以下三样，任何拆分方案不得迁出：

1. **`match _check:` 分派表**（L416 起，当前 26 项）。两道闸门直接解析它；检查函数外移后若分派表随迁，闸门立即假红（报"找不到 match _check: 分发块（结构变了？）"或"解析不出检查项（分发格式变了？）"）。
2. **三个计数常量**：`LAYOUT_ELEV_CASES := 10`（L4801）、`LAYOUT_RACING_CASES := 6`（L4948）、`REVERSE_CASES := 6`（L5330）。check-docs.ps1 L47-51 登记、L59 正则从 main.gd 原文取值；常量迁走即报"找不到常量（改名了？）"。注意：main.gd 另有 `LAYOUT_TARGET_CASES := 9`（L5096）但闸门未登记——本 ADR 只约束闸门登记的这三个。
3. **`_check_*` 入口函数签名与分派关系**：函数体可迁出（目标 scripts/checks/），但 match 条目 → 入口的调用关系不能变。如实注明：**闸门并不解析函数签名**，此条是架构约束（保证分派表可读、diff 可审、checks 族最后迁时仍有稳定锚点），非闸门约束。

## 为什么必须保留

check-docs.ps1 与 check-readme.ps1 均以 `Get-Content -Raw` 读 main.gd 原文做正则匹配。分派表/常量一旦随函数外移，闸门不会"放过"，而是假红或中断（check-docs.ps1 L115 在 IndexOf 失败时 Substring(-1) 直接抛异常）——验收流程被卡死，且报错信息指向"结构变了"而非真实原因，排错成本高。

## 未来迁移路径

若确需迁移分派表/常量：**先改闸门脚本，再改 main.gd，两步分开提交、分开验收**。闸门脚本迁移（如改 AST 解析或显式清单）是独立任务，不属于本次 main.gd 拆分范围；闸门改造完成并单独验收前，main.gd 上述三样不动。

## Alternatives Considered

- **闸门改用 AST 解析或显式登记表**：更稳健，但需引入 GDScript 解析依赖或维护第二份真相源；且 check-docs.ps1 L42-46 注释表明"登记表写在脚本里"正是有意为之的提醒机制。列为未来独立任务，本次不做。
- **分派表迁至 scripts/checks/dispatch.gd 并同步改两个闸门**：改造量与假红风险高于收益，否决。

## Consequences

- 本次拆分边界：函数实现可以搬走，分派表和三个计数常量不能搬。
- 防呆目的：防止三个月后有人看到 main.gd 里还留着分派表，以为是"没拆干净"而去动它——本 ADR 即该行为的否决依据，改动须先走"改闸门 → 改 main.gd"两步流程。
- main.gd 行数不会因本 ADR 下降；拆分收益取决于函数体外迁进度（环境/天气整块先行，checks 族最后迁）。
