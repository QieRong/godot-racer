# SPLIT-CHECKS-BASIC-005 补充专项验收：跑 run-all-checks -Quick 未覆盖的、但属于本批两模块
# 的检查项（reset / oob / resetkey / escape / lap / stress）。逐个串行（避免 Godot 并发段错误），
# 每项写独立日志前缀 split-checks-basic-005-* / split-checks-lap-005-*，不覆盖既有 check-*.log。
# 用法：pwsh -NoProfile -File godot-logs\_b5-extra-checks.ps1
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$L = "D:\桌面\DSH-Work\data-analysis\04-Godot启动器"
$g = "D:\桌面\DSH-Work\data-analysis\godot-logs"
$checks = @(
    @{ n = 'reset';    ln = 'split-checks-basic-005-reset' },
    @{ n = 'oob';      ln = 'split-checks-basic-005-oob' },
    @{ n = 'resetkey'; ln = 'split-checks-basic-005-resetkey' },
    @{ n = 'escape';   ln = 'split-checks-basic-005-escape' },
    @{ n = 'lap';      ln = 'split-checks-lap-005-lap' },
    @{ n = 'stress';   ln = 'split-checks-lap-005-stress' }
)
"-" * 60 | Out-File "$g\_b5-extra-exit.log" -Encoding ascii
foreach ($c in $checks) {
    & pwsh -NoProfile -File "$L\run-check.ps1" -Check $c.n -MaxTries 4 -LogName $c.ln -SkipLint 2>&1 |
        Out-File "$g\_b5-extra-$($c.n).out" -Encoding utf8
    "check=$($c.n) exit=$LASTEXITCODE" | Out-File "$g\_b5-extra-exit.log" -Append -Encoding ascii
}
"ALL_EXTRA_DONE" | Out-File "$g\_b5-extra-exit.log" -Append -Encoding ascii
