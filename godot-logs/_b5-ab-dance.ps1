# SPLIT-CHECKS-BASIC-005 A/B 舞步：HEAD 代码 vs 迁移后代码，同机同关卡跑同一批检查，日志留档比对。
#
# 方法（不复用 git stash / checkout --，也非 worktree）：把工作区 main.gd 备份后，用
# `git show HEAD:godot-racer/scenes/main.gd` 把 main.gd 还原成 HEAD 版跑一轮（"head" 组），
# 再从备份恢复（"work" 组）。两组只差 main.gd 内容、跑同一份 basic.gd/lap.gd（HEAD 版
# main.gd 不引用它们，等同未拆）。
#   - work 组：迁移后（新 main.gd 分发到 _checks_basic/_checks_lap）
#   - head 组：HEAD（旧 main.gd 自带 _check_* 函数体）
# try/finally 保证**无论如何都把 main.gd 恢复**（备份在 godot-logs/_b5-main-migrated.gd）。
#
# 用法：pwsh -NoProfile -File godot-logs\_b5-ab-dance.ps1
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$root = "D:\桌面\DSH-Work\data-analysis"
$L = "$root\04-Godot启动器"
$g = "$root\godot-logs"
$main = "$root\godot-racer\scenes\main.gd"
$bak = "$g\_b5-main-migrated.gd"

Copy-Item $main $bak -Force
"-" * 60 | Out-File "$g\_b5-ab-exit.log" -Encoding ascii
"backup: $((Get-FileHash $main -Algorithm SHA256).Hash.Substring(0,12))" |
    Out-File "$g\_b5-ab-exit.log" -Append -Encoding ascii

function Run-One($check, $logname) {
    & pwsh -NoProfile -File "$L\run-check.ps1" -Check $check -MaxTries 4 -LogName $logname -SkipLint 2>&1 |
        Out-File "$g\_b5-ab-$logname.out" -Encoding utf8
    "$logname exit=$LASTEXITCODE" | Out-File "$g\_b5-ab-exit.log" -Append -Encoding ascii
}

try {
    # ---- WORK 组（当前工作区 = 迁移后）----
    Run-One 'reverse' 'split-checks-basic-005-ab-work-reverse'
    Run-One 'lap'     'split-checks-basic-005-ab-work-lap1'
    Run-One 'lap'     'split-checks-basic-005-ab-work-lap2'

    # ---- 切到 HEAD 版 main.gd（LF、无 BOM；GDScript 两种行尾都能解析）----
    $headText = (& git -C $root show "HEAD:godot-racer/scenes/main.gd") -join "`n"
    [System.IO.File]::WriteAllText($main, $headText + "`n", (New-Object System.Text.UTF8Encoding($false)))
    "swapped-to-HEAD: $((Get-FileHash $main -Algorithm SHA256).Hash.Substring(0,12))" |
        Out-File "$g\_b5-ab-exit.log" -Append -Encoding ascii

    # ---- HEAD 组 ----
    Run-One 'reverse' 'split-checks-basic-005-ab-head-reverse'
    Run-One 'lap'     'split-checks-basic-005-ab-head-lap1'
    Run-One 'lap'     'split-checks-basic-005-ab-head-lap2'
}
finally {
    Copy-Item $bak $main -Force
    "restored: $((Get-FileHash $main -Algorithm SHA256).Hash.Substring(0,12))" |
        Out-File "$g\_b5-ab-exit.log" -Append -Encoding ascii
    "AB_DANCE_DONE" | Out-File "$g\_b5-ab-exit.log" -Append -Encoding ascii
}
