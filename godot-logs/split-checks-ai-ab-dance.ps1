# SPLIT-CHECKS-AI-003 行为等价 A/B 舞步（每趟一个 -Pass，避免单次调用过长）。
#
# 设计（4 趟 = 两组 × 各两跑）：
#   m1 / m2 = 迁移态（main.gd 走模块）两跑   —— 同代码噪声底 #1
#   c1 / c2 = HEAD 态（main.gd 原始）两跑   —— 同代码噪声底 #2
# 判据：跨组差必须 ≤ 同代码组内极差（数据驱动，不靠拍的阈值）。
#
# 5 个 check：opponents / aidiag / avoid / obstacles / aistart（关卡与 run-all-checks 对齐）。
# 唯一墙钟源：run_opponents 的 `对手用时 %.1f 秒（%d 帧）`（Time.get_ticks_msec）——
# 比对时秒数会被归一化，帧数与其余行必须逐字相同。
#
# 用法：pwsh -File godot-logs\split-checks-ai-ab-dance.ps1 -Pass m1
param(
    [Parameter(Mandatory = $true)][string]$Pass,   # m1 | c1 | m2 | c2 | m3..
    [string]$Only = ""                             # 只跑某个 check（补样本用）
)
$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
$Launcher = Join-Path $Root "04-Godot启动器\run-check.ps1"
$Live = Join-Path $Root "godot-logs\_ai-livedance"
$Target = Join-Path $Root "godot-racer\scenes\main.gd"
$Migrated = Join-Path $Live "main.gd.migrated"
$Head = Join-Path $Live "main.gd.head"

if (-not (Test-Path $Head)) {
    # git show 输出 LF；用 cmd 重定向保字节（管道 + Set-Content 会按行重组）
    cmd /c "git -C `"$Root`" show HEAD:godot-racer/scenes/main.gd > `"$Head`""
}

$state = switch -Wildcard ($Pass) {
    "m*" { "m" } "c*" { "c" }
    default { "" }
}
if ($state -eq "") { Write-Host "!! -Pass 必须是 m<n>|c<n>"; exit 2 }

# 设定状态并自检 md5
$src = if ($state -eq "m") { $Migrated } else { $Head }
if (-not (Test-Path $src)) { Write-Host "!! 源不存在: $src"; exit 2 }
Copy-Item $src $Target -Force
$h = (Get-FileHash $Target -Algorithm SHA256).Hash
$hm = (Get-FileHash $Migrated -Algorithm SHA256).Hash
$hh = (Get-FileHash $Head -Algorithm SHA256).Hash
Write-Host ("[dance] Pass={0} 状态={1} main.gd sha={2}（migrated={3} head={4}）" -f
    $Pass, $state, $h.Substring(0, 12), $hm.Substring(0, 12), $hh.Substring(0, 12))
if ($state -eq "m" -and $h -ne $hm) { Write-Host "!! 迁移态 md5 不符"; exit 3 }

# 每趟开头跑一次 lint + parse（不靠 run-check 的 preflight，省掉 5 次重复）
& pwsh -File (Join-Path $Root "04-Godot启动器\lint-gdscript.ps1") | Out-Null
$lintExit = $LASTEXITCODE
& pwsh -File (Join-Path $Root "04-Godot启动器\parse-check.ps1") | Out-Null
$parseExit = $LASTEXITCODE
Write-Host ("[dance] preflight lint={0} parse={1}" -f $lintExit, $parseExit)
if ($lintExit -ne 0 -or $parseExit -ne 0) { Write-Host "!! preflight 失败，本趟中止"; exit 4 }

# check -> level（与 run-all-checks.ps1 对齐）
$plan = @(
    @{ c = "opponents"; lv = 4 },
    @{ c = "aidiag";    lv = -1 },
    @{ c = "avoid";     lv = 4 },
    @{ c = "obstacles"; lv = 4 },
    @{ c = "aistart";   lv = 4 }
)
if ($Only -ne "") { $plan = @($plan | Where-Object { $_.c -eq $Only }) }
if ($plan.Count -eq 0) { Write-Host "!! -Only 不匹配任何 check"; exit 2 }

foreach ($p in $plan) {
    $c = $p.c
    $lv = $p.lv
    $logName = "split-checks-ai-ab-$Pass-$c"
    # ⚠ 不能用 $args（PowerShell 自动变量）
    $rcArgs = @("-File", $Launcher, "-Check", $c, "-SkipLint", "-LogName", $logName)
    if ($lv -ge 0) { $rcArgs += @("-Level", "$lv") }
    $t0 = Get-Date
    & pwsh @rcArgs | Out-Null
    $rc = $LASTEXITCODE
    $dt = [int]((Get-Date) - $t0).TotalSeconds
    $lp = Join-Path $Root "godot-logs\$logName.log"
    $hasDone = if (Test-Path $lp) { (Get-Content $lp -Raw) -match '\[CHECK\] 完成' } else { $false }
    Write-Host ("[dance] {0} {1,-10} rc={2} {3,4}s 完成={4}" -f $Pass, $c, $rc, $dt, $hasDone)
}

# 收尾：一律回到迁移态（避免下一趟/后续步骤看到半途状态）
Copy-Item $Migrated $Target -Force
$h2 = (Get-FileHash $Target -Algorithm SHA256).Hash
Write-Host ("[dance] 收尾回到迁移态 sha={0}（期望 {1}）" -f $h2.Substring(0, 12), $hm.Substring(0, 12))
if ($h2 -ne $hm) { Write-Host "!! 收尾恢复失败"; exit 5 }
Write-Host "[dance] Pass=$Pass 结束"
