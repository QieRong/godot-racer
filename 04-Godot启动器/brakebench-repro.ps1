# brakebench 跨进程复现检查：A/B/C 各冷启动一次，逐格比整表极差。
#
# ⚠ 本脚本**绝不**注册进 run-all-checks.ps1（同 steerbench-repro.ps1 的两个理由）：
#   ① 慢：单次 brakebench 约 1~2 分钟（4 初速 × 3 次重复，每格刹停即止），跑 3 次 ≈ 5 分钟，
#      塞进日常验收会拖垮 -Quick；
#   ② 更硬的原因：往 run-all-checks.ps1 的 $all 里加一项会增加 `@{ n='` 的**条数**，
#      直接破坏 check-readme.ps1 / check-docs.ps1 的「N 项 ↔ 文档计数」契约。所以它必须独立。
#
# 背景（Step 1d 2026-10-12）：a_brake 是 B 方案（把 racing_line.brake_distance() 接进 AI 限速链、
#   替换 probe 分支瞬时余隙二次式）的硬前置，当前文档里的 6.0 是单测假设值。
#   同 steerbench 的理由：格内重复因仿真**完全确定**（同摆位 + 同初速 + 无随机数）⇒ 同格 3 次
#   跑出逐字节相同的结果 ⇒ 格内标准差恒 0、无判别力；真正有判别力的是**跨进程**复现：
#   同机、同二进制、分别冷启动 A/B/C 三次，看整表是否一致。
#
# 判据：逐格算跨进程**相对极差** = (max(a,b,c) - min(a,b,c)) / mean(a,b,c)，阈值 1%（$ReproLimit）。
#   某格三值均值 < 0.05（近零，例如该格没采到稳态帧）→ **跳过**并在报告里单列（避免除零放大假阳）。
#   全部有效格 ≤ 1% → exit 0（打印每格三值与极差）；否则打印所有越界格 → exit 1。
#
# 用法：pwsh -File .\brakebench-repro.ps1 -Level 2        # L3 μ=0.7
#       pwsh -File .\brakebench-repro.ps1 -Level 3        # L4 荒漠 μ=0.85
#       pwsh -File .\brakebench-repro.ps1 -Level 4        # L5 极地 μ=0.5
param(
    [int]$Level = 3,
    [int]$MaxTries = 2,
    # 跨进程复现相对极差阈值：1%
    [double]$ReproLimit = 0.01
)

$ErrorActionPreference = "Continue"

# 与 run-all-checks.ps1 同一理由：本机默认控制台是 gb2312(CP936)，中文/符号会坏；报告要可读。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$LogDir = Join-Path $Root "godot-logs"

# 与 main.gd::_check_brakebench 的 speeds / repeats 保持一致（仅用于定位行列）
$Speeds = @(40, 60, 80, 100)
$Repeats = 3
# 近零跳过线：三值均值低于此的格不参与极差（避免除零放大假阳）
$ZeroMean = 0.05

