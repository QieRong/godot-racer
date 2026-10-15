$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l5-final-progress.log'
('HEAD=' + (git rev-parse HEAD)) | Set-Content $report
git status --short | Add-Content $report
function Assert-Source {
    foreach ($path in @('godot-racer/scripts/ai_opponent.gd','godot-racer/scripts/racing_line.gd')) {
        $hash = git hash-object -- $path
        if ($script:sourceHashes[$path] -ne $hash) {throw "Source drift: $path"}
    }
}
$sourceHashes = @{}
foreach ($path in @('godot-racer/scripts/ai_opponent.gd','godot-racer/scripts/racing_line.gd')) {
    $sourceHashes[$path] = git hash-object -- $path
    "$path BLOB=$($sourceHashes[$path])" | Add-Content $report
}
foreach ($name in @('lint-gdscript','parse-check','check-docs','check-readme','check-dup-source')) {
    & pwsh -NoProfile -File "04-Godot启动器/$name.ps1" *> "godot-logs/l5-final-$name.log"
    "$name EXIT=$LASTEXITCODE" | Add-Content $report
    if ($LASTEXITCODE -ne 0) {exit 1}
}
foreach ($n in @(1,2,3)) {
    Assert-Source
    "START opponents L5 $n" | Add-Content $report
    & pwsh -NoProfile -File '04-Godot启动器/run-check.ps1' -Check opponents -Level 4 -LogName "l5-final-opponents-$n" *> "godot-logs/l5-final-opponents-$n.out"
    $code = $LASTEXITCODE
    $passed = (Get-Content "godot-logs/l5-final-opponents-$n.log" -Raw) -match '对手验收 ✔'
    "opponents L5 $n EXIT=$code PASS=$passed" | Add-Content $report
    if ($code -ne 0 -or -not $passed) {exit 1}
}
Assert-Source
$console = 'E:\godot\Godot_v4.4.1-stable_win64_console.exe'
'START visual' | Add-Content $report
& $console --path godot-racer --log-file "$PWD/godot-logs/l5-final-visual.log" --script "$PWD/godot-logs/capture-opponent.gd" -- --level=4 "--capture-out=$PWD/godot-logs/l5-final-arc805.png" --capture-arc=805 *> godot-logs/l5-final-visual.out
"visual EXIT=$LASTEXITCODE" | Add-Content $report
if ($LASTEXITCODE -ne 0) {exit 1}
'START Quick' | Add-Content $report
& pwsh -NoProfile -File '04-Godot启动器/run-all-checks.ps1' -Quick *> godot-logs/l5-final-quick.log
"Quick EXIT=$LASTEXITCODE" | Add-Content $report
if ($LASTEXITCODE -ne 0) {exit 1}
'START aidiag L1' | Add-Content $report
& pwsh -NoProfile -File '04-Godot启动器/run-check.ps1' -Check aidiag -Level 0 -LogName l5-final-aidiag-l1 *> godot-logs/l5-final-aidiag-l1.out
$code=$LASTEXITCODE
$passed=(Get-Content godot-logs/l5-final-aidiag-l1.log -Raw) -match 'AI 诊断 ✔'
"aidiag L1 EXIT=$code PASS=$passed" | Add-Content $report
if ($code -ne 0 -or -not $passed) {exit 1}
Assert-Source
'DONE' | Add-Content $report
