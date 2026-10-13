# 起 MCP server + Godot headless 编辑器，跑一次能力探针，把结果落 UTF-8 日志。
#
# 与 verify-godot-mcp.ps1 -Live 的区别：
#   那个回答"链路通不通"（健康检查，7 个只读工具）。
#   这个回答"能干到什么程度"（能力评估，含运行时工具 run_scene / query_runtime_node
#   / get_performance_monitors / take_screenshot），并记录每个工具的耗时用于比成本。
#
# 为什么必须自己开 Godot：能力探针里有运行时工具，必须有编辑器实例连着 server，
# 而 run-check.ps1 那种游戏模式进程（--headless 不带 --editor）不会加载编辑器插件。
#
# 用法：pwsh -File .\run-mcp-capability.ps1
param(
    [string]$Project = "",
    [string]$GodotPath = "E:\godot\Godot_v4.4.1-stable_win64.exe",
    # 探针脚本名（放在本目录下）。默认跑能力评估，传 mcp-runtime-probe.js 跑运行时通道。
    [string]$Probe = "mcp-capability-probe.js",
    # 配合通用调用器 mcp-run.js 使用：给出调用清单 JSON，代替写死在脚本里的工具序列
    [string]$CallsFile = ""
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
if ($Project -eq "") { $Project = Join-Path $Root "godot-racer" }
$LogDir = Join-Path $Root "godot-logs"

# 中文输出：node 写 UTF-8 文件，PowerShell 这里只负责起停，不做管道中转
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# server 的启动参数直接读 mcp.json，避免在这里抄第二份路径
$cfgPath = Join-Path $env:USERPROFILE ".workbuddy\mcp.json"
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
$srv = $cfg.mcpServers.godot
$NodeExe = $srv.command
$ServerEntry = @($srv.args)[0]

if (-not (Test-Path $NodeExe))     { Write-Host "找不到 node.exe：$NodeExe"; exit 1 }
if (-not (Test-Path $ServerEntry)) { Write-Host "找不到 server 入口：$ServerEntry"; exit 1 }
if (-not (Test-Path $GodotPath))   { Write-Host "找不到 Godot：$GodotPath"; exit 1 }
if (Get-Process -Name "Godot*" -ErrorAction SilentlyContinue) {
    Write-Host "已有 Godot 进程在跑 —— 本工具需要独占，请先关掉。"; exit 1
}

$tag = if ($Probe -match 'runtime') { "mcp-rt" } else { "mcp-cap" }
$srvLog  = Join-Path $LogDir "$tag-srv.log"
$gLog    = Join-Path $LogDir "$tag-godot.log"
$probeOut= Join-Path $LogDir ("{0}-probe.txt" -f $tag)
Remove-Item $srvLog, $gLog, $probeOut -ErrorAction SilentlyContinue

$srvProc = Start-Process -FilePath $NodeExe -ArgumentList @($ServerEntry) `
    -RedirectStandardOutput $srvLog `
    -RedirectStandardError (Join-Path $LogDir "$tag-srv.err.log") `
    -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3

$gProc = Start-Process -FilePath $GodotPath `
    -ArgumentList @("--headless", "--editor", "--path", $Project, "--log-file", $gLog) `
    -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $LogDir "$tag-godot.out.log") `
    -RedirectStandardError (Join-Path $LogDir "$tag-godot.err.log")

# 等编辑器就绪：插件要在编辑器起来之后才会连 server，探针里的轮询能兜住，
# 但 run_scene 这类操作在编辑器还在导入资源时会失败，所以这里先给一段静默期。
Start-Sleep -Seconds 8

$probe = Join-Path $PSScriptRoot $Probe
$extra = @()
if ($CallsFile -ne "") { $extra += @((Resolve-Path $CallsFile).Path, $probeOut) }
else { $extra += @($probeOut) }
& $NodeExe $probe $NodeExe $ServerEntry $Project @extra | Out-Null
$probeExit = $LASTEXITCODE

Start-Sleep -Seconds 1
if (-not $gProc.HasExited)   { $gProc.Kill() | Out-Null }
if (-not $srvProc.HasExited) { $srvProc.Kill() | Out-Null }

Write-Host ""
Write-Host ("探针退出码: $probeExit")
if (Test-Path $probeOut) {
    foreach ($line in ([System.IO.File]::ReadAllText($probeOut, [System.Text.Encoding]::UTF8) -split "`r?`n")) {
        Write-Host ("  " + $line)
    }
} else { Write-Host "探针没有写出结果：$probeOut" }
exit 0
