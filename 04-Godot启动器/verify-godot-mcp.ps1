# godot-mcp 可用性自检。默认只做静态检查（秒级、不动 Godot）；
# 加 -Live 才会真正起 server + Godot 编辑器跑一次端到端。
#
# 为什么要有这个脚本：
#   这套 MCP 有三个"各自都静默失败"的环节 ——
#     ① AI 客户端 mcp.json 指向的 dist/index.js 不存在（改了路径/重装 node 后）
#     ② server 与 Godot 插件**版本错配**（AI 会看到 Unknown tool，但连接是绿的）
#     ③ 插件调了 Godot 4.4.1 没有的 API（read_scene 整条挂掉，形状像"插件坏了"）
#   三者都不会让"MCP Connected"变红，所以必须有一条能一次性报出来的检查。
#
# 用法：
#   pwsh -File .\verify-godot-mcp.ps1            # 静态检查
#   pwsh -File .\verify-godot-mcp.ps1 -Live      # 静态 + 真实链路（约 40 秒，需 Godot 未被占用）
param(
    [switch]$Live,
    [string]$Project = "",
    [string]$GodotPath = "E:\godot\Godot_v4.4.1-stable_win64.exe",
    [string]$McpConfig = ""
)

$Root = Split-Path -Parent $PSScriptRoot
if ($Project -eq "") { $Project = Join-Path $Root "godot-racer" }
if ($McpConfig -eq "") { $McpConfig = Join-Path $env:USERPROFILE ".workbuddy\mcp.json" }
$LogDir = Join-Path $Root "godot-logs"
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

# node 子进程输出 UTF-8，而 Windows PowerShell 5.1 默认按控制台代码页(GBK)解码，
# 结果是探针的中文全变成「宸茶繛涓?」这种乱码（功能不受影响，但没法读）。两侧都钉成 UTF-8。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$fails = @()
function Ok([string]$m)   { Write-Host ("  [OK]   " + $m) }
function Bad([string]$m)  { Write-Host ("  [FAIL] " + $m); $script:fails += $m }
function Warn([string]$m) { Write-Host ("  [WARN] " + $m) }

Write-Host "=== 1/5 AI 客户端配置 ==="
$cfg = $null
if (-not (Test-Path $McpConfig)) {
    Bad "找不到 MCP 配置：$McpConfig"
} else {
    try {
        $cfg = Get-Content $McpConfig -Raw | ConvertFrom-Json
        $srv = $cfg.mcpServers.godot
        if (-not $srv) { Bad "mcp.json 里没有 mcpServers.godot 节点" }
        else {
            $nodeExe = $srv.command
            $entry = @($srv.args)[0]
            if (-not (Test-Path $nodeExe)) { Bad "command 指向的 node.exe 不存在：$nodeExe" }
            elseif (-not (Test-Path $entry)) { Bad "args 指向的 index.js 不存在：$entry" }
            else {
                Ok "node.exe 与 dist/index.js 都存在"
                $script:NodeExe = $nodeExe
                $script:ServerEntry = $entry
                $script:ProjectDir = if ($srv.cwd) { $srv.cwd } else { $Project }
            }
        }
    } catch { Bad "mcp.json 不是合法 JSON：$($_.Exception.Message)" }
}

Write-Host "=== 2/5 Godot 插件文件 ==="
$pluginCfg = Join-Path $Project "addons\godot_mcp\plugin.cfg"
$pluginVer = $null
if (-not (Test-Path $pluginCfg)) {
    Bad "插件未安装：$pluginCfg 不存在（先在 Godot 里装 Godot MCP 插件）"
} else {
    foreach ($line in (Get-Content $pluginCfg)) {
        if ($line -match '^version\s*=\s*"([^"]+)"') { $pluginVer = $Matches[1] }
    }
    Ok "插件已安装，plugin.cfg version=$pluginVer"
}

Write-Host "=== 3/5 插件是否已在 project.godot 启用 ==="
$projTxt = Get-Content (Join-Path $Project "project.godot") -Raw
if ($projTxt -match 'res://addons/godot_mcp/plugin\.cfg') {
    Ok "已启用（[editor_plugins] 里有 godot_mcp）"
} else {
    Bad "未启用 —— 在 Godot 里 Project > Project Settings > Plugins 勾选 Godot MCP"
}

