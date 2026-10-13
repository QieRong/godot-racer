# SPLIT-CHECKS-LAYOUT-001 行为等价 A/B（stash 舞步，背靠背）。
#
# 对照组 = HEAD 的 main.gd（stash 后，layout 族还在 main.gd 里内联实现）；
# 改动后 = pop 后（layout 族外迁到 scripts/checks/layout.gd）。
# **必须背靠背**：同代码跨进程间隔 5 分钟实测差异 25854 行（AGENTS §4.3）。
#
# ⚠ 为什么用**定向 pathspec** 而不是 `git stash -u`：
#   ① 整仓 stash -u 会把 godot-logs 下的证据文件（structcheck 红绿日志、本脚本）
#      一起卷走，pop 前它们不在盘上；
#   ② 只收 main.gd：新模块 layout.gd(+.uid) 是**未跟踪**文件、不在 pathspec 里，
#      全程留在盘上（split-opponent-fileprobe 先例同款做法）—— ctrl 环境 = 纯 HEAD
#      代码 + 模块在盘但没人引用，证明"纯 HEAD 也能跑"。
#
# ⚠ 并行对话防御（2026-10-13 新增）：stash 前核验 git status 中**被修改的已跟踪文件
#   只有 main.gd 一个**，且 main.gd 的 diff 行数符合本次迁移（-768/+18 量级）。
#   若出现别的脏文件（并行对话的未提交成果），立即中止 —— 绝不动别人的工作区。
#
# 合格判据（layout 是纯函数族，无物理计时、无墙钟打印）：
#   base1 vs base2（同代码两跑）= 噪声底，预期**逐行相同**；
#   ctrl vs after（归一化实例 ID 后）= **逐行相同**，一个字符都不许差。
#
# ⚠ 2026-10-13 round 2 实证的噪声底（AGENTS §4.3「先确认模式」的又一例）：
#   日志里有 9 个 `[车辆] t=` 诊断块（跑圈中周期性打印，与 layout 族无关）。
#   前 8 个位置四跑完全一致；**第 9 个（t=2.3s）会翻位置** —— stdout（[自检] 检查行）
#   与 stderr（[车辆] 块）在 PowerShell 合流时的次序不稳定：base1 落在检查输出前、
#   base2/ctrl/after 落在 `[CHECK] 完成，退出` 之后。**内容逐行相同**，纯合流噪声。
#   → 每次跑完都记录「模式指纹」（末块在检查输出前=A / 后=B）；
#     ctrl 与 after **必须同模式**，此时的逐行相同才是有效的行为等价证据；
#     不同模式时的差异 = 噪声底，需人工核对内容一致性（onlyA/onlyB 计数为 0 即证）。
#
# 用法：pwsh -File godot-logs\split-checks-layout-ab-dance.ps1
param(
    [string]$Group = "layout"
)
$ErrorActionPreference = "Continue"
$Logs = $PSScriptRoot                       # godot-logs
$Root = Split-Path -Parent $PSScriptRoot    # git 根
$Summary = Join-Path $Logs "split-checks-layout-ab-summary.log"
$RunCheck = Join-Path $Root "04-Godot启动器\run-check.ps1"
$Main = Join-Path $Root "godot-racer\scenes\main.gd"
$Module = Join-Path $Root "godot-racer\scripts\checks\layout.gd"
$Bak = Join-Path $Logs "_ab-backup-checks-layout"

function Log([string]$m) { $m | Out-File -FilePath $Summary -Encoding utf8 -Append }

