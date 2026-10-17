# 跑 tests/release_settings_test.gd（REL-STEP2A：渲染帧率 / 窗口策略 / 关卡枚举 / 菜单可达性）。
#
# 为什么要单独一个 runner（而不是直接敲 godot）：
#   ① 这台机器上 Godot 4.4.1 **启动期**偶发 signal 11（与项目代码无关），必须能重跑；
#   ② 判据是"全部用例都过才算过"（RELEASE_SETTINGS_PASS），只看退出码会漏掉
#      "脚本加载失败 → 退出 0 但一个用例都没跑"这种假绿，所以退出码**和**标志串都查；
#   ③ 日志名可换，红灯/绿灯证据才能各存一份、互不覆盖（A/B 的老坑）。
#
# 用法：
#   pwsh -File .\run-settings-test.ps1 -LogName rel-step2a-red
#   pwsh -File .\run-settings-test.ps1 -LogName rel-step2a-green
param(
    [string]$LogName = "rel-step2a-settings",
    [int]$MaxTries = 4,
    [int]$TimeoutSec = 120,
    # 默认无头：这个测试断言的是数据与布局，不需要真窗口；
    # 而且无头跑得快、也不会在跑验收时弹出一堆窗口抢焦点（那会让 lap/physics 类检查发散）。
    [switch]$NoHeadless
)

$ErrorActionPreference = "Continue"
# ⚠ 强制 UTF-8（本机默认 gb2312，不设会通过 stdout 把 ✔/✘ 降级成 ?，判据全线假红）
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$Proj = Join-Path $Root "godot-racer"
$Godot = "E:\godot\Godot_v4.4.1-stable_win64.exe"
$LogPath = Join-Path $Root "godot-logs\$LogName.log"

if (-not (Test-Path $Godot)) { Write-Host "找不到 Godot: $Godot"; exit 2 }
if (-not (Test-Path (Join-Path $Proj "tests\release_settings_test.gd"))) {
    Write-Host "找不到测试脚本：$(Join-Path $Proj 'tests\release_settings_test.gd')"; exit 2
}

# ---- preflight：引号 lint + Godot 解析（与 run-check.ps1 同一道闸） ----
# 一行 print 里的直引号会让**整个脚本**加载失败，那时本 runner 会看到
# "没有 RELEASE_SETTINGS_PASS" —— 看起来像功能没实现，其实是一行引号。
# 挡在启动前，省掉一轮误判。
$lint = Join-Path $Here "lint-gdscript.ps1"
if (Test-Path $lint) {
    & pwsh -File $lint | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "!! preflight 未通过：lint 失败，先修掉引号/粘行问题再跑测试"
        exit 4
    }
}

$ok = $false
for ($i = 1; $i -le $MaxTries; $i++) {
    Remove-Item $LogPath -ErrorAction SilentlyContinue
    $argList = @('--path', $Proj, '--log-file', $LogPath)
    if (-not $NoHeadless) { $argList += '--headless' }
    $argList += @('--script', 'res://tests/release_settings_test.gd')
    $p = Start-Process -FilePath $Godot -ArgumentList $argList `
        -WorkingDirectory $Proj -NoNewWindow -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        if ($p.HasExited) { break }
    }
    if (-not $p.HasExited) { $p.Kill() | Out-Null; Start-Sleep -Seconds 1 }
    $p.Refresh()
    $processExit = if ($p.HasExited) { $p.ExitCode } else { -1 }
    if ($processExit -eq 0 -and (Test-Path $LogPath) -and
        ((Get-Content $LogPath -Raw) -match 'RELEASE_SETTINGS_(PASS|FAIL)')) {
        $ok = $true
        break
    }
    Write-Host "== 第 $i 次未正常结束（exit=$processExit），重试 =="
}

if (-not (Test-Path $LogPath)) { Write-Host "没有日志产出：$LogPath"; exit 3 }
$txt = Get-Content $LogPath -Raw
Write-Host "---- $LogName ----"
Get-Content $LogPath | ForEach-Object { Write-Host $_ }

if (-not $ok) {
    Write-Host ""
    Write-Host "!! 测试没有正常结束（脚本加载失败？）：既没 PASS 也没 FAIL —— 这是**红灯**，不是通过"
    exit 3
}
if ($txt -match 'RELEASE_SETTINGS_PASS') { exit 0 }
Write-Host ("!! 有用例失败：{0}" -f $LogPath)
exit 1
