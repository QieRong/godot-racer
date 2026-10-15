param([switch]$RunPhysical)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
function Test-L4Acceptance([string]$Log, [string]$Expected) {
    return ($Log -match '\[CHECK\] 完成') -and $Log.Contains($Expected) -and
        ($Log -notmatch '(?m)^\[自检\].*✘') -and
        ($Log -notmatch 'SCRIPT ERROR:|Parse Error|Failed to load script|Compilation failed')
}
$report = 'godot-logs/l4-player-receipt-fixed-progress.log'
('HEAD=' + (git rev-parse HEAD)) | Set-Content $report
git status --short | Add-Content $report
foreach ($path in @('godot-racer/scripts/ai_opponent.gd','godot-racer/scripts/racing_line.gd','godot-racer/scripts/obstacle_field.gd','godot-racer/scripts/autopilot.gd')) {
    "$path BLOB=$(git hash-object -- $path)" | Add-Content $report
}
$logName = 'l4-player-current-baseline'
$code = 0
if ($RunPhysical) {
    $logName = 'l4-player-receipt-fixed-lap'
    'START explicit physical recheck' | Add-Content $report
    & pwsh -NoProfile -File '04-Godot启动器/run-check.ps1' -Check lap -Level 3 -SkipLint -LogName $logName *> "godot-logs/$logName.out"
    $code = $LASTEXITCODE
} else {
    'READ existing completed baseline; no physical rerun' | Add-Content $report
}
$log = Get-Content "godot-logs/$logName.log" -Raw
$passed = ($code -eq 0) -and (Test-L4Acceptance -Log $log -Expected '跑圈验收 ✔')
"lap L4 RUNNER_EXIT=$code PASS=$passed COMPLETE=$($log -match '\[CHECK\] 完成')" | Add-Content $report
"DONE EXIT=$([int](-not $passed))" | Add-Content $report
exit ([int](-not $passed))
