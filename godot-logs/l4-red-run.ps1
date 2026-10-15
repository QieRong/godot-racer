$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l4-red-progress.log'
'WAIT baseline PID=18168' | Set-Content $report
Wait-Process -Id 18168 -ErrorAction SilentlyContinue
if ((Get-Content godot-logs/l4-current-baseline-progress.log -Raw) -notmatch 'DONE') { throw 'baseline incomplete' }
('HEAD=' + (git rev-parse HEAD)) | Add-Content $report
git status --short | Add-Content $report
$console = 'E:\godot\Godot_v4.4.1-stable_win64_console.exe'
'START red unit' | Add-Content $report
& $console --headless --path godot-racer --log-file "$PWD/godot-logs/l4-tracking-red.log" --script res://tools/test_lateral_tracking.gd *> godot-logs/l4-tracking-red.out
"red unit EXIT=$LASTEXITCODE" | Add-Content $report
'START baseline screenshot' | Add-Content $report
& $console --path godot-racer --log-file "$PWD/godot-logs/l4-baseline-visual.log" --script "$PWD/godot-logs/capture-l4-stuck.gd" -- --check=opponents --level=3 "--capture-out=$PWD/godot-logs/l4-baseline-stuck.png" *> godot-logs/l4-baseline-visual.out
"baseline screenshot EXIT=$LASTEXITCODE" | Add-Content $report
'DONE' | Add-Content $report
