$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l5-resume-progress.log'
('HEAD=' + (git rev-parse HEAD)) | Set-Content $report
git status --short | Add-Content $report
function Assert-Source {
    if ((git hash-object -- godot-racer/scripts/ai_opponent.gd) -ne 'fe38b674492b7f15c173030dd65409dd93f84ab5') { throw 'AI source drift' }
    if ((git hash-object -- godot-racer/scripts/racing_line.gd) -ne '39cea821f4fb6ccc0f2f76b7a01e4686d58a0a9e') { throw 'RacingLine source drift' }
}
Assert-Source
& 'E:\godot\Godot_v4.4.1-stable_win64_console.exe' --headless --path godot-racer --log-file "$PWD/godot-logs/l5-resume-unit.log" --script res://tools/test_probe_braking.gd *> godot-logs/l5-resume-unit.out
"unit EXIT=$LASTEXITCODE" | Add-Content $report
if ($LASTEXITCODE -ne 0) {exit 1}
'START Quick rerun; prior run interrupted without final exit' | Add-Content $report
& pwsh -NoProfile -File '04-Godot启动器/run-all-checks.ps1' -Quick *> godot-logs/l5-resume-quick.log
"Quick EXIT=$LASTEXITCODE" | Add-Content $report
if ($LASTEXITCODE -ne 0) {exit 1}
Assert-Source
'START aidiag L1' | Add-Content $report
& pwsh -NoProfile -File '04-Godot启动器/run-check.ps1' -Check aidiag -Level 0 -LogName l5-resume-aidiag-l1 *> godot-logs/l5-resume-aidiag-l1.out
$code=$LASTEXITCODE
$passed=(Get-Content godot-logs/l5-resume-aidiag-l1.log -Raw) -match 'AI 诊断 ✔'
"aidiag L1 EXIT=$code PASS=$passed" | Add-Content $report
if ($code -ne 0 -or -not $passed) {exit 1}
Assert-Source
'DONE' | Add-Content $report