# 跑一次 run-check（-Check layout）并记录 exit / 日志行数 / 关键行数
function Invoke-Check([string]$tag) {
    $logCopy = Join-Path $Logs "split-checks-layout-ab-$tag.log"
    $runLog = Join-Path $Logs "split-checks-layout-ab-$tag.run.log"
    Log ("--- [{0}] {1}  开始 {2}" -f $Group, $tag, (Get-Date -Format "HH:mm:ss"))
    if (Test-Path $logCopy) { Remove-Item $logCopy -Force }
    & pwsh -NoProfile -File $RunCheck -Check layout -LogName "split-checks-layout-ab-$tag" -SkipLint 2>&1 |
        Out-File $runLog -Encoding utf8
    $code = $LASTEXITCODE
    $logLines = if (Test-Path $logCopy) { @(Get-Content $logCopy).Count } else { -1 }
    $selfcheck = if (Test-Path $logCopy) {
        @(Get-Content $logCopy | Where-Object { $_ -match '\[自检\]' }).Count } else { -1 }
    $done = if (Test-Path $logCopy) {
        @(Get-Content $logCopy | Where-Object { $_ -match '\[CHECK\] 完成' }).Count } else { -1 }
    Log ("--- [{0}] {1}  结束 {2}   exit={3}   日志行数={4}   [自检]行={5}   [CHECK]完成={6}" -f
        $Group, $tag, (Get-Date -Format "HH:mm:ss"), $code, $logLines, $selfcheck, $done)
    # 模式指纹：最后一个 [车辆] 诊断块相对检查输出的位置（合流次序会翻，见文件头）
    if (Test-Path $logCopy) {
        $ls = @(Get-Content $logCopy)
        $blk = @()
        for ($i = 0; $i -lt $ls.Count; $i++) { if ($ls[$i].StartsWith('[车辆] t=')) { $blk += $i } }
        $chk = -1
        for ($i = 0; $i -lt $ls.Count; $i++) { if ($ls[$i].StartsWith('[自检] 布局验收')) { $chk = $i; break } }
        $mode = "?"
        $lastBlk = -1
        if ($blk.Count -gt 0 -and $chk -ge 0) {
            $lastBlk = $blk[$blk.Count - 1]
            if ($lastBlk -lt $chk) { $mode = "A（末块在检查输出前）" } else { $mode = "B（末块在检查输出后）" }
        }
        Log ("  → 模式指纹: 共 {0} 个车辆块，末块@{1}，检查首行@{2} = {3}" -f $blk.Count, $lastBlk, $chk, $mode)
    }
}

# 归一化：实例 ID #<数字> → #ID（AGENTS §4.3）
function Get-Norm([string]$p) {
    (Get-Content $p -Raw) -replace '#[0-9]+', '#ID'
}

