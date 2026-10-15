$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l4-tracking-progress.log'
('HEAD=' + (git rev-parse HEAD)) | Set-Content $report
git status --short | Add-Content $report
foreach ($path in @('godot-racer/scripts/ai_opponent.gd', 'godot-racer/scripts/racing_line.gd')) {
    "$path BLOB=$(git hash-object -- $path)" | Add-Content $report
}
foreach ($name in @('lint-gdscript', 'parse-check', 'check-docs', 'check-readme', 'check-dup-source')) {
    & pwsh -NoProfile -File "04-Godot启动器/$name.ps1" *> "godot-logs/l4-tracking-$name.log"
    "$name EXIT=$LASTEXITCODE" | Add-Content $report
    if ($LASTEXITCODE -ne 0) { exit 1 }
}
'START opponents L4 tracking 1' | Add-Content $report
& pwsh -NoProfile -File '04-Godot启动器/run-check.ps1' -Check opponents -Level 3 -SkipLint -LogName l4-tracking-opponents-1 *> godot-logs/l4-tracking-opponents-1.out
$code = $LASTEXITCODE
$log = Get-Content godot-logs/l4-tracking-opponents-1.log -Raw
"opponents L4 EXIT=$code PASS=$($log -match '对手验收 ✔') COMPLETE=$($log -match '\[CHECK\] 完成')" | Add-Content $report
'DONE' | Add-Content $report
