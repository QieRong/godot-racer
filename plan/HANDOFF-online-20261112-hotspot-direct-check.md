# 2026-11-12 EOS 跨运营商与强制直连复测

《棱角飞车 · EDGE RACER》正式工程位于 `godot-racer/`。环境为 Godot 4.7.2 Compatibility（含 mobile）、Jolt、120 Hz，Windows 和 Android 实验端使用 EOSG 2.3.1、EOS SDK 1.19.1.2。当前正式 Windows EOS 入口使用 `AllowRelays`，首次建连预算和 EOS 同局重连单次预算均为 40 秒。实验 App 复用现有安装，通过 USB 装载实验脚本。

## 复测结果

电脑始终走有线，FlClash 保持开启。测试手机先直走中国广电 5G SA，再通过 Wi-Fi 接入另一家运营商手机的热点，结束后恢复广电蜂窝。ADB 确认对应的默认网络和 `VALIDATED` 状态。

| 手机网络 | 房主 | EOS 策略 | 结果 |
| --- | --- | --- | --- |
| 另一家运营商热点 | 手机 | `ForceRelays` | 大厅、邀请码、双方就绪成功，P2P 约 35 秒超时 |
| 同一个热点 | 手机 | `NoRelays` | 双端确认选中强制直连，交换候选后约 35 秒超时 |
| 同一个热点 | PC | `ForceRelays` | `EOS_P2P_AcceptConnection` 返回 `0`，约 35 秒超时 |
| 广电蜂窝 | 手机 | `NoRelays` | 大厅和准备成功，交换候选后约 35 秒超时 |

广电蜂窝下，从实验 App UID 向公开 STUN 服务发出的 IPv4 和 IPv6 Binding 请求均收到匹配事务的回包。前一轮在同一个实际 EOS TURN 端点上，PC 默认路径经 FlClash 收到 TURN `401` 认证挑战，指定以太网的独立测试 socket 超时，广电手机无回包。Windows 侧还观察到一条 IPv4 TURN 分配成功和部分 IPv4 `WSAENETUNREACH`。另一家运营商热点仍复现故障，当前证据支持继续隔离 Windows 出口与 EOS 的候选配对或中继数据路径。 [公开 STUN 服务](https://developers.cloudflare.com/realtime/sfu/get-started/connection-patterns/)

这四轮均未进入双向应用数据和重连。试验用 `NoRelays` 开关已撤回，runner 和实验脚本哈希已恢复到开测前，手机实验脚本已通过 USB 核对哈希。四轮零构建、零安装，临时配置已清空，无待清理大厅。既有 LLDB 返回码采集修复见 `plugin-labs-20261105/eos/trace_eos_p2p.py`。

## 给 Claude 的排查问题

请优先读 `godot-racer/scripts/online_eos_room.gd`、`godot-racer/scripts/online_room_session.gd`、`plugin-labs-20261105/eos/cross-platform-probe/probe.gd` 和 `plugin-labs-20261105/eos/run_phone_pc_probe.py`。在 EOS 大厅、双方就绪和信令都成功，Windows 原生 `AcceptConnection` 与首次 `SendPacket` 分别返回 `EOS_Success`，但强制直连和强制中继都超时的情况下，请指出代码里有没有可复现的 EOS 生命周期、候选配对、socket 绑定、回调或轮询问题，并给出对应源码位置及最小验证。若现有证据不足以归因，请提出一项能区分 Windows FlClash 出口、EOS SDK 和 TURN 路径的单变量实验，注明预期信号和判断标准。完整 Android 移植、正式导出及公网部署均有各自的后续授权与验收门槛。
