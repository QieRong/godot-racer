$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l4-recovery-gates-progress.log'
('HEAD=' + (git rev-parse HEAD)) | Set-Content $report
foreach ($name in @('lint-gdscript','parse-check','check-docs','check-readme','check-dup-source')) {
    "START $name" | Add-Content $report
    & pwsh -NoProfile -File "04-Godot启动器/$name.ps1" *> "godot-logs/l4-recovery-final-$name.log"
    "$name EXIT=$LASTEXITCODE" | Add-Content $report
    if ($LASTEXITCODE -ne 0) { 'DONE EXIT=1' | Add-Content $report; exit 1 }
}
$bad = 0
foreach ($name in @('l4-player-baseline-run','l4-receipt-selftest','l4-recovery-final-run','l4-recovery-visual-retry','l4-recovery-visual-batch','l4-recovery-gates')) {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile("$PWD/godot-logs/$name.ps1",[ref]$tokens,[ref]$errors)
    "$name POWERSHELL_ERRORS=$($errors.Count)" | Add-Content $report
    $bad += $errors.Count
}
"DONE EXIT=$([int]($bad -gt 0))" | Add-Content $report
exit ([int]($bad -gt 0))
