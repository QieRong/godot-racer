# Windows 导出链路验收（2026-10-17）

- 基线引擎：Godot 4.4.1 stable；官方导出模板包已按发布页 SHA512 校验并安装到 `%APPDATA%\Godot\export_templates\4.4.1.stable`。模板安装是本机前置条件，不进入 Git。
- 独立临时项目空场景导出后，在项目目录外启动 EXE，日志 `godot-logs/rel-step1-exe-empty.log` 含 `PROBE_EMPTY_READY`。
- 同项目五个 `.tres` 的 PCK 实测：`ResourceLoader.list_directory()` 返回原资源名、顺序稳定、5/5 可加载；`DirAccess` 返回 `.tres.remap`，按这些名字加载 0/5。`godot-logs/rel-step1-pck-enum.log` 包含多轮正反探针，不能把刻意的负对照 `RESULT: FAIL` 当成最终导出失败。
- 正式工程的旧 `DirAccess` 导出结果 0 关，改 `ResourceLoader` 后同机 EXE 枚举 5 关；原始日志分别为 `godot-logs/rel-step2a-pck-red.log` 与 `rel-step2a-pck-green.log`。
- 这些是本机导出链路结果；干净 Windows 机器验收仍待完成。正式交付还须从确定提交构建 ZIP 并重验五关、设置、结算和退出。
