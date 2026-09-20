# Godot 赛车 - 启动器菜单（中文界面）
#
# 为什么菜单在 PowerShell 而不是 .bat：
#   cmd.exe 按**控制台代码页**解析 .bat，而这台机器的代码页不保证是 UTF-8。
#   中文字节被误解析时会吞掉后面的 ASCII 字符，把 echo 变成 ho、把 if 断掉，
#   整个脚本散架（实测过）。PowerShell 处理 UTF-8 没问题，而且**可以非交互测试**
#   （见下面的 -Action 参数），.bat 只留一个 ASCII 薄壳。
#
# 用法：
#   pwsh -File .\launcher-menu.ps1                     # 交互菜单
#   pwsh -File .\launcher-menu.ps1 -Action lint        # 非交互：只跑一项（便于自动化验证）
#   pwsh -File .\launcher-menu.ps1 -Action play -Level 3
#
# 可用的 -Action：play / playlevel / lint / readme / allchecks / quick /
#                 check（配 $env:CHECK_NAME）/ genoff / genon / cleanlogs / list
param(
    [string]$Action = "",
    [int]$Level = 0
)

$ErrorActionPreference = "Continue"
$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$Proj = Join-Path $Root "godot-racer"
$LogDir = Join-Path $Root "godot-logs"
$Godot = "E:\godot\Godot_v4.4.1-stable_win64.exe"
$CheckRunner = Join-Path $Here "run-check.ps1"
$Lint = Join-Path $Here "lint-gdscript.ps1"
$Gen = Join-Path $Proj "tools\test_generator.py"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Fail($msg) { Write-Host "[启动器] $msg" -ForegroundColor Red; if (-not $Action) { pause }; exit 1 }

function Assert-Env {
    if (-not (Test-Path (Join-Path $Proj "project.godot"))) { Fail "找不到项目：$Proj" }
    if (-not (Test-Path $Godot)) { Fail "找不到 Godot：$Godot" }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
}

# 跑 lint；返回 $true 表示可以继续
function Invoke-Lint {
    if (-not (Test-Path $Lint)) { return $true }
    Write-Host "[启动器] 预检查 GDScript…"
    & pwsh -File $Lint
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Red
        Write-Host " 已拦截：脚本里有会让文件整个解析失败的错误。" -ForegroundColor Red
        Write-Host " 现在启动会看到「赛道不生成、车一直往下掉」。" -ForegroundColor Red
        Write-Host " 请先修掉上面列出的问题。" -ForegroundColor Red
        Write-Host "============================================================" -ForegroundColor Red
        if (-not $Action) { pause }
        return $false
    }
    return $true
}

function Start-Game([string[]]$ExtraArgs) {
    Assert-Env
    if (-not (Invoke-Lint)) { return }
    $log = Join-Path $LogDir "game.log"
    for ($try = 1; $try -le 4; $try++) {
        $args = @("--path", $Proj, "--log-file", $log)
        if ($ExtraArgs.Count -gt 0) { $args += @("--") + $ExtraArgs }
        Write-Host "[启动器] 启动游戏（第 $try 次）…"
        $p = Start-Process -FilePath $Godot -ArgumentList $args -PassThru
        $p.WaitForExit()
        if (-not (Test-Path $log)) { Write-Host "[启动器] 没产生日志（启动太早就崩了），重试…"; continue }
        $txt = Get-Content $log -Raw -ErrorAction SilentlyContinue
        if ($txt -match 'CrashHandlerException') {
            if ($try -lt 4) { Write-Host "[启动器] 已知的启动期段错误（与项目无关），自动重试…"; continue }
            Fail "连续 4 次启动期段错误，请跑「启动诊断」"
        }
        # 退出后仍要检查脚本级错误：main.gd 挂掉时日志里照样有大量正常输出
        $bad = Get-Content $log | Select-String -Pattern 'Parse Error|Failed to load script|Compilation failed'
        if ($bad) {
            Write-Host ""
            Write-Host "============================================================" -ForegroundColor Yellow
            Write-Host " 警告：日志里发现脚本解析/编译错误，游戏表现不正常：" -ForegroundColor Yellow
            Write-Host "============================================================" -ForegroundColor Yellow
            $bad | Select-Object -First 10 | ForEach-Object { Write-Host "  $($_.Line)" }
            Write-Host "  完整日志：$log"
            if (-not $Action) { pause }
        }
        return
    }
}

function Invoke-AllChecks([switch]$Quick) {
    Assert-Env
    # ⚠ 这里曾经调 "跑全部验收.ps1"（改名前的旧文件名），菜单里点「跑全部验收」会直接失败。
    $a = @("-File", (Join-Path $Here "run-all-checks.ps1"))
    if ($Quick) { $a += "-Quick" }
    & pwsh @a
}

