# 项目文档入口

首次了解或试玩请读仓库根目录 [README](../README.md)。

## 当前实现与待验收

- [取消小地图、M绑定与README重写](minimap-取消与README重写-20261025.md)：最新界面改动、专项结果及待真人复看内容。
- [完整首页依赖与间距修正](showcase-完整首页依赖发布-20261025.md)：首页接线、BGM、白名单及已知编辑器诊断。
- [玩法设计](../godot-racer/docs/portfolio-design.md)、[测试说明](../godot-racer/docs/testing.md)、[工程笔记](../godot-racer/docs/engineering-notes.md)：持续维护的项目说明。
- [开发契约](../AGENTS.md)：C/T/U边界、工作区保护及修改规则。

## 保留的专题来源

| 主题 | 正式记录 |
|---|---|
| 比赛时钟与恢复验证 | [计时修复](review-r6-clock-20261021.md)、[场景补验](review-r6-resume-20261021.md) |
| 圈钟诊断 | [诊断报告](countdown-clock-diagnosis-20261022.md) |
| 圈钟判据拆分 | [批准范围与结果](countdown-clock-split-20261022.md) |
| 倒计时/圈钟音频回收 | [专项报告](countdown-audio-drain-20261022.md) |
| 首页展台 | [设计方案](Godot_Racer_首页展台交互与入场动画_实施计划_2026-10-23.md)及相应showcase专题 |

历史报告记录当时的版本与失败，不能直接作为当前通过结论；未完成工单、证据包、红日志和许可证继续保留。

## 2026-10-25 文档精简

移除根目录4份无入站引用、已被上述专题接管的暂停提示：HANDOVER-2026-10-21-R6、HANDOVER-2026-10-22-AUDIO-DRAIN-PAUSE、HANDOVER-2026-10-22-CLOCK-DIAGNOSIS、HANDOVER-2026-10-22-CLOCK-SPLIT（原扩展名均为.md）。正式报告、测试和日志未删除。

原文可从提交 `d95cd3e` 恢复，本机逐字节备份与清单位于godot-logs/docs-cleanup-20261025/。其他预先修改、删除及未跟踪文件没有纳入这次清理。
