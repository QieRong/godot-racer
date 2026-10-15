# 玩家 L4 自动驾驶：控制分支替换提案（未实施）

需要确认的边界：HANDOVER §6 第 8 条禁止收紧转向死区/打舵门限。
当前 autopilot.drive_track 的有障碍与无障碍路径都通过 side=±0.06 门限输出满幅方向键。
把该分支改成连续轮舵角跟踪会绕过原二值门限，故先明确获得本例外授权，不能偷改数字。

## 具体范围

- 仅修改 scripts/autopilot.gd 的“存在真实障碍”自动驾驶分支。
- 复用 RacingLine.pursuit_steering，把几何所需轮舵角换成 Input.action_press 的连续强度，
  经 vehicle.gd 原有转向权限、响应速度与物理轮胎执行。
- 无障碍分支仍执行原来的 ±0.06 门限；玩家手动驾驶和 vehicle.gd 都不改。
- 有障碍选道前瞻改为 max(原 45m, 速度×3s)，瞄准点仍取调用方原 ahead，不混淆两种距离。
- 抓地、max_steer、方向盘权限、辅助力、自救、恢复、赛道数据、验收判据均不改。
- 先运行真实 drive_track → Input → 玩家转向的圆弧红用例；通过后再加远障碍提前选道用例。
- 只有原判据下 L4 lap 三次冷启动通过并有截图，才标记玩家路径修复；AI 两关继续串行防回归。

## 转向分支的拟议差异

```diff
 Input.action_release("steer_left")
 Input.action_release("steer_right")
-if side > 0.06:
-    Input.action_press("steer_right")
-elif side < -0.06:
-    Input.action_press("steer_left")
+if can_pick and _obstacle_field.obstacle_count() > 0:
+    # 真实目标点 → 曲率 → 轮舵角 → 归一化 Input 强度。
+    # limit 取玩家当前实际转向权限，轮舵角来自共享纯函数。
+    _drive_obstacle_steering(to_target)
+else:
+    if side > 0.06:
+        Input.action_press("steer_right")
+    elif side < -0.06:
+        Input.action_press("steer_left")
```

辅助函数拟使用现有玩家实际轴距、max_lateral_accel、steer_limit 与 roll_guard，
不直接写 steering/linear_velocity、不使用 steer_fixture、不增加力。

这是待签字提案，未修改 autopilot.gd；本文件不代表已经实现或验收通过。
