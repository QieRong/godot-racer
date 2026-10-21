# Godot MCP 连接恢复记录（2026-10-21）

状态：**编辑器连接及真实工具调用已恢复**。用户报告项目仍开着，要求使用时修复连接。

## 现场与处置

- `get_godot_status` 首次返回 `ECONNREFUSED 127.0.0.1:16506`，提示主服务不可达。
- 系统端口检查确认 16505、16506 都没有监听；存在的 MCP Node 客户端进程没有提供主服务。仅凭这些信息不能确定旧主服务为何退出。
- 编辑器插件 `addons/godot_mcp/mcp_client.gd` 与 Codex 配置已一致使用 WebSocket 16505 / HTTP 16506，无须改端口。
- 隐藏启动本机已安装的 `godot-mcp-server` 0.6.0，设置与既有配置相同的进程环境端口，使用 `--no-force`，未结束其他进程。此次主服务 PID 17044，仅供本次会话排查；不能在以后按此 PID 盲目操作。
- 没有重启或关闭用户的 Godot 编辑器，没有改 project.godot、autoload、源码、网络/代理或全局配置。正在运行的串行回归继续。

## 实测

1. 服务日志确认 WebSocket 16505 与 HTTP 16506 成功监听，随后原编辑器自动重连。
2. 再次 `get_godot_status`：`connected=true`、`mode=live`、项目为 `D:/桌面/DSH-Work/data-analysis/godot-racer/`。
3. `get_console_log` 真正往返编辑器，读到 `[MCP] Connected to server` 和 `[Godot MCP] Connected to MCP server`，`ok=true`。
4. `get_runtime_status` 真正往返编辑器，版本为 Godot 4.4.1-stable official，`playing=false`。`runtime_helper_connected=false`：本项目未注册运行助手且此时编辑器未启动游戏；不能据此说编辑器 MCP 仍然断线，也不能宣称运行时发键能力已验证。

原始服务启动日志：`godot-logs/review-p0c-20261021-mcp-server.{stdout,stderr}.log`。本次恢复连接没有修订第三方服务的代理重选逻辑；若以后主服务再次退出，应先重新确认端口与健康状态，不能通过杀编辑器解决。