Write-Host "=== 4/5 server 与插件版本是否配套 ==="
$srvVer = $null
if ($script:ServerEntry -and (Test-Path $script:ServerEntry)) {
    $pkg = Join-Path (Split-Path -Parent $script:ServerEntry) "..\package.json"
    if (Test-Path $pkg) {
        try { $srvVer = (Get-Content $pkg -Raw | ConvertFrom-Json).version } catch {}
    }
}
if ($srvVer -and $pluginVer) {
    if ($srvVer -eq $pluginVer) { Ok "配套：server $srvVer = 插件 $pluginVer" }
    else {
        Warn "版本不同：server $srvVer / 插件 $pluginVer"
        Warn "若 AI 报 Unknown tool，就是这个原因 —— 换同版本插件（见 README 记录）"
    }
} else { Warn "有一侧版本读不到，跳过比对" }

Write-Host "=== 5/5 Godot 4.4.x 兼容补丁 ==="
$sceneTools = Join-Path $Project "addons\godot_mcp\tools\scene_tools.gd"
if (-not (Test-Path $sceneTools)) { Warn "找不到 scene_tools.gd，跳过" }
else {
    $st = Get-Content $sceneTools -Raw
    if ($st -match 'has_method\("get_base_scene_state"\)') { Ok "补丁已打，read_scene 可用" }
    elseif ($st -match 'state\.get_base_scene_state\(\)') {
        Bad "补丁未打 —— read_scene 在 Godot 4.4.x 上必然失败，跑 .\patch-godot-mcp.ps1"
    } else { Warn "目标代码形态已变，需人工复核" }
}

if (-not $Live) {
    Write-Host ""
    if ($fails.Count -eq 0) { Write-Host "静态检查通过。加 -Live 可跑真实链路（约 40 秒）。"; exit 0 }
    Write-Host ("静态检查发现 {0} 个问题，见上方 [FAIL]。" -f $fails.Count); exit 1
}

Write-Host ""
Write-Host "=== Live：真实链路端到端（起 server + Godot headless 编辑器）==="
if (-not (Test-Path $GodotPath)) { Write-Host "  [FAIL] 找不到 Godot：$GodotPath"; exit 1 }
if (Get-Process -Name "Godot*" -ErrorAction SilentlyContinue) {
    Write-Host "  [FAIL] 已有 Godot 进程在跑 —— 本工具需要独占（同时跑会互相干扰），请先关掉。"
    exit 1
}

$srvLog = Join-Path $LogDir "verify-mcp-srv.log"
$gLog = Join-Path $LogDir "verify-mcp-godot.log"
$probeOut = Join-Path $LogDir "verify-mcp-probe.txt"
Remove-Item $srvLog, $gLog, $probeOut -ErrorAction SilentlyContinue

$srvProc = Start-Process -FilePath $script:NodeExe -ArgumentList @($script:ServerEntry) `
    -RedirectStandardOutput $srvLog -RedirectStandardError (Join-Path $LogDir "verify-mcp-srv.err.log") `
    -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 3

$gProc = Start-Process -FilePath $GodotPath `
    -ArgumentList @("--headless", "--editor", "--path", $script:ProjectDir, "--log-file", $gLog) `
    -PassThru -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $LogDir "verify-mcp-godot.out.log") `
    -RedirectStandardError (Join-Path $LogDir "verify-mcp-godot.err.log")
Start-Sleep -Seconds 6

$probe = Join-Path $PSScriptRoot "mcp-probe.js"
# 探针自己把结果写成 UTF-8 文件，这里不做 PowerShell 管道中转（否则中文会被按 GBK 解码成乱码）
& $script:NodeExe $probe $script:NodeExe $script:ServerEntry $script:ProjectDir $probeOut | Out-Null
$code = $LASTEXITCODE

Start-Sleep -Seconds 1
if (-not $gProc.HasExited) { $gProc.Kill() | Out-Null }
if (-not $srvProc.HasExited) { $srvProc.Kill() | Out-Null }

Write-Host ""
if (Test-Path $probeOut) {
    Write-Host "探针结果："
    foreach ($line in ([System.IO.File]::ReadAllText($probeOut, [System.Text.Encoding]::UTF8) -split "`r?`n")) {
        Write-Host ("  " + $line)
    }
} else { Warn "探针没有写出结果文件：$probeOut" }

Write-Host ""
Write-Host "Godot 侧握手日志："
Get-Content $gLog -ErrorAction SilentlyContinue |
    Select-String -Pattern '\[MCP\]|Godot MCP' |
    Select-Object -First 5 |
    ForEach-Object { Write-Host ("  " + $_.Line) }

if ($code -eq 0) { Write-Host "`n端到端通过 ✔"; exit 0 }
Write-Host "`n端到端失败，探针输出见 $probeOut"; exit 1
