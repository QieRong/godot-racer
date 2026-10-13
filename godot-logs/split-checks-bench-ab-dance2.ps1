# SPLIT-CHECKS-BENCH-002 A/B 舞步 v2（复现分布版）。
#
# v1 的教训（split-checks-bench-ab-dance.ps1，2026-10-13 20:34-20:38 实证）：
#   ① 台架**逐帧 dump 有相位/墙钟噪声**（同代码两跑 8528 vs 8524 行，difflib 报 12368 行
#      差异，实则只是打印末位 + 交错）→ v1「骨架逐行相同」判据对本族必然假红；
#   ② 可复现对象是**结论矩阵**（6×4 lat_peak / a_brake），但**单格双稳态**（同代码两跑
#      就有 1 格越 1%：45.58 vs 45.05）→ 2+1 份样本分不开「代码差异」与「进程噪声」；
#   ③ 决定性事实：三份日志（mig×2 + HEAD×1）的 **[台架帧] 前 539 帧逐字节完全相同**，
#      且三类配对（含同代码）**首个不同帧都恰在 539** → 分歧起点与代码版本无关。
#   → v2 补样本：steerbench 3 迁移 + 2 HEAD；**brakebench 2 迁移 + 2 HEAD（v1 完全没采）**。
#     判据交给 Python 比对器（组内极差 vs 跨组极差），本脚本只负责采集与安全还原。
#
# 并行对话防御：基准要求「工作区被修改的已跟踪文件只有 main.gd，且 diff 为 +18/-705」。
#   本批的 AGENTS.md ×2 文档同步是**我们自己的**改动 → 先备份再定向 stash 收起来，
#   让工作区回到「只 main.gd 脏」，跑完再 pop 回来并逐字节核验。全程有备份兜底。
#
# 用法：pwsh -NoProfile -File godot-logs\split-checks-bench-ab-dance2.ps1
param(
    [int]$Level = 3
)
$ErrorActionPreference = "Continue"
$Logs = $PSScriptRoot
$Root = Split-Path -Parent $PSScriptRoot
$Summary = Join-Path $Logs "split-checks-bench-ab2-summary.log"
$RunCheck = Join-Path $Root "04-Godot启动器\run-check.ps1"
$Main = Join-Path $Root "godot-racer\scenes\main.gd"
$Module = Join-Path $Root "godot-racer\scripts\checks\bench.gd"
$Bak = Join-Path $Logs "_ab-backup-checks-bench"
$Ag1 = Join-Path $Root "AGENTS.md"
$Ag2 = Join-Path $Root "godot-racer\AGENTS.md"

function Log([string]$m) { $m | Out-File -FilePath $Summary -Encoding utf8 -Append }

function Invoke-Bench([string]$check, [string]$tag, [string[]]$extra) {
    $name = "split-checks-bench-ab2-$check-$tag"
    $logCopy = Join-Path $Logs "$name.log"
    $runLog = Join-Path $Logs "$name.run.log"
    if (Test-Path $logCopy) { Remove-Item $logCopy -Force }
    Log ("--- [{0}] {1}  开始 {2}" -f $check, $tag, (Get-Date -Format "HH:mm:ss"))
    & pwsh -NoProfile -File $RunCheck -Check $check -Level $Level -SkipLint -LogName $name @extra 2>&1 |
        Out-File $runLog -Encoding utf8
    $code = $LASTEXITCODE
    $lines = if (Test-Path $logCopy) { @(Get-Content $logCopy).Count } else { -1 }
    $done = if (Test-Path $logCopy) { @(Get-Content $logCopy | Where-Object { $_ -match '\[CHECK\] 完成' }).Count } else { -1 }
    Log ("--- [{0}] {1}  结束 {2}   exit={3}   行数={4}   [CHECK]完成={5}" -f
        $check, $tag, (Get-Date -Format "HH:mm:ss"), $code, $lines, $done)
}

Log "================ SPLIT-CHECKS-BENCH-002 A/B v2（复现分布）================"
Log ("START {0}   HEAD={1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), (git rev-parse --short HEAD))

New-Item -ItemType Directory -Force -Path $Bak | Out-Null
Copy-Item $Main "$Bak\main.gd.after" -Force
Copy-Item $Module "$Bak\bench.gd" -Force
Copy-Item $Ag1 "$Bak\AGENTS.root.md" -Force
Copy-Item $Ag2 "$Bak\AGENTS.racer.md" -Force
Log "已备份 main.gd / bench.gd / AGENTS.md ×2 到 _ab-backup-checks-bench"

# 本批 AGENTS.md 文档同步先收起来（我们自己的改动，不是并行对话的），跑完 pop 回来
$sA = & git -C $Root stash push -m "AB2-AGENTS-ours" -- AGENTS.md godot-racer/AGENTS.md 2>&1
Log ("stash push[AGENTS]: {0}" -f (($sA -join " ") -replace '\s+', ' '))

# 并行防御
$modified = @(& git -C $Root status --porcelain -uall | Where-Object { $_ -match '^\s*M' })
$diffStat = & git -C $Root diff --numstat -- godot-racer/scenes/main.gd
Log ("stash 前已跟踪修改：{0}" -f (($modified | ForEach-Object { $_.Trim() }) -join " ; "))
Log ("main.gd numstat: {0}" -f ($diffStat -join " "))
if ($modified.Count -ne 1 -or $modified[0] -notmatch 'main\.gd') {
    Log "!! 中止：modified 不止 main.gd（并行对话在动工作区？）"; exit 1
}
if ($diffStat -notmatch '^18\s+705\s') {
    Log "!! 中止：main.gd diff 不是预期的 +18/-705"; exit 1
}
Log "  防御通过：唯一修改 = main.gd（+18/-705）；AGENTS.md ×2 已另行暂存"

# Phase A：迁移后
Invoke-Bench "steerbench" "s3" @()
Invoke-Bench "brakebench" "k1" @("-NoAi")
Invoke-Bench "brakebench" "k2" @("-NoAi")

# 切到 HEAD（只收 main.gd）
$s1 = & git -C $Root stash push -m "AB2-MAINGD-CTRL" -- godot-racer/scenes/main.gd 2>&1
Log ("stash push[main.gd]: {0}" -f (($s1 -join " ") -replace '\s+', ' '))
Log ("  模块在盘（应 True）: {0}   main.gd 行数（应 4033）: {1}" -f (Test-Path $Module), @(Get-Content $Main).Count)

# Phase B：HEAD 代码
Invoke-Bench "steerbench" "c2" @()
Invoke-Bench "brakebench" "j1" @("-NoAi")
Invoke-Bench "brakebench" "j2" @("-NoAi")

# 还原 main.gd
$p1 = & git -C $Root stash pop 2>&1
Log ("stash pop[main.gd]: {0}" -f (($p1 -join " ") -replace '\s+', ' '))
Log ("  main.gd 行数（应 3346）: {0}" -f @(Get-Content $Main).Count)

# 还原 AGENTS.md ×2
$p2 = & git -C $Root stash pop 2>&1
Log ("stash pop[AGENTS]: {0}" -f (($p2 -join " ") -replace '\s+', ' '))

# 核验还原（行尾无关：用 git diff --numstat 比内容行数）
$agStat = & git -C $Root diff --numstat -- AGENTS.md godot-racer/AGENTS.md
Log ("  还原后 AGENTS.md numstat: {0}" -f ($agStat -join " | "))
$stashLeft = @(& git -C $Root stash list)
Log ("  stash 剩余: {0}" -f $(if ($stashLeft.Count -eq 0) { "无（干净）" } else { $stashLeft -join " ; " }))
Log "DONE"
