$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l4-regression-progress.log'
'WAIT first L4 run PID=5656' | Set-Content $report
Wait-Process -Id 5656 -ErrorAction SilentlyContinue
if ((Get-Content godot-logs/l4-resume-progress.log -Raw) -notmatch 'PASS=True COMPLETE=True') {
    'STOP first L4 did not pass; EXIT=1' | Add-Content $report
    exit 1
}
('HEAD=' + (git rev-parse HEAD)) | Add-Content $report
git status --short | Add-Content $report
$hashes = @{}
foreach ($path in @('godot-racer/scripts/ai_opponent.gd', 'godot-racer/scripts/racing_line.gd')) {
    $hashes[$path] = git hash-object -- $path
    "$path BLOB=$($hashes[$path])" | Add-Content $report
}
function Assert-Source {
    foreach ($path in $hashes.Keys) {
        if ((git hash-object -- $path) -ne $hashes[$path]) { throw "Source drift $path" }
    }
}
foreach ($n in @(2,3)) {
    Assert-Source
    "START opponents L4 $n" | Add-Content $report
    & pwsh -NoProfile -File '04-Godot启动器/run-check.ps1' -Check opponents -Level 3 -SkipLint -LogName "l4-regression-opponents-$n" *> "godot-logs/l4-regression-opponents-$n.out"
    $code = $LASTEXITCODE
    $log = Get-Content "godot-logs/l4-regression-opponents-$n.log" -Raw
    $passed = $log -match '对手验收 ✔'
    "opponents L4 $n EXIT=$code PASS=$passed" | Add-Content $report
    if ($code -ne 0 -or -not $passed) { exit 1 }
}
foreach ($item in @(@('opponents',4,'l5'), @('aidiag',0,'l1'))) {
    Assert-Source
    $check = $item[0]; $level = $item[1]; $label = $item[2]
    "START $check $label" | Add-Content $report
    & pwsh -NoProfile -File '04-Godot启动器/run-check.ps1' -Check $check -Level $level -SkipLint -LogName "l4-regression-$check-$label" *> "godot-logs/l4-regression-$check-$label.out"
    $code = $LASTEXITCODE
    $log = Get-Content "godot-logs/l4-regression-$check-$label.log" -Raw
    $passed = ($log -match '对手验收 ✔') -or ($log -match 'AI 诊断 ✔')
    "$check $label EXIT=$code PASS=$passed" | Add-Content $report
    if ($code -ne 0 -or -not $passed -or $log -match '\[自检\].*✘') { exit 1 }
}
Assert-Source
'START Quick' | Add-Content $report
& pwsh -NoProfile -File '04-Godot启动器/run-all-checks.ps1' -Quick *> godot-logs/l4-regression-quick.log
"Quick EXIT=$LASTEXITCODE" | Add-Content $report
if ($LASTEXITCODE -ne 0) { exit 1 }
Assert-Source
'DONE EXIT=0' | Add-Content $report
