$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l4-envelope-regression-progress.log'
'WAIT first envelope L4 run PID=2360' | Set-Content $report
Wait-Process -Id 2360 -ErrorAction SilentlyContinue
if ((Get-Content godot-logs/l4-envelope-progress.log -Raw) -notmatch 'PASS=True COMPLETE=True') {
    'STOP first L4 did not pass; EXIT=1' | Add-Content $report
    exit 1
}
('HEAD=' + (git rev-parse HEAD)) | Add-Content $report
git status --short | Add-Content $report
$hashes = @{}
foreach ($path in @('godot-racer/scripts/ai_opponent.gd', 'godot-racer/scripts/racing_line.gd', 'godot-racer/scripts/obstacle_field.gd')) {
    $hashes[$path] = git hash-object -- $path
    "$path BLOB=$($hashes[$path])" | Add-Content $report
}
function Assert-Source {
    foreach ($path in $hashes.Keys) {
        if ((git hash-object -- $path) -ne $hashes[$path]) { throw "Source drift $path" }
    }
}
$items = @(
    @{ check='opponents'; level=4; label='l5-1'; pass='对手验收 ✔' },
    @{ check='opponents'; level=3; label='l4-2'; pass='对手验收 ✔' },
    @{ check='opponents'; level=3; label='l4-3'; pass='对手验收 ✔' },
    @{ check='opponents'; level=4; label='l5-2'; pass='对手验收 ✔' },
    @{ check='opponents'; level=4; label='l5-3'; pass='对手验收 ✔' },
    @{ check='aidiag'; level=0; label='aidiag-l1'; pass='AI 诊断 ✔' }
)
foreach ($item in $items) {
    Assert-Source
    $check = $item.check; $level = $item.level; $label = $item.label
    "START $label" | Add-Content $report
    & pwsh -NoProfile -File '04-Godot启动器/run-check.ps1' -Check $check -Level $level -SkipLint -LogName "l4-envelope-$label" *> "godot-logs/l4-envelope-$label.out"
    $code = $LASTEXITCODE
    $log = Get-Content "godot-logs/l4-envelope-$label.log" -Raw
    $passed = $log.Contains($item.pass)
    "$label EXIT=$code PASS=$passed" | Add-Content $report
    if ($code -ne 0 -or -not $passed -or $log -match '\[自检\].*✘') {
        'STOP acceptance failure; EXIT=1' | Add-Content $report
        exit 1
    }
}
Assert-Source
'START Quick' | Add-Content $report
& pwsh -NoProfile -File '04-Godot启动器/run-all-checks.ps1' -Quick *> godot-logs/l4-envelope-quick.log
"Quick EXIT=$LASTEXITCODE" | Add-Content $report
if ($LASTEXITCODE -ne 0) { exit 1 }
Assert-Source
'DONE EXIT=0' | Add-Content $report
