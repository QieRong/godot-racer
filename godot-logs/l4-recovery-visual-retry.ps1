$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l4-recovery-visual-retry-progress.log'
('HEAD=' + (git rev-parse HEAD)) | Set-Content $report
$hashes = @{}
foreach ($path in @('godot-racer/scripts/ai_opponent.gd','godot-racer/scripts/racing_line.gd','godot-racer/scripts/obstacle_field.gd','godot-racer/scripts/autopilot.gd')) {
    $hashes[$path] = git hash-object -- $path
    "$path BLOB=$($hashes[$path])" | Add-Content $report
}
$argsList = @('--path','godot-racer','--log-file',"$PWD/godot-logs/l4-recovery-visual-retry.log",'--script',"$PWD/godot-logs/capture-l4-pass.gd",'--','--check=opponents','--level=3',"--capture-out=$PWD/godot-logs/l4-recovery-pass-valid.png")
$game = Start-Process -FilePath 'E:\godot\Godot_v4.4.1-stable_win64_console.exe' -ArgumentList $argsList -WindowStyle Hidden -PassThru -RedirectStandardOutput godot-logs/l4-recovery-visual-retry.out -RedirectStandardError godot-logs/l4-recovery-visual-retry.err
"START visual PID=$($game.Id)" | Add-Content $report
if (-not $game.WaitForExit(120000)) {
    $game.Kill()
    'TIMEOUT DONE EXIT=1' | Add-Content $report
    exit 1
}
$game.Refresh()
$code = $game.ExitCode
$log = Get-Content godot-logs/l4-recovery-visual-retry.log -Raw
$valid = $log -match '\[VISUAL\] start_crossed=true arc=26\d\.\d+ speed=\d+\.\d+ rescues=0'
"visual EXIT=$code VALID=$valid" | Add-Content $report
foreach ($path in $hashes.Keys) {
    if ((git hash-object -- $path) -ne $hashes[$path]) { throw "Source drift $path" }
}
$result = [int]($code -ne 0 -or -not $valid)
"DONE EXIT=$result" | Add-Content $report
exit $result
