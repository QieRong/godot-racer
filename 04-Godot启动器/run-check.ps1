# 跑一次游戏内自检并抓取结果。
#
# 为什么要重试：这台机器上 Godot 4.4.1 的**启动期**偶发 signal 11 段错误
# （和项目代码无关，空场景也会），所以验收脚本必须能自动重跑。
#
# 用法：
#   pwsh -File .\run-check.ps1 -Check enclosure
#   pwsh -File .\run-check.ps1 -Check opponents -Level 4     # 指定关卡（0 起）
#   pwsh -File .\run-check.ps1 -Check opponents -Level 3 -LogName ab-A1   # 写入独立日志
#   pwsh -File .\run-check.ps1 -Check enclosure -RenderFps 120            # 用 120 FPS 跑一遍
#   pwsh -File .\run-check.ps1 -Check aidiag                              # 冻结带回放（默认）
#   pwsh -File .\run-check.ps1 -Check aidiag -AiTapeMode calibrate -AiTapeOutput ..\a.json  # 生成候选带
#
# 退出码：0 通过；2 参数错 / 找不到 Godot；3 没有日志产出；4 preflight lint 未过；
#         5 日志含解析/编译失败；6 parse-check 未过；
#         8 aidiag 冻结输入带不可用（测量条件未建立，未启动 Godot）。
param(
    [string]$Check = "enclosure",
    [int]$MaxTries = 6,
    [int]$TimeoutSec = 120,
    [int]$Level = -1,
    # REL-STEP2A：临时用指定**渲染**帧率跑这一项（60 / 120）。0 = 不加这个参数
    # （沿用玩家存档 / 工程默认 60）。物理始终 120 Hz，不受它影响。
    # ⚠ 它**不会**改写玩家存档里的帧率 —— GameState 侧走的是"覆盖不落盘"那条路。
    [int]$RenderFps = 0,
    [switch]$NoAi,
    [switch]$SkipLint,
    # A/B 实验用：把日志写到 godot-logs<LogName>.log 而不是默认的 check-<Check>.log。
    # 为什么必须有这个参数：默认日志名只由 -Check 决定，所以**两个并行的 A/B 组会互相覆盖**
    # （2026-09-23 实测：A 组和 B 组的 "结果" 是同一份日志，字节数完全一样 —— 这种假对照比没有对照更危险）。
    # 不传时行为与以前完全一致。
    [string]$LogName = "",
    [ValidateSet('replay','calibrate')][string]$AiTapeMode = 'replay',
    [string]$AiTapeManifest = '',
    [string]$AiTapeOutput = ''
)

if ($RenderFps -ne 0 -and $RenderFps -ne 60 -and $RenderFps -ne 120) {
    Write-Host "-RenderFps 只接受 60 / 120（收到 $RenderFps）" -ForegroundColor Red
    exit 2
}

$ErrorActionPreference = "Continue"
$Godot = "E:\godot\Godot_v4.4.1-stable_win64.exe"
$ProjDir = Split-Path -Parent $PSScriptRoot
$LogPath = if ($LogName) {
    Join-Path $ProjDir "godot-logs\$LogName.log"
} else {
    Join-Path $ProjDir "godot-logs\check-$Check.log"
}

# 每项检查都有**自己合理的**最短等待时间，别用统一的 120 秒卡死它们。
# 踩过的坑：--check=lap 内部允许跑 6 分钟，我给了 260 秒，结果它在第 2 圈就被杀掉，
# 日志里只剩下 1 圈的圈速，于是"上圈 == 最快"被判成**圈速异常** ——
# 看起来像代码回归，其实是检查脚本把进程掐了。这类假红灯最浪费时间。
$minTimeout = switch ($Check) {
    "lap"       { 420 }
    "opponents" { 320 }
    "stress"    { 260 }
    "phys"      { 240 }
    "friction"  { 260 }
    # steerbench 要跑 4 速度 × 6 舵角 × 3 次重复（约 68s 纯测量）+ 冷启动，
    # 给 300s 免得像 lap 那样被超时掐断、只剩半张矩阵。
    "steerbench"{ 300 }
    # brakebench 要跑 4 初速 × 3 次重复（每格刹停即止，约 3~6s/格）+ 冷启动，
    # 同 steerbench 给 300s（低抓地档减速慢，单格窗口给到 12s）。
    "brakebench"{ 300 }
    "weather"   { 220 }
    "aistart"   { 200 }
    "obstacles" { 180 }
    "avoid"     { 220 }
    "minimap"   { 160 }
    "wallslide" { 200 }
    "pause"     { 180 }
    "aidiag"    { 220 }
    "flip"      { 280 }
    "layout"    { 160 }
    "reverse"   { 220 }
    default     { 140 }
}
if ($TimeoutSec -lt $minTimeout) {
    Write-Host "（$Check 至少需要 $minTimeout 秒，已把 $TimeoutSec 提升到 $minTimeout，避免误杀）"
    $TimeoutSec = $minTimeout
}

