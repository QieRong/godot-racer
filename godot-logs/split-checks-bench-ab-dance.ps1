# SPLIT-CHECKS-BENCH-002 行为等价 A/B（stash 舞步，背靠背）。
#
# 对照组 = HEAD 的 main.gd（stash 后，bench 两族还在 main.gd 里内联实现）；
# 改动后 = pop 后（两族外迁到 scripts/checks/bench.gd）。
# **必须背靠背**：同代码跨进程间隔 5 分钟实测差异 25854 行（AGENTS §4.3）。
#
# ⚠ 为什么用**定向 pathspec** 而不是 `git stash -u`（同 layout 批）：
#   ① 整仓 stash -u 会把 godot-logs 下的证据文件（structcheck 红绿日志、本脚本）
#      一起卷走，pop 前它们不在盘上；
#   ② 只收 main.gd：新模块 bench.gd(+.uid) 是**未跟踪**文件、不在 pathspec 里，
#      全程留在盘上 —— ctrl 环境 = 纯 HEAD 代码 + 模块在盘但没人引用。
#
# ⚠ 并行对话防御（2026-10-13 新增，同 layout 批）：stash 前核验 git status 中
#   **被修改的已跟踪文件只有 main.gd 一个**，且 main.gd 的 diff 行数符合本次迁移
#   （+18/-705 量级）。若出现别的脏文件（并行对话的未提交成果），立即中止 ——
#   绝不动别人的工作区。
#
# ⚠ 噪声底判据的推导（本族与 layout 批的本质不同，动手前已实证）：
#   steerbench / brakebench **不在 run-all-checks.ps1**（刻意不注册，否则破坏
#   check-readme 的「N 项 ↔ 文档计数」契约），所以本舞步是这两族**主要的行为验证**。
#   台架逐帧采样物理，但日志里混着两类**跨进程不可复现**的内容（04-Godot启动器/
#   *-repro.ps1 的历史证据：steerbench 三连最大极差 0.02%、brakebench 同理 ≤1%）：
#     ① 实例 ID（VehicleBody3D#39191577946 等，每次冷启动不同）；
#     ② `[车辆] t=` 诊断块 —— 按**墙钟**打印，负载一变同一个 t=2.3s 的物理步数
#        就不同，位置/数值都不稳定（AGENTS §4.3「双稳态」同源）。
#   因此同代码两跑**不可能逐字节相同**（layout 批的纯函数族才可以）：
#     · base1 vs base2 先量噪声底：台架证据行（[台架帧]/[台架刹帧]/[自检] 台架*/
#       [CHECK] 行）归一化实例 ID 后若逐行相同 → 判据用「逐行相同」；
#     · 否则 → 判据 = 「结构相同（数值Mask后骨架逐行相同）+ 数值相对极差
#       ≤ min(实测噪声底, 1%)」—— 1% 是本项目自己的跨进程复现阈值
#       （steerbench-repro.ps1 / brakebench-repro.ps1 的 $ReproLimit）。
#   **永远不许为变绿放宽**：若 ctrl/after 的极差超过 min(底, 1%)，脚本判 FAIL 并
#   落差异画像，人工核完再谈结论。
#
# 模式指纹（同 layout 批）：最后一个 `[车辆] t=` 诊断块相对检查输出的位置
# （stdout/stderr 合流次序会翻）。ctrl 与 after 必须同模式，此时的台架行比对
# 才是有效证据；块计数也一并记录（墙钟打印，计数允许不同，属文档化噪声）。
#
# 用法：pwsh -File godot-logs\split-checks-bench-ab-dance.ps1
param(
    [string]$Group = "bench"
)
$ErrorActionPreference = "Continue"
$Logs = $PSScriptRoot                       # godot-logs
$Root = Split-Path -Parent $PSScriptRoot    # git 根
$Summary = Join-Path $Logs "split-checks-bench-ab-summary.log"
$RunCheck = Join-Path $Root "04-Godot启动器\run-check.ps1"
$Main = Join-Path $Root "godot-racer\scenes\main.gd"
$Module = Join-Path $Root "godot-racer\scripts\checks\bench.gd"
$Bak = Join-Path $Logs "_ab-backup-checks-bench"

