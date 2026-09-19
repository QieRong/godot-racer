# 跑一次游戏内自检并抓取结果。
#
# 为什么要重试：这台机器上 Godot 4.4.1 的**启动期**偶发 signal 11 段错误
# （和项目代码无关，空场景也会），所以验收脚本必须能自动重跑。
#
# 用法：
#   pwsh -File .\run-check.ps1 -Check enclosure
#   pwsh -File .\run-check.ps1 -Check opponents -Level 4     # 指定关卡（0 起）
param(
    [string]$Check = "enclosure",
    [int]$MaxTries = 6,
    [int]$TimeoutSec = 120,
    [int]$Level = -1,
    [switch]$NoAi
)

$ErrorActionPreference = "Continue"
$Godot = "E:\godot\Godot_v4.4.1-stable_win64.exe"
$ProjDir = Split-Path -Parent $PSScriptRoot
$LogPath = Join-Path $ProjDir "godot-logs\check-$Check.log"

if (-not (Test-Path $Godot)) { Write-Host "找不到 Godot: $Godot"; exit 2 }

# 关卡参数是可选的：不传就沿用 GameState 默认关卡
$userArgs = @("--check=$Check")
if ($Level -ge 0) { $userArgs += "--level=$Level" }
if ($NoAi) { $userArgs += "--noai" }

for ($i = 1; $i -le $MaxTries; $i++) {
    Remove-Item $LogPath -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $Godot `
        -ArgumentList (@('--path', '.', '--log-file', $LogPath, '--') + $userArgs) `
        -WorkingDirectory (Join-Path $ProjDir 'godot-racer') `
        -NoNewWindow -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-Path $LogPath) {
            $txt = Get-Content $LogPath -Raw -ErrorAction SilentlyContinue
            if ($txt -and $txt -match '\[CHECK\] 完成') { $ok = $true; break }
        }
        if ($p.HasExited) { break }
    }
    if (-not $p.HasExited) { $p.Kill() | Out-Null; Start-Sleep -Seconds 1 }
    if ($ok) { Write-Host "== 第 $i 次尝试成功 =="; break }
    Write-Host "== 第 $i 次尝试失败（大概率是启动期段错误），重试 =="
}

if (-not (Test-Path $LogPath)) { Write-Host "没有日志产出"; exit 3 }
Write-Host "---- 自检结果 ----"
Get-Content $LogPath | Select-String -Pattern '\[自检\]|\[CHECK\]|护栏环闭合|护栏已生成|SCRIPT ERROR|ERROR: ' |
    ForEach-Object { $_.Line }