function Invoke-CleanLogs([int]$KeepHours = 6) {
    if (-not (Test-Path $LogDir)) { Write-Host "[启动器] 没有日志目录，无需清理"; return }
    $files = Get-ChildItem $LogDir -File -ErrorAction SilentlyContinue
    $before = ($files | Measure-Object Length -Sum).Sum
    $cut = (Get-Date).AddHours(-$KeepHours)
    $old = $files | Where-Object { $_.LastWriteTime -lt $cut }
    # 保留最近 6 小时：日志是排查用的中间产物，随时能再生成，
    # 但刚刚跑过的检查日志还可能要看，所以不做全清。
    $old | Remove-Item -Force -ErrorAction SilentlyContinue
    $after = ((Get-ChildItem $LogDir -File -ErrorAction SilentlyContinue) | Measure-Object Length -Sum).Sum
    Write-Host ("[启动器] 删除 {0} 个旧日志（保留最近 {1} 小时）" -f $old.Count, $KeepHours)
    Write-Host ("[启动器] {0:N1} MB → {1:N1} MB" -f ($before / 1MB), ($after / 1MB))
}

## 检查项列表：**直接从 run-all-checks.ps1 解析**，不再手抄一份。
##
## 为什么改成解析（实测教训）：菜单里原来手抄了 15 项，后来加了 flip / layout / aidiag 三个检查，
## 这份手抄的列表就**悄悄过期**了 —— 用户在菜单 6) 里根本看不到新检查。
## 现在检查项只有一处定义（run-all-checks.ps1），菜单永远跟着它走。
function Get-CheckList {
    $runner = Join-Path $Here 'run-all-checks.ps1'
    if (-not (Test-Path $runner)) { return @() }
    $text = Get-Content $runner -Raw
    $out = @()
    foreach ($m in [regex]::Matches($text, "@\{\s*n='([a-z0-9_]+)';\s*lv=(-?\d+);\s*ok='([^']+)'")) {
        if ([int]$m.Groups[2].Value -eq -9) { continue }   # -9 = 不启动 Godot 的特殊项（readme）
        $out += @{ n = $m.Groups[1].Value; d = ($m.Groups[3].Value -replace '\s*✔$', '') }
    }
    return $out
}

function Invoke-OneCheck {
    $checks = Get-CheckList
    Write-Host ""
    Write-Host ("[启动器] 可用检查项（共 {0} 项，定义来自 run-all-checks.ps1）：" -f $checks.Count)
    $i = 0
    foreach ($c in $checks) { $i++; Write-Host ("  {0,2}) {1,-12} {2}" -f $i, $c.n, $c.d) }
    Write-Host ""
    $sel = Read-Host "输入编号或检查名（回车取消）"
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $name = $sel.Trim()
    if ($name -match '^\d+$') {
        $idx = [int]$name - 1
        if ($idx -lt 0 -or $idx -ge $checks.Count) { Write-Host "编号超出范围"; return }
        $name = $checks[$idx].n
    }
    $lv = Read-Host "关卡编号 1-5（回车=默认）"
    $a = @("-File", $CheckRunner, "-Check", $name)
    if (-not [string]::IsNullOrWhiteSpace($lv)) { $a += @("-Level", "$([int]$lv - 1)") }
    & pwsh @a
}

function Invoke-OneCheckDirect([string]$name, [int]$oneBasedLevel) {
    Assert-Env
    $a = @("-File", $CheckRunner, "-Check", $name)
    if ($oneBasedLevel -ge 1) { $a += @("-Level", "$($oneBasedLevel - 1)") }
    & pwsh @a
}

function Invoke-Generate([switch]$Offline, [int]$oneBasedLevel = 5) {
    Assert-Env
    if (-not (Test-Path $Gen)) { Fail "找不到用例生成器：$Gen" }
    $a = @("tools\test_generator.py", "--level", "$($oneBasedLevel - 1)")
    if ($Offline) { $a += "--offline" } else { $a += @("--count", "12") }
    Push-Location $Proj
    try { & python @a } finally { Pop-Location }
}