# ---- aidiag 冻结带预检：启动 Godot **之前**，缺带/作废秒级失败 ----
# 正式验收只走已冻结输入带回放（-AiTapeMode replay 默认）；实时驱动仅用于
# calibrate 生成候选带，**不做静默兜底**（题 D 裁定：测量条件未建立 = 非通过）。
# 为什么要前置：冻结带缺失/作废时，引擎内要到一次冷启动（220s×MaxTries）后才报
# TAPE_NOT_FROZEN；预检把它压到秒级。完整契约见 tape-preflight.ps1 头注。
$tapePreflight = Join-Path $PSScriptRoot 'tape-preflight.ps1'
if (-not (Test-Path $tapePreflight)) {
    Write-Host "!! tape-preflight.ps1 缺失：aidiag 测量条件无法预检，拒绝启动 Godot" -ForegroundColor Red
    exit 8
}
& $tapePreflight -Check $Check -AiTapeMode $AiTapeMode -AiTapeManifest $AiTapeManifest -ProjDir $ProjDir
if ($LASTEXITCODE -eq 8) { exit 8 }

if (-not (Test-Path $Godot)) { Write-Host "找不到 Godot: $Godot"; exit 2 }

# ---- preflight：先静态检查 GDScript，再花时间启动 Godot ----
# 为什么值得：一行 print 里的直引号会让 main.gd **整个解析失败**，
# 表现却是"赛道不生成、车自由落体、每个关卡都坏" —— 极难从现象反推。
# 这个坑踩了两次，所以现在把它挡在启动之前（省下几分钟才发现问题的成本）。
if (-not $SkipLint) {
    $lint = Join-Path $PSScriptRoot "lint-gdscript.ps1"
    if (Test-Path $lint) {
        & pwsh -File $lint | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "!! preflight 未通过：先修掉上面的引号问题再跑检查（否则 main.gd 会整个加载失败）"
            exit 4
        }
    }
}

# 真·语法检查：跑 Godot 解析器，拦「类型推断 / 引号」这类会让整个脚本加载失败的错误。
# 必须在启动正式检查之前 —— 一旦 main.gd 解析失败，检查日志里照样有大量正常的
# [自检] 输出（来自其它脚本），只看那些会以为一切正常。
if (-not $SkipLint) {
    $pc = Join-Path $PSScriptRoot "parse-check.ps1"
    if (Test-Path $pc) {
        & pwsh -File $pc
        if ($LASTEXITCODE -ne 0) {
            Write-Host "!! preflight 未通过：脚本解析失败，本次检查结果会全部无效（赛道不会生成）" -ForegroundColor Red
            exit 6
        }
    }
}
# README 一致性：**只警告、不拦住检查**。
# 文档过时不影响物理验收，所以不该因为它让检查跑不起来；
# 但每次运行都提醒一次，免得它无声无息地烂掉。
# （要"拦住"的用法见 run-all-checks.ps1 的 readme 项 / 启动器菜单 13）
if (-not $SkipLint) {
    $readmeCheck = Join-Path $PSScriptRoot "check-readme.ps1"
    if (Test-Path $readmeCheck) {
        $rout = & pwsh -File $readmeCheck 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host ""
            Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
            $rout | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
            Write-Host "  （只是提醒：README 该更新了，不影响本次检查结果）" -ForegroundColor Yellow
            Write-Host "------------------------------------------------------------" -ForegroundColor Yellow
        }
    }
}

