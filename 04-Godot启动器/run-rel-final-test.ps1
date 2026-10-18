# REL-QA-GATE · 跑 tests/ 下的 SceneTree 专项测试并把日志落盘。
#
# 为什么单独一个 runner（与 run-settings-test.ps1 同一套路）：
#   ① 本机 Godot 4.4.1 启动期偶发 signal 11，必须能自动重跑；
#   ② 只看退出码会漏掉"脚本加载失败 → 退出 0 但一个用例都没跑"这类假绿，
#      所以退出码和日志里的标志串**都**要查；
#   ③ --script 跑 SceneTree 时，要喂给 get_cmdline_user_args() 的参数必须放在 `--` 之后，
#      手敲容易漏这个 `--`，漏了测试就静默空转（参数根本没进去）。
#
# 用法：
#   pwsh -File .\run-rel-final-test.ps1 -LogName rel-final-finish-green
#   pwsh -File .\run-rel-final-test.ps1 -Script res://tests/rel_final_mode_guard_test.gd `
#        -LogName rel-final-finish-b7-check -Extra '--check=rel-qa-b7','--rfmode=check'
param(
    [string]$Script = "res://tests/rel_final_finish_flow_test.gd",
    [string]$LogName = "rel-final-finish",
    # 空格分隔的单个字符串，而不是 [string[]]。
    # 为什么：外层再用 `pwsh -File` 调本脚本时，数组参数会被整体当成一个带引号的字符串
    # 传进来（实测打印出 `'--check=x','--rfmode=y'` 这样的**一个** argv），
    # 于是 Godot 收到的是一个根本不认识的参数，测试会静默空转。用单串自己 split 最稳。
    [string]$ExtraArgs = "",
    [int]$MaxTries = 4,
    [int]$TimeoutSec = 300,
    [switch]$NoHeadless,
    # REL-QA-GATE：给 Godot 加 --verbose，用来定位退出期的
    # "ObjectDB instances leaked / N resources still in use" 到底是哪些对象。
    [switch]$GodotVerbose
)

$ErrorActionPreference = "Continue"
# ⚠ 强制 UTF-8：本机默认 gb2312，不设会把子进程输出里的 ✔/✘ 降级成 ?，判据全线假红。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$Proj = Join-Path $Root "godot-racer"
$Logs = Join-Path $Root "godot-logs"
$Godot = "E:\godot\Godot_v4.4.1-stable_win64.exe"
$LogPath = Join-Path $Logs "$LogName.log"
$StdOutPath = Join-Path $Logs "$LogName.stdout.log"

if (-not (Test-Path $Godot)) { Write-Host "找不到 Godot: $Godot"; exit 2 }

# ---- preflight：引号 lint + 解析（与 run-check.ps1 同一道闸）----
$lint = Join-Path $Here "lint-gdscript.ps1"
if (Test-Path $lint) {
    & pwsh -File $lint | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! preflight 未通过：lint 失败（本轮结果会全部无效）"
        exit 4
    }
}
$pc = Join-Path $Here "parse-check.ps1"
if (Test-Path $pc) {
    & pwsh -File $pc | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "!! preflight 未通过：脚本解析失败（本轮结果会全部无效）"
        exit 6
    }
}

for ($i = 1; $i -le $MaxTries; $i++) {
    if (Test-Path $LogPath) { Remove-Item $LogPath -Force }
    $argList = @('--path', $Proj, '--log-file', $LogPath)
    if ($GodotVerbose) { $argList = @('--verbose') + $argList }
    if (-not $NoHeadless) { $argList += '--headless' }
    $argList += @('--script', $Script)
    if ($ExtraArgs -ne "") {
        $argList += '--'
        $argList += ($ExtraArgs -split '\s+')
    }
    Write-Host ("== 第 {0} 次：godot {1}" -f $i, ($argList -join ' '))
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
    if ($processExit -ne -1 -and (Test-Path $LogPath)) { break }
    Write-Host ("== 第 {0} 次未正常结束（exit={1}），重试 ==" -f $i, $processExit)
}

if (-not (Test-Path $LogPath)) { Write-Host "没有日志产出：$LogPath"; exit 3 }
"PROCESS_EXIT=$processExit" | Set-Content -Path $StdOutPath -Encoding UTF8
Get-Content $LogPath | Add-Content -Path $StdOutPath -Encoding UTF8
Write-Host "---- $LogName (exit=$processExit) ----"
Get-Content $LogPath | ForEach-Object { Write-Host $_ }
exit $processExit
