# install_godot.ps1
# 把 Godot 4.4.1 (stable) 标准版装到 E:\godot
#
# 为什么需要你手动跑：我这个 Agent 派生的进程在沙箱里没有任何网络访问
# （curl 报 SEC_E_NO_CREDENTIALS，winget 报网络不可用），
# 而你的普通终端是有网的。
#
# 用法：在本文件所在目录打开 PowerShell，执行
#     powershell -ExecutionPolicy Bypass -File .\install_godot.ps1

$ErrorActionPreference = 'Stop'

# 项目根目录 = 本脚本所在目录的上一级（自定位，文件夹改名/移动都不受影响）
$ProjRoot = Split-Path -Parent $PSScriptRoot
$GameProj = Join-Path $ProjRoot 'godot-racer'

$TargetDir = 'E:\godot'
$Url       = 'https://downloads.godotengine.org/?version=4.4.1&flavor=stable&slug=win64.exe.zip&platform=windows.64'
$ZipPath   = Join-Path $env:TEMP 'godot_4.4.1_win64.zip'

Write-Host "==> 目标目录: $TargetDir"
if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
}

Write-Host "==> 下载 Godot 4.4.1 (约 60 MB) ..."
# BITS 比 Invoke-WebRequest 稳，且支持断点续传；失败则回退
try {
    Start-BitsTransfer -Source $Url -Destination $ZipPath -Description 'Godot 4.4.1' -ErrorAction Stop
} catch {
    Write-Host "    BITS 不可用，改用 Invoke-WebRequest ..."
    Invoke-WebRequest -Uri $Url -OutFile $ZipPath -UseBasicParsing
}

if (-not (Test-Path $ZipPath)) { throw "下载失败：$ZipPath 不存在" }
$size = (Get-Item $ZipPath).Length
Write-Host ("==> 下载完成: {0:N1} MB" -f ($size / 1MB))

Write-Host "==> 解压到 $TargetDir ..."
Expand-Archive -Path $ZipPath -DestinationPath $TargetDir -Force

# 官方压缩包内是 Godot_v4.4.1-stable_win64.exe；再复制一份短名字方便命令行调用
$exe = Get-ChildItem $TargetDir -Filter 'Godot_v*_win64.exe' | Select-Object -First 1
if ($exe) {
    Copy-Item $exe.FullName (Join-Path $TargetDir 'godot.exe') -Force
    Write-Host "==> 可执行文件: $($exe.FullName)"
    Write-Host "==> 短名副本:   $TargetDir\godot.exe"
} else {
    Write-Warning "没找到 Godot 可执行文件，请检查解压结果"
    Get-ChildItem $TargetDir
}

Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "==> 完成。自检："
& (Join-Path $TargetDir 'godot.exe') --version

Write-Host ""
Write-Host "提示：游戏项目在 $ProjRoot\godot-racer"
Write-Host "     装好后直接用同目录下的快捷方式启动："
Write-Host "       运行游戏.lnk          （直接玩；带 --log-file 规避启动期崩溃）"
Write-Host "       打开Godot编辑器.lnk    （进编辑器改场景/调参）"
Write-Host "     命令行方式："
Write-Host "       & '$TargetDir\godot.exe' -e --path '$ProjRoot\godot-racer'"