function Log([string]$m) { $m | Out-File -FilePath $Summary -Encoding utf8 -Append }

# 负载背景：并行会话可能在跑 Blender 重活，记一笔（台架按物理帧采样，本应与负载
# 无关；但 [车辆] 墙钟块与合流次序受负载影响，留痕便于事后解释模式差异）。
function Log-Load([string]$tag) {
    $blender = @(Get-Process blender -ErrorAction SilentlyContinue).Count
    $godot = @(Get-Process godot -ErrorAction SilentlyContinue).Count
    Log ("  → 负载背景[{0}]: blender 进程={1}，godot 进程={2}" -f $tag, $blender, $godot)
}

# 跑一次 run-check 并记录 exit / 日志行数 / 台架行数 / 模式指纹
# $extra：逐字透传 run-check.ps1 的附加参数（brakebench 的 -NoAi 等）。
function Invoke-Check([string]$check, [string]$tag, [string[]]$extra = @()) {
    $logCopy = Join-Path $Logs "split-checks-bench-ab-$check-$tag.log"
    $runLog = Join-Path $Logs "split-checks-bench-ab-$check-$tag.run.log"
    Log ("--- [{0}/{1}] {2}  开始 {3}" -f $Group, $check, $tag, (Get-Date -Format "HH:mm:ss"))
    Log-Load $tag
    if (Test-Path $logCopy) { Remove-Item $logCopy -Force }
    & pwsh -NoProfile -File $RunCheck -Check $check -Level 3 -SkipLint -LogName "split-checks-bench-ab-$check-$tag" @extra 2>&1 |
        Out-File $runLog -Encoding utf8
    $code = $LASTEXITCODE
    $logLines = if (Test-Path $logCopy) { @(Get-Content $logCopy).Count } else { -1 }
    $benchLines = if (Test-Path $logCopy) {
        @(Get-Content $logCopy | Where-Object { $_ -match '^\[台架帧\]|^\[台架刹帧\]|^\[自检\] 台架|^\[CHECK\]' }).Count } else { -1 }
    $done = if (Test-Path $logCopy) {
        @(Get-Content $logCopy | Where-Object { $_ -match '\[CHECK\] 完成' }).Count } else { -1 }
    Log ("--- [{0}/{1}] {2}  结束 {3}   exit={4}   日志行数={5}   台架证据行={6}   [CHECK]完成={7}" -f
        $Group, $check, $tag, (Get-Date -Format "HH:mm:ss"), $code, $logLines, $benchLines, $done)
    # 模式指纹：最后一个 [车辆] 诊断块相对检查输出的位置（合流次序会翻，见文件头）
    if (Test-Path $logCopy) {
        $ls = @(Get-Content $logCopy)
        $blk = @()
        for ($i = 0; $i -lt $ls.Count; $i++) { if ($ls[$i].StartsWith('[车辆] t=')) { $blk += $i } }
        $chk = -1
        for ($i = 0; $i -lt $ls.Count; $i++) { if ($ls[$i].StartsWith('[自检] 台架')) { $chk = $i; break } }
        $mode = "?"
        $lastBlk = -1
        if ($blk.Count -gt 0 -and $chk -ge 0) {
            $lastBlk = $blk[$blk.Count - 1]
            if ($lastBlk -lt $chk) { $mode = "A（末块在检查输出前）" } else { $mode = "B（末块在检查输出后）" }
        }
        Log ("  → 模式指纹[{0}/{1}]: 共 {2} 个车辆块，末块@{3}，检查首行@{4} = {5}" -f
            $check, $tag, $blk.Count, $lastBlk, $chk, $mode)
    }
}

# 归一化：实例 ID #<数字> → #ID（AGENTS §4.3）
function Get-NormLines([string]$p) {
    @(Get-Content $p) | ForEach-Object { $_ -replace '#[0-9]+', '#ID' }
}

# 数值Mask：把所有数值（含符号/小数/科学计数字面）换成 #，只留骨架
function Get-Skeleton([string[]]$lines) {
    $lines | ForEach-Object { $_ -replace '[-+]?[0-9]+\.?[0-9]*([eE][-+]?[0-9]+)?', '#' }
}

