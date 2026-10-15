# L4 横向规划与跟踪修复

以 HANDOVER §0 为当前状态。原 lap-autopilot-obstacle-avoidance 计划保留历史记录。

- [x] 在 4dbc98a 的 L5 修复上串行重测 opponents L4：15527 帧 / 1 圈 / 自救 9，FAIL。
- [x] 建立真实 AI 转向入口的圆弧红用例：几何所需 -0.01831rad，当前 -0.08214rad，EXIT=1。
- [ ] 最小修正共享曲率换算，保留方向权限、死区、max_steer、抓地及全部自救。
- [ ] 以专项结果决定是否仍需时间制前瞻和可达性限速；不得硬套旧玩家轨迹 0.011m/m。
- [ ] lint → parse → 单项 → Quick，串行复核 L5 与 L1 诊断。
- [ ] L4 opponents / lap 各三次冷启动，原判据不变，数值与真实截图同时留证。
- [ ] 更新报告、testing、HANDOVER、push-log，显式路径提交、fetch、push、三方哈希核对。

新测试是独立工具，不新增 --check 入口、不改闸门或既有阈值。
修复时不改 racing_line 的既有核心公式，仅添加共享辅助函数。
每个逻辑步骤完成即提交推送；失败尝试保留证据且不宣称修复。
