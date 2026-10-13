# godot-mcp 插件的 Godot 4.4.1 兼容性补丁（幂等，可反复运行）。
#
# 为什么需要它（2026-10-13 实测）：
#   插件 addons/godot_mcp/tools/scene_tools.gd 里有一行
#       if state and state.get_base_scene_state() != null:
#   而 SceneState.get_base_scene_state() 是 **Godot 4.5+** 才有的 API。
#   用本机 Godot 4.4.1-stable 实测 ClassDB：
#       HAS get_base_scene_state : false
#       HAS get_node_count       : true      ← 对照，说明探测方法本身是好的
#   后果：read_scene 工具每次调用都失败，报
#       "Invalid call. Nonexistent function 'get_base_scene_state'"
#   并且这条错误会被插件自己的 get_errors 抓到，污染 AI 读到的报错列表。
#
# 修法：**先探测再调用**（has_method 守卫），4.4.1 上退化为按主场景实例化，
# 4.5+ 上行为完全不变。这是最小改动，不做版本分叉。
#
# ⚠ addons/ 已在本项目的 .gitignore 里（第三方依赖不入库），
#   所以**重装插件后必须重新跑一次本脚本**。
#
# 用法：pwsh -File .\patch-godot-mcp.ps1
#       pwsh -File .\patch-godot-mcp.ps1 -Project <项目绝对路径>
param(
    [string]$Project = ""
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if ($Project -eq "") { $Project = Join-Path $Root "godot-racer" }

$target = Join-Path $Project "addons\godot_mcp\tools\scene_tools.gd"
if (-not (Test-Path $target)) {
    Write-Host "patch-godot-mcp: 找不到 $target"
    Write-Host "                 请先在 Godot 里安装 Godot MCP 插件再跑本脚本。"
    exit 2
}

$oldLine = 'if state and state.get_base_scene_state() != null:'
$newBlock = @'
	# [本地补丁 2026-10-13] SceneState.get_base_scene_state() 是 Godot 4.5+ 才有的 API，
	# 在 4.4.1 上直接调用会让 read_scene 整体失败（get_errors 抓到
	# "Invalid call. Nonexistent function 'get_base_scene_state'"，见 Godot 4.4.1 ClassDB 实测）。
	# 改为先探测再调用：没有该 API 时退化为按主场景实例化。此改动向上兼容 4.5+。
	if state and state.has_method("get_base_scene_state") and state.get_base_scene_state() != null:
'@

$txt = Get-Content $target -Raw

if ($txt -match 'has_method\("get_base_scene_state"\)') {
    Write-Host "patch-godot-mcp: 补丁已存在，无需重复打 ✔"
    exit 0
}

if (-not $txt.Contains($oldLine)) {
    Write-Host "patch-godot-mcp: 找不到目标行 —— 插件版本可能已变，脚本需要复核。"
    Write-Host "                 要替换的是：$oldLine"
    exit 3
}

# 保持原有换行风格（CRLF / LF），不要顺手改文件格式
$nl = if ($txt -match "`r`n") { "`r`n" } else { "`n" }
$patched = $txt.Replace($oldLine, $newBlock.Replace("`r`n", "`n").Replace("`n", $nl))
[System.IO.File]::WriteAllText($target, $patched, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "patch-godot-mcp: 已写入补丁 ✔  read_scene 现在可用于 Godot 4.4.1"
Write-Host "                 验证：启动 MCP server + Godot 后调用 read_scene / get_errors"
exit 0