## 从一份日志里解析 brakebench 的 4×3 矩阵（a_brake 均值 m/s²）。
## 返回 hashtable（键 "初速|重复次序"，值 = double）；解析不到 4 行则返回 $null。
function Parse-BrakebenchMatrix([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    $lines = Get-Content $path -Encoding UTF8
    $inMatrix = $false
    $rows = 0
    $res = @{}
    foreach ($line in $lines) {
        if (-not $inMatrix) {
            # 矩阵表头形如： [自检] 台架刹   初速度\重复         1        2        3
            if ($line -match '初速度\\重复') { $inMatrix = $true }
            continue
        }
        if ($rows -ge 4) { break }
        # 数据行形如： [自检] 台架刹      40.0      8.12     8.11     8.12
        $m = [regex]::Match($line, '^\[自检\]\s*台架刹\s+([0-9]+\.[0-9]+)\s+([0-9]+\.[0-9]+)\s+([0-9]+\.[0-9]+)\s+([0-9]+\.[0-9]+)\s*$')
        if ($m.Success) {
            $v0 = [double]$m.Groups[1].Value
            for ($c = 0; $c -lt $Repeats; $c++) {
                $res[('{0:F1}|{1}' -f $v0, ($c + 1))] = [double]$m.Groups[$c + 2].Value
            }
            $rows++
        }
    }
    if ($rows -lt 4) { return $null }
    return $res
}

$runs = @('A', 'B', 'C')
$parsed = @{}

foreach ($r in $runs) {
    $logName = "brakebench-repro-$($r)-L$($Level)"
    Write-Host ("==== 跨进程复现：第 {0} 次（LogName={1}）====" -f $r, $logName)
    # -NoAi：台架车要停在起终点直道上刹停，AI 对手可能绕上来撞到它、污染减速度读数。
    # 这是一次**测量**，与对手 AI 无关，去掉它只减少噪声（main.gd --noai 是既有开关）。
    & pwsh -File (Join-Path $Here 'run-check.ps1') -Check brakebench -Level $Level -MaxTries $MaxTries -NoAi -LogName $logName
    $code = $LASTEXITCODE
    $logPath = Join-Path $LogDir "$logName.log"
    $mat = Parse-BrakebenchMatrix $logPath
    if ($null -eq $mat) {
        Write-Host ("!! 第 {0} 次没能从 {1} 解析出完整 4×3 矩阵（run-check 退出码 {2}）" -f $r, $logName, $code) -ForegroundColor Red
        $parsed[$r] = $null
    } else {
        Write-Host ("-- 第 {0} 次解析到 4×3 矩阵 ✔" -f $r)
        $parsed[$r] = $mat
    }
}

# 三次都要有矩阵才能比对（缺任一次直接判失败 —— 没有对照样本等于没测）
$missing = @($runs | Where-Object { $null -eq $parsed[$_] })
if ($missing.Count -gt 0) {
    Write-Host ("✘ 缺少复现样本：{0}（没有完整矩阵，无法比对）" -f ($missing -join ', ')) -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host ("==== 逐格跨进程相对极差（阈值 {0}%）====" -f ($ReproLimit * 100.0))

$violations = @()
$skipped = @()
$maxRR = -1.0
$maxAt = ""

foreach ($v in $Speeds) {
    foreach ($r in 1..$Repeats) {
        $key = ('{0:F1}|{1}' -f $v, $r)
        $a = [double]$parsed['A'][$key]
        $b = [double]$parsed['B'][$key]
        $c = [double]$parsed['C'][$key]
        $mean = ($a + $b + $c) / 3.0
        $label = ("v0={0} 第{1}次" -f $v, $r)
        if ($mean -lt $ZeroMean) {
            $skipped += [pscustomobject]@{ 格 = $label; A = $a; B = $b; C = $c; 均值 = $mean }
            continue
        }
        $mx = [Math]::Max($a, [Math]::Max($b, $c))
        $mn = [Math]::Min($a, [Math]::Min($b, $c))
        $rr = ($mx - $mn) / $mean
        if ($rr -gt $maxRR) { $maxRR = $rr; $maxAt = $label }
        $flag = if ($rr -gt $ReproLimit) { "  ← 越界" } else { "" }
        Write-Host ("  {0,-16} A={1,8:F3} B={2,8:F3} C={3,8:F3} 均值={4,8:F3} 极差={5,7:F4}%{6}" `
            -f $label, $a, $b, $c, $mean, ($rr * 100.0), $flag)
        if ($rr -gt $ReproLimit) {
            $violations += [pscustomobject]@{ 格 = $label; A = $a; B = $b; C = $c; 均值 = $mean; 极差 = $rr }
        }
    }
}

if ($skipped.Count -gt 0) {
    Write-Host ""
    Write-Host ("注：{0} 格因三值均值 < {1}（近零，可能该格没采到稳态帧）被**跳过**、不参与极差：" -f $skipped.Count, $ZeroMean)
    foreach ($k in $skipped) {
        Write-Host ("  跳过 {0,-16} A={1,8:F3} B={2,8:F3} C={3,8:F3} 均值={4,8:F3}" -f $k.格, $k.A, $k.B, $k.C, $k.均值)
    }
}

Write-Host ""
if ($violations.Count -eq 0) {
    Write-Host ("✔ 跨进程复现通过：全部有效格极差 ≤ {0}%（实测最大 {1:F4}% 位于 {2}）" -f ($ReproLimit * 100.0), ($maxRR * 100.0), $maxAt) -ForegroundColor Green
    exit 0
}
Write-Host ("✘ 跨进程复现失败：{0} 格极差 > {1}%（实测最大 {2:F4}% 位于 {3}）" -f $violations.Count, ($ReproLimit * 100.0), ($maxRR * 100.0), $maxAt) -ForegroundColor Red
foreach ($x in $violations) {
    Write-Host ("  ✘ {0,-16} A={1,8:F3} B={2,8:F3} C={3,8:F3} 均值={4,8:F3} 极差={5,7:F4}%" -f $x.格, $x.A, $x.B, $x.C, $x.均值, ($x.极差 * 100.0))
}
exit 1