## 赛道布局闭环解算：把 tools/layout_closure.py 里 DESIGNS 的设计解成可直接粘贴的 layout 串。
## 为什么要有这个入口：路段拼装**不保证首尾相接**，手写长度几乎不可能闭合
## （实测 L2 第一版残差 340m）。设计新赛道时必须用它先解长度。
function Invoke-LayoutDesign([int]$oneBasedLevel = 0) {
    Assert-Env
    $tool = Join-Path $Proj 'tools\layout_closure.py'
    if (-not (Test-Path $tool)) { Fail "找不到设计工具：$tool" }
    Push-Location $Proj
    try {
        if ($oneBasedLevel -ge 1) { & python 'tools\layout_closure.py' --level $oneBasedLevel }
        else { & python 'tools\layout_closure.py' --all }
    } finally { Pop-Location }
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host "============================================================"
        Write-Host "  Godot 赛车 - 启动器"
        Write-Host "============================================================"
        Write-Host "  项目：$Proj"
        Write-Host ""
        Write-Host "  [ 游玩 ]"
        Write-Host "    1) 运行游戏"
        Write-Host "    2) 运行游戏（指定关卡 1-5）"
        Write-Host "    3) 打开 Godot 编辑器"
        Write-Host ""
        Write-Host "  [ 测试与验收 ]"
        Write-Host "    4) 跑全部验收（16 项，约 20 分钟）"
        Write-Host "    5) 跑全部验收（快速版：跳过 lap/stress/opponents）"
        Write-Host "    6) 跑单项验收（列出全部检查项）"
        Write-Host "    7) 静态检查 lint（1 秒，不启动引擎）"
        Write-Host "    8) 校验文档：README/docs 与项目是否一致（1 秒）"
        Write-Host ""
        Write-Host "  [ 测试用例生成 ]"
        Write-Host "    9) 生成用例（离线，不需要梯子）"
        Write-Host "   10) 生成用例（联网，需要梯子开着）"
        Write-Host "   11) 赛道布局闭环解算（设计新赛道：把设计解成可粘贴的 layout 串）"
        Write-Host ""
        Write-Host "  [ 排查 ]"
        Write-Host "   12) 启动诊断（启动不了时用）"
        Write-Host "   13) 打开日志目录"
        Write-Host "   14) 清理临时日志（可再生，不影响游戏）"
        Write-Host ""
        Write-Host "    0) 退出"
        Write-Host "============================================================"
        $ch = Read-Host "请输入编号后回车"
        switch ($ch.Trim()) {
            "1"  { Start-Game @() }
            "2"  { $lv = Read-Host "关卡编号 1-5"; if ($lv -match '^\d+$') { Start-Game @("--level=$([int]$lv - 1)") } }
            "3"  { Assert-Env; Start-Process $Godot -ArgumentList @("-e", "--path", $Proj, "--log-file", (Join-Path $LogDir "editor.log")) }
            "4"  { Invoke-AllChecks }
            "5"  { Invoke-AllChecks -Quick }
            "6"  { Invoke-OneCheck }
            "7"  { & pwsh -File $Lint }
            "8"  { & pwsh -File (Join-Path $Here "check-readme.ps1") }
            "9"  { Invoke-Generate -Offline }
            "10" { Invoke-Generate }
            "11" { $lv = Read-Host "关卡编号 1-5（回车=全部）"; if ($lv -match '^\d+$') { Invoke-LayoutDesign ([int]$lv) } else { Invoke-LayoutDesign } }
            "12" { & cmd /c "`"$(Join-Path $Here '诊断Godot启动.bat')`"" }
            "13" { if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }; Start-Process explorer.exe $LogDir }
            "14" { Invoke-CleanLogs }
            "0"  { return }
            default { }
        }
        if ($ch.Trim() -ne "0") { Write-Host ""; pause }
    }
}

# ---------- 入口 ----------
if ($Action -eq "") { Show-Menu; exit 0 }

switch ($Action.ToLower()) {
    "play"      { Start-Game @() }
    "playlevel" { Start-Game @("--level=$($Level - 1)") }
    "lint"      { & pwsh -File $Lint; exit $LASTEXITCODE }
    "allchecks" { Invoke-AllChecks }
    "quick"     { Invoke-AllChecks -Quick }
    "check"     { Invoke-OneCheckDirect -name $env:CHECK_NAME -oneBasedLevel $Level }
    "genoff"    { Invoke-Generate -Offline -oneBasedLevel $Level }
    "genon"     { Invoke-Generate -oneBasedLevel $Level }
    "layout"    { Invoke-LayoutDesign -oneBasedLevel $Level }
    "list"      { Get-ChildItem $Here -File | Select-Object -ExpandProperty Name }
    "cleanlogs" { Invoke-CleanLogs }
    "readme"    { & pwsh -File (Join-Path $Here 'check-readme.ps1'); exit $LASTEXITCODE }
    default     { Write-Host "未知 -Action：$Action"; exit 2 }
}
exit 0
