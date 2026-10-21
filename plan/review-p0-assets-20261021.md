# P0-2 · 原有资产分批收口核查（2026-10-21）

状态：**已辨别批次与阻断点；原 UI/BGM/展车/后视资产尚未提交，本轮没有将其算作完成**。

## 现场批次

| 建议独立批次 | 现有文件 / 现行说明 | 下一步验收 |
|---|---|---|
| 首页、选关及公共 UI | menu、menu_overlay、ui_theme、homepage；ui-pages 与 ui-home 系列测试/说明 | 当前机器页面专项、两尺寸实际渲染、真实键鼠与 U |
| 实时 3D 展车、菜单 BGM | car_showcase、menu_music、menu_theme.ogg/LICENSE、compose_menu_music；menu-interactions-spec/selftest | 单实例、循环与离场释放；当前引擎真实播放；车型与资源范围、U 听感 |
| C 后视及交互收口 | chase_camera、project.godot 的 camera_rear 输入；menu_interactions_test / interaction_capture | 三视角按住/松开、暂停/失焦、五关驾驶；与冻结源码绑定重新核对 |
| 倒计时既有视觉修订 | start_countdown、对应 UI 说明 | 发车共同入口与五关可读性；新 W/S 试听计划仍为 Planned，不能混同已实现 |

当前最新交互说明已经用独立 SubViewport 实时展车替代旧首页静态车图方案。旧 PNG、渲染工具与历史方案均保留；不能据旧文档直接回退新实现。上述批次存在共享 menu.gd 的依赖，实施提交前应以实际 diff 拆分，不按表格机械覆盖文件。

## 本轮复核与阻断

- 本轮重新运行 `python godot-racer/tests/check-ui-pages.py`：**60 PASS / 1 FAIL，exit 1**。真实日志为 `godot-logs/review-p0c-20261021-ui-source-audit.log` 与 `.exit.txt`。
- 失败为 CD-01 源码保护门：相对 HEAD，scenes/menu.tscn 两行 UID 元数据发生重排（场景 UID 改变，脚本资源补 UID）。其他受保护生产路径本轮没有被 UI 收口改写。该差异仍是失败，不能改检查期望或排除该场景来制造全绿。
- project.godot 的现有差异仅为新增已批准 C 动作，现有 REAR-01 静态断言通过；该配置目前未提交，却已被新冻结带绑定。只有当前脏工作区回放通过，不能推断干净提交通过。
- 原交互自测文档的 287/0 页面专项等为前轮证据；本轮未重新跑整批 UI 动态专项或听感验收。完整回归主要验证比赛核心，不能覆盖所有 UI 验收。
- rain_loop.ogg.import、race_car.glb.import、临时探针、龙门架备份、旧 superseded 冻结目录和被删除的旧交接属于原现场，保留原状，未随本轮提交。

## 后续最小动作

先处置场景 UID 差异并保留本轮失败记录；涉及保护门判据变化必须公开最小 diff、说明影响并按 AGENTS.md §3.1 另行批准，不能静默放宽。之后复跑既有交互与页面专项、检查源码引用与授权素材，按实际依赖分批提交。完成这些源文件收口后再固定源码字节，使用既有校准/冻结流程与全量回归建立干净提交证据；不手改 manifest hash。

90 分钟真人步骤另见 `review-playtest-90min-20261021.md`，结果均为空白待执行。本轮普通推送授权仅涵盖本轮明确列出的音频修复、冻结带和验证文档，不扩大为原 UI/美术批量发布授权。