Log "================ SPLIT-CHECKS-LAYOUT-001 A/B（{0}）================" -f $Group
Log ("START {0}   HEAD={1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), (git rev-parse --short HEAD))

# 0) 备份：万一 pop 出问题还能手工还原
New-Item -ItemType Directory -Force -Path $Bak | Out-Null
Copy-Item $Main "$Bak\main.gd.after" -Force
Copy-Item $Module "$Bak\layout.gd" -Force
Log "已备份 main.gd(after) / layout.gd 到 _ab-backup-checks-layout"

# 0b) 并行对话防御：被修改的已跟踪文件必须只有 main.gd
$modified = @(& git -C $Root status --porcelain -uall | Where-Object { $_ -match '^\s*M' })
Log ("stash 前已跟踪修改文件：{0}" -f (($modified | ForEach-Object { $_.Trim() }) -join " ; "))
if ($modified.Count -ne 1 -or $modified[0] -notmatch 'main\.gd') {
    Log "!! 中止：modified 不止 main.gd 或不含 main.gd（并行对话在动工作区？）—— 不 stash、不跑 A/B"
    exit 1
}
$diffStat = & git -C $Root diff --numstat -- godot-racer/scenes/main.gd
Log ("  main.gd diff --numstat: {0}" -f ($diffStat -join " "))
# +19/-787 = 插入 18（模块声明 10 + setup 接线 4 + breadcrumb 4）+ 删除 786（九个区间）
#          + 分发行替换的 1 增 1 删（L333 await _check_layout() → await _checks_layout.run()）
if ($diffStat -notmatch '^19\s+787\s') {
    Log "!! 中止：main.gd 的 diff 不是预期的 +19/-787（并行对话改过 main.gd？）—— 不 stash"
    exit 1
}
Log "  防御通过：唯一修改 = main.gd，diff = +19/-787（本次迁移的量级）"

# 1) 同代码两跑：确认 layout 族的噪声底（预期逐行相同）
Invoke-Check "base1"
Invoke-Check "base2"

# 2) 对照组：只收起 main.gd，回到 HEAD 代码（模块留盘）
$s1 = & git -C $Root stash push -m "SPLIT-CHECKS-LAYOUT-AB-CTRL" -- godot-racer/scenes/main.gd 2>&1
Log ("stash push: {0}" -f ($s1 -join " | "))
Log ("  → 模块是否还在（应 True）: {0}" -f (Test-Path $Module))
Log ("  → main.gd 行数（应回到 4801）: {0}" -f @(Get-Content $Main).Count)
Invoke-Check "ctrl"

# 3) 改动组：恢复迁移
$s2 = & git -C $Root stash pop 2>&1
Log ("stash pop: {0}" -f ($s2 -join " | "))
Log ("  → main.gd 行数（应 4033）: {0}" -f @(Get-Content $Main).Count)
$hNow = (Get-FileHash $Main).Hash
$hBak = (Get-FileHash "$Bak\main.gd.after").Hash
Log ("  → main.gd 与备份逐字节一致（pop 无损）: {0}" -f ($hNow -eq $hBak))
if ($hNow -ne $hBak) {
    Log "!! pop 后 main.gd 与备份不一致 —— 从 _ab-backup-checks-layout 手工还原后再继续"
    exit 1
}
Invoke-Check "after"

# 4) 比对
$pairs = @(
    @{ n = "base1-vs-base2（同代码两跑=噪声底）"; a = "split-checks-layout-ab-base1.log"; b = "split-checks-layout-ab-base2.log"; want = "逐行相同" },
    @{ n = "ctrl-vs-after（归一化后=行为等价）"; a = "split-checks-layout-ab-ctrl.log"; b = "split-checks-layout-ab-after.log"; want = "逐行相同" }
)
foreach ($pr in $pairs) {
    $pa = Join-Path $Logs $pr.a
    $pb = Join-Path $Logs $pr.b
    if (-not (Test-Path $pa) -or -not (Test-Path $pb)) {
        Log ("比对 {0}：日志缺失（a={1} b={2}）" -f $pr.n, (Test-Path $pa), (Test-Path $pb))
        continue
    }
    $na = Get-Norm $pa
    $nb = Get-Norm $pb
    if ($na -eq $nb) {
        Log ("比对 {0}：✔ 归一化后逐行相同（{1} 字符）" -f $pr.n, $na.Length)
    } else {
        $d = Join-Path $Logs ("split-checks-layout-ab-diff-{0}.txt" -f ($pr.n -replace '[^\w]', ''))
        # 出行数级别的差异画像，便于定位
        $la = $na -split "`r?`n"
        $lb = $nb -split "`r?`n"
        $onlyA = @($la | Where-Object { $lb -notcontains $_ })
        $onlyB = @($lb | Where-Object { $la -notcontains $_ })
        $msg = @()
        $msg += ("比对 {0}：✘ 有差异（A {1} 行 / B {2} 行；仅 A 有 {3} 行、仅 B 有 {4} 行）" -f
            $pr.n, $la.Count, $lb.Count, $onlyA.Count, $onlyB.Count)
        $msg += "--- 仅 A 有（前 20 行）---"
        $msg += ($onlyA | Select-Object -First 20)
        $msg += "--- 仅 B 有（前 20 行）---"
        $msg += ($onlyB | Select-Object -First 20)
        $msg | Out-File $d -Encoding utf8
        Log ($msg[0])
        Log ("  差异画像已写 {0}" -f $d)
    }
}

# 实例 ID 指纹（证代码版本）。⚠ 用 Select-String 而不是 bash：本机 PowerShell 里
# `bash` 解析到 WSL 的 wsl.exe，被安全策略拉黑（2026-10-13 实测），会令脚本以非零退出。
foreach ($t in @("ctrl", "after")) {
    $p = Join-Path $Logs "split-checks-layout-ab-$t.log"
    if (Test-Path $p) {
        $fp = @(Select-String -Path $p -Pattern '[A-Za-z0-9_]+#[0-9]+' -AllMatches |
            ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Sort-Object -Unique)
        Log ("  实例 ID 指纹 [{0}]（{1} 个）: {2}" -f $t, $fp.Count, ($fp -join " "))
    }
}

Log ("END {0}   HEAD={1}   工作区文件数={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
    (git rev-parse --short HEAD), @(git status --porcelain -uall).Count)
