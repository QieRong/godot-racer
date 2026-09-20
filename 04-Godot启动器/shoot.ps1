# 抓游戏实机截图。
#
# 为什么要重试：这台机器上 Godot 4.4.1 的**启动期**偶发 signal 11 段错误
# （与项目代码无关，空场景也会），所以抓图脚本必须能自动重跑。
#
# 用法：
#   pwsh -File .\shoot.ps1 -Level 4 -Out shot.png
#   pwsh -File .\shoot.ps1 -Level 3 -Frames 430 -Hold 430
param(
    [int]$Level = 0,
    [int]$Frames = 430,
    [int]$Hold = 430,
    [string]$Out = "",
    [int]$MaxTries = 6,
    [int]$TimeoutSec = 60
)

$ErrorActionPreference = "Continue"
$Godot = "E:\godot\Godot_v4.4.1-stable_win64.exe"
$ProjDir = Split-Path -Parent $PSScriptRoot
$Proj = Join-Path $ProjDir 'godot-racer'
if ($Out -eq "") { $Out = Join-Path $ProjDir "godot-logs\shot-$Level.png" }
$LogPath = Join-Path $ProjDir "godot-logs\shot-$Level.log"

if (-not (Test-Path $Godot)) { Write-Host "找不到 Godot: $Godot"; exit 2 }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Out) | Out-Null

for ($i = 1; $i -le $MaxTries; $i++) {
    Remove-Item $Out -ErrorAction SilentlyContinue
    Remove-Item $LogPath -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $Godot `
        -ArgumentList @('--path', '.', '--log-file', $LogPath, '--',
            '--shot', "--shot-frames=$Frames", "--shot-hold=$Hold",
            "--shot-out=$Out", "--level=$Level") `
        -WorkingDirectory $Proj -NoNewWindow -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 1500
        if (Test-Path $Out) { $ok = $true; Start-Sleep -Milliseconds 800; break }
        if ($p.HasExited) { break }
    }
    if (-not $p.HasExited) { $p.Kill() | Out-Null; Start-Sleep -Milliseconds 500 }
    if ($ok) { Write-Host "== 第 $i 次尝试成功 =="; break }
    Write-Host "== 第 $i 次尝试失败（多半是启动期段错误），重试 =="
}

if (Test-Path $Out) {
    Write-Host ("截图成功 -> {0}  ({1} bytes)" -f $Out, (Get-Item $Out).Length)
    if (Test-Path $LogPath) {
        Get-Content $LogPath | Select-String -Pattern '截图|天气|对手|关卡已加载' | ForEach-Object { $_.Line }
    }
} else {
    Write-Host "截图失败（$MaxTries 次尝试都没产出）"
    if (Test-Path $LogPath) {
        Write-Host "---- 最后一次日志尾部 ----"
        Get-Content $LogPath -Tail 25
    }
    exit 3
}