# 台架证据行（行为等价判定对象）：逐帧 dump + 摘要/矩阵/判定 + CHECK 行
function Get-BenchLines([string]$p) {
    @(Get-Content $p) | Where-Object { $_ -match '^\[台架帧\]|^\[台架刹帧\]|^\[自检\] 台架|^\[CHECK\]' } |
        ForEach-Object { $_ -replace '#[0-9]+', '#ID' }
}

# 逐行配对算数值相对极差（行数必须已校验相等）。返回 @{ ok; worst; where; bad }。
function Get-NumSpread([string[]]$a, [string[]]$b) {
    $worst = 0.0
    $where = "（无数值差异）"
    $bad = @()
    for ($i = 0; $i -lt $a.Count; $i++) {
        $na = @([regex]::Matches($a[$i], '[-+]?[0-9]+\.?[0-9]*') | ForEach-Object { [double]$_.Value })
        $nb = @([regex]::Matches($b[$i], '[-+]?[0-9]+\.?[0-9]*') | ForEach-Object { [double]$_.Value })
        if ($na.Count -ne $nb.Count) {
            $bad += ("证据行L{0} 数值个数不同（{1} vs {2}）：{3}" -f ($i + 1), $na.Count, $nb.Count, $a[$i])
            continue
        }
        for ($k = 0; $k -lt $na.Count; $k++) {
            $d = [math]::Abs($na[$k] - $nb[$k])
            $m = [math]::Max([math]::Abs($na[$k]), [math]::Abs($nb[$k]))
            if ($m -lt 1e-9) { continue }
            $r = $d / $m
            if ($r -gt $worst) {
                $worst = $r
                $where = ("证据行L{0} 字段{1}: {2} vs {3}" -f ($i + 1), ($k + 1), $na[$k], $nb[$k])
            }
        }
    }
    return @{ ok = ($bad.Count -eq 0); worst = $worst; where = $where; bad = $bad }
}

# 一组比对：返回判据文本 + 是否通过 + 明细
function Compare-Pair([string]$check, [string]$tagA, [string]$tagB, [string]$label, [double]$floorSpread) {
    $pa = Join-Path $Logs "split-checks-bench-ab-$check-$tagA.log"
    $pb = Join-Path $Logs "split-checks-bench-ab-$check-$tagB.log"
    if (-not (Test-Path $pa) -or -not (Test-Path $pb)) {
        Log ("比对 {0}[{1}]：日志缺失（a={2} b={3}）" -f $label, $check, (Test-Path $pa), (Test-Path $pb))
        return @{ pass = $false; crit = "日志缺失" }
    }
    $la = Get-BenchLines $pa
    $lb = Get-BenchLines $pb
    if ($la.Count -ne $lb.Count) {
        Log ("比对 {0}[{1}]：✘ 台架证据行数不同（{2} vs {3}）—— 结构就不等价" -f $label, $check, $la.Count, $lb.Count)
        return @{ pass = $false; crit = "行数不同" }
    }
    $skA = Get-Skeleton $la
    $skB = Get-Skeleton $lb
    $skDiff = @(Compare-Object $skA $skB)
    if ($skDiff.Count -gt 0) {
        $d = Join-Path $Logs ("split-checks-bench-ab-diff-{0}-{1}.txt" -f $check, ($label -replace '[^\w]', ''))
        $msg = @()
        $msg += ("比对 {0}[{1}]：✘ 数值Mask后骨架有差异（{2} 处）—— 结构不等价" -f $label, $check, $skDiff.Count)
        $msg += "--- 骨架差异（前 20 行）---"
        $msg += ($skDiff | Select-Object -First 20 | ForEach-Object { "{0} {1}" -f $_.SideIndicator, $_.InputObject })
        $msg | Out-File $d -Encoding utf8
        Log ($msg[0])
        Log ("  骨架差异画像已写 {0}" -f $d)
        return @{ pass = $false; crit = "骨架有差异" }
    }
    $sp = Get-NumSpread $la $lb
    if (-not $sp.ok) {
        Log ("比对 {0}[{1}]：✘ {2}" -f $label, $check, ($sp.bad -join " ; "))
        return @{ pass = $false; crit = "数值个数不符" }
    }
    # 判据：floorSpread < 0 表示调用方要求"逐行相同"（base1=base2 时）；否则 ≤ min(floor, 1%)
    if ($floorSpread -lt 0.0) {
        $identical = ($sp.worst -le 0.0)
        if ($identical) {
            Log ("比对 {0}[{1}]：✔ 台架证据行归一化后逐行相同（{2} 行）" -f $label, $check, $la.Count)
            return @{ pass = $true; crit = "逐行相同" }
        }
        Log ("比对 {0}[{1}]：✘ 判据是逐行相同，但数值极差 {2:P4}（{3}）" -f $label, $check, $sp.worst, $sp.where)
        return @{ pass = $false; crit = "逐行相同" }
    }
    $limit = [math]::Min($floorSpread, 0.01)
    if ($sp.worst -le $limit) {
        Log ("比对 {0}[{1}]：✔ 结构相同（{2} 行骨架全同）+ 数值极差 {3:P4} ≤ min(噪声底 {4:P4}, 1%) = {5:P4}（最大处：{6}）" -f
            $label, $check, $la.Count, $sp.worst, $floorSpread, $limit, $sp.where)
        return @{ pass = $true; crit = ("结构相同+极差≤{0:P4}" -f $limit) }
    }
    Log ("比对 {0}[{1}]：✘ 数值极差 {2:P4} 超过 min(噪声底 {3:P4}, 1%) = {4:P4}（最大处：{5}）—— 停下人工核，不许放宽" -f
        $label, $check, $sp.worst, $floorSpread, $limit, $sp.where)
    return @{ pass = $false; crit = "极差超限" }
}

