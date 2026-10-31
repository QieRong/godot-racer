# 小地图清理公开副本同步与验证

2026-10-31，基线为公开提交 `123015366524d543b1f85bdab2611097fa62bb5a` 加本批白名单改动。继续使用 E:/godot 下的 Godot 4.4.1。本文记录工作区验证，所在提交产生后未对干净提交另跑一遍。

将已批准的地图实现/UID删除、HUD与专用接口清理、主场景接线、生产调度退役及对应测试同步到公开副本；校正AI发车/路宽与作品说明。README和测试说明定点更新，保留公开版原有的精简链接，不整份覆盖本地历史推送日志。详情见[清理规则](minimap-code-cleanup-20261029.md)和[验收跟进](review-followup-20261029.md)。

## 本轮实测

- lint扫描158个GD通过；生产聚合解析67个GD通过；两道文档闸门通过，套件19项/Quick14项，生产检查23类。
- PowerShell调度及最终证据判定16通过、0失败。
- `minimap_removed_test.gd`：18/0；`race_position_scene_test.gd`：15/0；`race_clock_scene_test.gd`：正常实时60目标、AI开启，42/0。三者进程退出码均0，无脚本错误或资源泄漏，均保留根证书读取诊断。
- 计时专项第一次误传`--aioff`，需要真实AI的前置断言失败，结果1/1、exit1；修正调用为`--aion`后通过，测试及断言未修改。此前完整候选加速模式41/1的历史失败继续保留。
- 所有修改GD不超过1000行，历史AI文件1686行债务未改。指定路径diff空白检查通过。
- 原73个.import及7个UID在同步前已备份并记录SHA256，验证后80个文件哈希均保持不变，不纳入本次提交。

复核命令示例：

```powershell
pwsh -File .\04-Godot启动器\lint-gdscript.ps1
pwsh -File .\04-Godot启动器\parse-check.ps1
pwsh -File .\04-Godot启动器\check-docs.ps1
pwsh -File .\04-Godot启动器\check-readme.ps1
& 'E:\godot\Godot_v4.4.1-stable_win64_console.exe' --headless --path .\godot-racer --log-file '<新的绝对日志路径>' --audio-driver WASAPI --script res://tests/race_clock_scene_test.gd -- --aion --render-fps=60
```

原始日志、备份及调用失败记录仅保存在本机会话目录 `evidence/publish-x`，不入公开提交。本次未做图形渲染、持续FPS或真人验收；此前BAT流程证据仍绑定此前完整候选。耳机/扬声器听音、反光/涟漪、A/D、R、雨雪滑动、腾空和阴影的真人U继续开放。90场矩阵未授权、未启动；六语言仅规划；未导出EXE，未重冻。

本批仅创建本地提交，新提交推送须用户另行明确授权。Blender下载和MCP配置已按用户后续决定停止，由用户手动下载；本次工作不依赖Blender。
