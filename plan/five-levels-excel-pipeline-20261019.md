# ENG-2026-10-19-02 · 五关 Excel 单一真相源 + .tres 生成器设计（v1.0 · 2026-10-19）

> 状态：**设计定稿待实施**（本文只做设计 + 工具链契约；未写生成器代码、未改任何 .tres）。
> 基线：HEAD = `0cb669d`（= origin/main）。脑力活授权背景：GPT 额度未恢复，原「设计归 GPT」的
> 五关数值设计由本机承接，数值档走「先 1:1 回填」路线（用户 2026-10-19 拍板）。
> 实测依据：`godot-racer/scripts/level_config.gd`（156 行，31 个导出字段）、
> `godot-racer/data/levels/level_1..5.tres` 全量字段对比（24 字段被序列化）。

---

## 0. 结论速览

| 问题 | 结论 |
|---|---|
| 为什么做 | 5 个 .tres 全靠手维护，同一组参数要同时改 `radius_x` 和 `layout` 字符串两处（实测 5 关皆是），已现双真源漂移风险 |
| 真相源怎么摆 | `level_config.gd` = **字段契约**真相源（唯一）；Excel = **数值**真相源（新增）；`.tres` 降级为**生成物**（禁手改） |
| 生成方向 | 严格单向：Excel → .tres。反向只允许「只读导出」用于回放验证，且禁止回写 |
| 先红素材 | 回放验证：现 5 关 → 反填 Excel → 重生成 → 与现状逐字节一致（不一致即 TDD 红，也是生成器契约的验收判据） |
| 最大坑（实测） | Godot `.tres` **只序列化非默认字段**（5 关均未写 `ground_texture` 与 3 个 `reverse_*`）——生成器必须复刻该规则，否则产物与手写件必有 diff |

---

## 1. 七维定义（Excel 列组）

「七维」= `level_config.gd` 的 6 个 `@export_group` + 第 7 维「派生校验列」（Excel 公式层，不落 .tres）。

| 维 | Sheet 列组 | 字段 | 说明 |
|---|---|---|---|
| ① 身份 | A–D | display_name / difficulty / blurb / suggested_speed_kmh | difficulty 为 free-text，建议枚举约束写进维7校验 |
| ② 几何 | E–N | radius_x / radius_z / road_width / checkpoint_count / start_finish_t / s_curve_amplitude / s_curve_waves / closure_mode / min_corner_radius + **layout（派生列，禁手填）** | 见 §2 派生规则 |
| ③ 规则 | O–Q | laps_to_finish / ai_opponents / ai_speed_scale | |
| ④ 障碍 | R–T | obstacle_count / obstacle_kind / dynamic_obstacle_count | |
| ⑤ 提示 | U–W | reverse_speed_threshold_kmh / reverse_angle_enter_deg / reverse_angle_exit_deg | 默认值不进 .tres（§3） |
| ⑥ 环境 | X–AB | weather_type / friction_multiplier / is_night / fog_density / ground_texture | ground_texture 留空走约定路径（`_level_index` 推导），**不入 Excel** |
| ⑦ 校验 | AC+ | 一致性/范围公式列 +  verdict | 不进 .tres，Excel 内机器判定 |

---

## 2. layout 派生规则（消双真源的头号项）

实测 5 关的 `layout` 与椭圆参数并存且数值同步：

| 关 | layout 字符串 | radius_x:z | amp:waves |
|---|---|---|---|
| 1 | `ellipse:320:200` | 320:200 | 0:3 |
| 4 | `ellipse:340:220:4:18` | 340:220 | 18:4 |
| 5 | `ellipse:230:150:5:26` | 230:150 | 26:5 |

规则：`layout = "ellipse:{radius_x}:{radius_z}"`，当 `s_curve_amplitude > 0` 时追加 `":{waves}:{amplitude}"`（波的顺序 = 先 waves 后 amplitude，以 level_4/5 实测格式为准）。

- Excel 中 **radius/amp/waves 是可编辑列，layout 列是公式列**（生成器亦按同公式生成）。
- 若手填 layout 与公式不一致 → 维 7 verdict FAIL，拒绝生成（fail-fast，对齐「不得为变绿放宽判据」）。
- 非 ellipse 段 DSL（阶段 3 的路段设计）未来进入时，layout 列升级为可编辑 + 附带 DSL 解析校验列。

---

## 3. .tres 序列化契约（生成器必须复刻的 5 条）

1. **只写非默认字段**：默认值（如 `ground_texture = ""`、`reverse_*` 三值、`ai_speed_scale = 0.9` 恰 5 关全同）不落盘；判据 = `level_config.gd` 的字段默认值表（生成器启动时从 .gd 解析，不复制第二份）。
2. **字段顺序 = .gd 导出声明序**（level_3.tres 实测即此序，勿按 Excel 列序）。
3. 数值写法：float 带 `.0`（`40.0`）、int 不带（`18`）；bool 为 `true/false`；String 带双引号。
4. 头部固定三行：`[gd_resource ...]` / `[ext_resource ...]` / `[resource]` + `script = ExtResource("1_cfg")`。
5. 文件尾保留一个空行（level_3.tres 实测如此，逐字节比对时计入）。

---

## 4. 工具链设计

```
tools/levels_xlsx_to_tres.py        # 主生成器（Excel→.tres，单向）
tools/levels_tres_to_xlsx.py        # 只读反填（回放验证用，不回写）
plan/five-levels.xlsx               # 数值真相源（本设计落地时由反填脚本产出）
godot-racer/data/levels/level_*.tres# 生成物（git 继续跟踪，但 README 标注禁手改）
```

- 依赖 openpyxl（本机 Python 环境验证可用后写入工具头注）。
- 生成器 `--check` 模式：反填 → 重生成 → 逐字节 diff，exit 0/1。这就是 AC-13 之外的「契约等价」机器判据。
- 纯函数核心（解析默认值/派生 layout/序列化）与 IO 分离，便于 Pester/pytest 级单测（先红 8+ 断言：layout 派生、非默认过滤、序列化格式、verdict 规则）。

## 5. 与验收/闸门的关系

- 本工具不动任何 `scripts/`/`scenes/`，不问两道文档闸门事；新增 `tools/*.py` 不在 ≥1000 行约束面（Python 工具，无 godot-logs 扫描依赖）。
- 落地顺序：先 `--check` 绿（回放一致）→ 再开放「改 Excel 数值 → 生成 → `run-all-checks.ps1 -Quick` 回归」的调档流程。
- 调档纪律（GPT 额度恢复后同样适用）：数值改动 = 改 Excel 一个格子 + 跑回归；**禁止直接编辑 .tres**。

## 6. 待实施清单（按 TDD）

1. 红：写 `levels_tres_to_xlsx.py` + 比对器（现 5 关反填 → 重生成 → 预期字节一致，先证明可行再写生成器）。
2. 红转绿：`levels_xlsx_to_tres.py`（含上述 5 条序列化契约 + 维 7 verdict）。
3. 回归：`lint-gdscript.ps1` → `parse-check.ps1` → `run-all-checks.ps1 -Quick`（数值 1:1 回填，预期 15/15 全绿不变）。
4. 文档：README/AGENTS 标注「.tres 为生成物，数值改 Excel」——注意此改动若涉及 `godot-racer/docs/*.md` 会进闸门扫描集，措辞避开「全部 N 项」与带前缀反引号路径两类误伤。