Log "================ SPLIT-CHECKS-BENCH-002 A/B（{0}）================" -f $Group
Log ("START {0}   HEAD={1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), (git rev-parse --short HEAD))

# 0) 备份：万一 pop 出问题还能手工还原
New-Item -ItemType Directory -Force -Path $Bak | Out-Null
Copy-Item $Main "$Bak\main.gd.after" -Force
Copy-Item $Module "$Bak\bench.gd" -Force
Log "已备份 main.gd(after) / bench.gd 到 _ab-backup-checks-bench"

# 0b) 并行对话防御：被修改的已跟踪文件必须只有 main.gd
$modified = @(& git -C $Root status --porcelain -uall | Where-Object { $_ -match '^\s*M' })
Log ("stash 前已跟踪修改文件：{0}" -f (($modified | ForEach-Object { $_.Trim() }) -join " ; "))
if ($modified.Count -ne 1 -or $modified[0] -notmatch 'main\.gd') {
    Log "!! 中止：modified 不止 main.gd 或不含 main.gd（并行对话在动工作区？）—— 不 stash、不跑 A/B"
    exit 1
}
$diffStat = & git -C $Root diff --numstat -- godot-racer/scenes/main.gd
Log ("  main.gd diff --numstat: {0}" -f ($diffStat -join " "))
# +18/-705 = 插入 18（模块声明块 10 + setup 接线 3 + breadcrumb 4 + dispatch 2 新行）
#          + 删除 705（两族整块 704 行 − 1 行与 breadcrumb 尾空行对齐的原空行，
#             + dispatch 2 旧行；行数口径 4033−705+18=3346）
if ($diffStat -notmatch '^18\s+705\s') {
    Log "!! 中止：main.gd 的 diff 不是预期的 +18/-705（并行对话改过 main.gd？）—— 不 stash"
    exit 1
}
Log "  防御通过：唯一修改 = main.gd，diff = +18/-705（本次迁移的量级）"

# 每个 check 独立跑四跑，各自量噪声底、各自判据
$checks = @(
    @{ n = "steerbench"; extra = @() },                 # 同 steerbench-repro.ps1：不带 -NoAi
    @{ n = "brakebench"; extra = @("-NoAi") }           # 同 brakebench-repro.ps1：AI 会撞台架车
)
$verdicts = @{}
foreach ($c in $checks) {
    $check = $c.n
    # 1) 同代码两跑：量本族的噪声底
    Invoke-Check $check "base1" $c.extra
    Invoke-Check $check "base2" $c.extra
    $baseIdentical = (Compare-Pair $check "base1" "base2" "base1-vs-base2（同代码两跑=噪声底）" -1.0)
    $floor = -1.0
    if ($baseIdentical.pass) {
        Log ("  → 噪声底[{0}]：base1=base2 台架证据行逐行相同 → ctrl/after 判据用「逐行相同」" -f $check)
    } else {
        $la = Get-BenchLines (Join-Path $Logs "split-checks-bench-ab-$check-base1.log")
        $lb = Get-BenchLines (Join-Path $Logs "split-checks-bench-ab-$check-base2.log")
        $sp = Get-NumSpread $la $lb
        $floor = $sp.worst
        Log ("  → 噪声底[{0}]：base1≠base2（跨进程墙钟噪声）→ 台架证据行数值极差实测 {1:P4}（{2}）；ctrl/after 判据 = 结构相同 + 极差 ≤ min(底, 1%)" -f
            $check, $sp.worst, $sp.where)
    }

    # 2) 对照组：只收起 main.gd，回到 HEAD 代码（模块留盘）
    $s1 = & git -C $Root stash push -m "SPLIT-CHECKS-BENCH-AB-CTRL-$check" -- godot-racer/scenes/main.gd 2>&1
    Log ("stash push[{0}]: {1}" -f $check, ($s1 -join " | "))
    Log ("  → 模块是否还在（应 True）: {0}" -f (Test-Path $Module))
    Log ("  → main.gd 行数（应回到 4033）: {0}" -f @(Get-Content $Main).Count)
    Invoke-Check $check "ctrl" $c.extra

    # 3) 改动组：恢复迁移
    $s2 = & git -C $Root stash pop 2>&1
    Log ("stash pop[{0}]: {1}" -f $check, ($s2 -join " | "))
    Log ("  → main.gd 行数（应 3346）: {0}" -f @(Get-Content $Main).Count)
    $hNow = (Get-FileHash $Main).Hash
    $hBak = (Get-FileHash "$Bak\main.gd.after").Hash
    Log ("  → main.gd 与备份逐字节一致（pop 无损）: {0}" -f ($hNow -eq $hBak))
    if ($hNow -ne $hBak) {
        Log "!! pop 后 main.gd 与备份不一致 —— 从 _ab-backup-checks-bench 手工还原后再继续"
        exit 1
    }
    Invoke-Check $check "after" $c.extra

    # 4) 判定
    $v = Compare-Pair $check "ctrl" "after" "ctrl-vs-after（归一化后=行为等价）" $floor
    $verdicts[$check] = $v
}

# 实例 ID 指纹（证代码版本）。⚠ 用 Select-String 而不是 bash：本机 PowerShell 里
# `bash` 解析到 WSL 的 wsl.exe，被安全策略拉黑（2026-10-13 实测）。
foreach ($c in $checks) {
    foreach ($t in @("ctrl", "after")) {
        $p = Join-Path $Logs "split-checks-bench-ab-$($c.n)-$t.log"
        if (Test-Path $p) {
            $fp = @(Select-String -Path $p -Pattern '[A-Za-z0-9_]+#[0-9]+' -AllMatches |
                ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Sort-Object -Unique)
            Log ("  实例 ID 指纹 [{0}/{1}]（{2} 个）: {3}" -f $c.n, $t, $fp.Count, ($fp -join " "))
        }
    }
}

# 总判据
$allPass = $true
foreach ($k in $verdicts.Keys) { if (-not $verdicts[$k].pass) { $allPass = $false } }
Log ("================ 总判据：{0} ================" -f $(if ($allPass) { "✔ 两个 check 全部通过（判据见上，零放宽）" } else { "✘ 有 check 未过 —— 停下报告，不许调参掩盖" }))
foreach ($k in ($verdicts.Keys | Sort-Object)) {
    Log ("  [{0}] {1}（{2}）" -f $k, $(if ($verdicts[$k].pass) { "PASS" } else { "FAIL" }), $verdicts[$k].crit)
}

Log ("END {0}   HEAD={1}   工作区文件数={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
    (git rev-parse --short HEAD), @(git status --porcelain -uall).Count)
if (-not $allPass) { exit 1 }
exit 0
