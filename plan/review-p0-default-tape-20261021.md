# P0-2 · 默认冻结带接入（2026-10-21）

状态：**默认入口在当前工作区双 FPS 正式回放通过；候选原始字节归档，默认包正式提交等待源文件收口**。

## 输入与边界

- 承接 `e744884` 已归档的首个合法候选；本次没有重新挑选候选、修改输入、控制律、物理阈值、测量窗口或判据。
- 先将现场原 `data/checks/frozen/` 全部文件封装为 `godot-logs/review-p0c-20261021-default-before.zip`，再复制 `godot-logs/resume-20261021b-frozen/` 五个 JSON，逐文件核对 SHA256 相同。
- 新输入仍是 5041 帧，input_tape_hash=`f8dcdb436054342ed3d4258c1dcff7252ac7ee267cad039aad09caf765636072`。校准红项仍为 CALIBRATION_ONLY / 5 条失败，原始全过程在前轮 `resume-20261021b-freeze-evidence.zip`，不改写历史。
- 新增 `data/checks/.gitattributes`：只对 frozen JSON 禁止 Git 文本换行转换，且承认文件已有 CRLF 行尾；否则检出时改写字节会破坏内嵌 SHA256。没有关闭真实空白检查或放宽游戏测试。
- 默认包的 calibration-history 保留原候选名称及哈希；完整候选和日志在前轮 ZIP 中，不伪造为新一轮校准。

## 实测

Windows / Godot 4.4.1 / 图形 runner / 物理 120 Hz；基线 `01122df` 加既有工作区及本次默认带复制。

| 检查 | 最终证据 | 进程 / runner |
|---|---|---|
| 默认 tape-preflight | FROZEN、数据哈希自洽、5041 帧 | 0 |
| 默认 run-check aidiag，60 FPS | COMPLETE、10 条断言、零失败；贴限速 74.2% ≥ 原 60% | 0 / 0 |
| 默认 run-check aidiag，120 FPS | COMPLETE、10 条断言、零失败；贴限速 74.3% ≥ 原 60% | 0 / 0 |
| Git JSON 差异检查 | 原始 CRLF 在固定字节文件中被识别；diff --check 通过 | 0 |

证据前缀 `godot-logs/review-p0c-20261021-default-{60,120}`，包括完整引擎日志、runner 输出及真实退出码。没有借用独立清单参数绕过默认入口。

复跑（新日志名，避免覆盖）：

```powershell
pwsh -NoProfile -File ./04-Godot启动器/run-check.ps1 -Check aidiag -RenderFps 60 -MaxTries 1 -LogName <新名称>
pwsh -NoProfile -File ./04-Godot启动器/run-check.ps1 -Check aidiag -RenderFps 120 -MaxTries 1 -LogName <新名称>
```

**证据限制**：当前 project.godot 的既有 C 后视动作尚未提交；新带的源码字节绑定包含它。不能将此工作区双 FPS 通过说成干净 HEAD / 换机器 / 导出包验收。后续原有 UI/后视/BGM 资产分批收口、Git 换行稳定性核对之后，仍需重新验证绑定，不可手改清单 hash 冒充校准。旧 frozen-superseded-4 和用户其他素材未动。

本轮提交候选原始字节与验证记录的 ZIP，不将这五个 JSON 或换行属性草稿正式提交为远端默认包。现场文件保留，以便后续按实际源码收口后校准/重冻；不悄悄把尚未匹配干净 HEAD 的包发布为可重现基线。全量结果及环境诊断另记主进度报告；严格 C/T/U 12 项的计数不因此直接增加。
