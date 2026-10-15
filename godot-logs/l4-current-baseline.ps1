$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l4-current-baseline-progress.log'
('HEAD=' + (git rev-parse HEAD)) | Set-Content $report
git status --short | Add-Content $report
foreach ($path in @('godot-racer/scripts/ai_opponent.gd', 'godot-racer/scripts/racing_line.gd', 'godot-racer/scripts/autopilot.gd', 'godot-racer/scripts/obstacle_field.gd')) {
    "$path BLOB=$(git hash-object -- $path)" | Add-Content $report
}
try {
    foreach ($name in @('lint-gdscript', 'parse-check', 'check-docs', 'check-readme', 'check-dup-source')) {
        "START $name" | Add-Content $report
        & pwsh -NoProfile -File "04-Godot启动器/$name.ps1" *> "godot-logs/l4-current-$name.log"
        "$name EXIT=$LASTEXITCODE" | Add-Content $report
        if ($LASTEXITCODE -ne 0) { throw "Gate failed: $name" }
    }
    'START opponents L4 baseline' | Add-Content $report
    & pwsh -NoProfile -File '04-Godot启动器/run-check.ps1' -Check opponents -Level 3 -LogName l4-current-opponents-baseline *> godot-logs/l4-current-opponents-baseline.out
    $code = $LASTEXITCODE
    $log = Get-Content godot-logs/l4-current-opponents-baseline.log -Raw
    "opponents L4 EXIT=$code PASS=$($log -match '对手验收 ✔') COMPLETE=$($log -match '\[CHECK\] 完成')" | Add-Content $report
    'DONE baseline collection (PASS field is acceptance result)' | Add-Content $report
} catch {
    "ERROR $_" | Add-Content $report
    'EXIT=1' | Add-Content $report
    exit 1
}
'EXIT=0' | Add-Content $report