# 关卡参数是可选的：不传就沿用 GameState 默认关卡
$userArgs = @("--check=$Check")
if ($Level -ge 0) { $userArgs += "--level=$Level" }
if ($NoAi) { $userArgs += "--noai" }
if ($RenderFps -gt 0) { $userArgs += "--render-fps=$RenderFps" }
if ($Check -eq 'aidiag') {
    $userArgs += "--ai-tape-mode=$AiTapeMode"
    if ($AiTapeManifest.Contains('"') -or $AiTapeOutput.Contains('"')) { Write-Host '输入带文件路径不得包含双引号'; exit 2 }
    if ($AiTapeManifest) { $userArgs += ('"--ai-tape-manifest=' + $AiTapeManifest + '"') }
    if ($AiTapeOutput) { $userArgs += ('"--ai-tape-output=' + $AiTapeOutput + '"') }
}

for ($i = 1; $i -le $MaxTries; $i++) {
    Remove-Item $LogPath -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath $Godot `
        -ArgumentList (@('--path', '.', '--log-file', $LogPath, '--') + $userArgs) `
        -WorkingDirectory (Join-Path $ProjDir 'godot-racer') `
        -NoNewWindow -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $ok = $false
    $evidenceKilled = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-Path $LogPath) {
            $txt = Get-Content $LogPath -Raw -ErrorAction SilentlyContinue
            if ($txt -and $txt -match '\[CHECK\] 完成') {
                $ok = $true
                # 登记模式只在既有 deadline 内等真实退出，不把完成标志当进程退出码。
                if (-not $env:AC13_RUN_IDENTITY) { break }
            }
        }
        if ($p.HasExited) { break }
    }
    if (-not $p.HasExited) { $evidenceKilled = $true; $p.Kill() | Out-Null; Start-Sleep -Seconds 1 }
    # 只附加事实回执；保留原来的退出/重试决策。AC-13 登记器强制 MaxTries=1。
    if ($env:AC13_RUN_IDENTITY) {
        $evidenceIdentity = $env:AC13_RUN_IDENTITY | ConvertFrom-Json
        $p.Refresh()
        $evidenceReceipt = [ordered]@{
            run_id = $evidenceIdentity.run_id; attempt = $i
            exit_code = $p.ExitCode; killed = $evidenceKilled
            timed_out = ($evidenceKilled -and (Get-Date) -ge $deadline)
        }
        Add-Content -LiteralPath $LogPath -Encoding utf8 -Value ('PROCESS|' + ($evidenceReceipt | ConvertTo-Json -Compress))
    }
    if ($ok) { Write-Host "== 第 $i 次尝试成功 =="; break }
    Write-Host "== 第 $i 次尝试失败（大概率是启动期段错误），重试 =="
}

if (-not (Test-Path $LogPath)) { Write-Host "没有日志产出"; exit 3 }
Write-Host "---- 自检结果 ----"
Get-Content $LogPath | Select-String -Pattern '\[自检\]|\[CHECK\]|护栏环闭合|护栏已生成|SCRIPT ERROR|ERROR: ' |
    ForEach-Object { $_.Line }

# ---- 脚本级解析/编译失败：必须显式失败，不能混在"检查跑了"里 ----
# 为什么单列一条：main.gd 一旦解析失败，日志里**照样有**大量正常的 [自检] 输出
# （那些来自 vehicle.gd 等其它脚本），输出了"完成"也照样退出 0，
# 但实际上赛道没生成、车在自由落体。如果只看 [自检] 行会以为一切正常。
$logText = Get-Content $LogPath -Raw
$parseBad = [regex]::Matches($logText,
    'Parse Error|Failed to load script|Compilation failed|Script inherits from native type.*cannot|Invalid call\. Nonexistent function')
if ($parseBad.Count -gt 0) {
    Write-Host ""
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    Write-Host "!! 脚本解析/编译失败：本次结果**全部无效**（赛道不会生成、车会掉下去）"
    Write-Host "!! 命中 $($parseBad.Count) 处，逐条如下："
    Get-Content $LogPath | Select-String -Pattern 'Parse Error|Failed to load script|Compilation failed|Invalid call' |
        Select-Object -First 20 | ForEach-Object { Write-Host "!!   $($_.Line)" }
    Write-Host "!! 提示：先跑 lint-gdscript.ps1；类型推断错误（Cannot infer the type）"
    Write-Host "!!       需要给 var 显式标注类型，见 main.gd 里的相关注释。"
    Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    exit 5
}
exit 0
