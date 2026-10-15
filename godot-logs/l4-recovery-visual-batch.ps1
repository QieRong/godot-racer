$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l4-recovery-visual-batch-progress.log'
('HEAD=' + (git rev-parse HEAD)) | Set-Content $report
$hashes = @{}
foreach ($path in @('godot-racer/scripts/ai_opponent.gd','godot-racer/scripts/racing_line.gd','godot-racer/scripts/obstacle_field.gd','godot-racer/scripts/autopilot.gd')) {
    $hashes[$path] = git hash-object -- $path
    "$path BLOB=$($hashes[$path])" | Add-Content $report
}
$passed = $false
foreach ($n in 1..6) {
    $prefix = "l4-recovery-visual-attempt-$n"
    $argsList = @('--path','godot-racer','--log-file',"$PWD/godot-logs/$prefix.log",'--script',"$PWD/godot-logs/capture-l4-pass.gd",'--','--check=opponents','--level=3',"--capture-out=$PWD/godot-logs/l4-recovery-pass-valid.png")
    $game = Start-Process -FilePath 'E:\godot\Godot_v4.4.1-stable_win64_console.exe' -ArgumentList $argsList -WindowStyle Hidden -PassThru -RedirectStandardOutput "godot-logs/$prefix.out" -RedirectStandardError "godot-logs/$prefix.err"
    "START attempt=$n PID=$($game.Id)" | Add-Content $report
    if (-not $game.WaitForExit(90000)) {
        $game.Kill()
        "TIMEOUT attempt=$n DONE EXIT=1" | Add-Content $report
        exit 1
    }
    $game.Refresh()
    $code = $game.ExitCode
    $log = if (Test-Path "godot-logs/$prefix.log") { Get-Content "godot-logs/$prefix.log" -Raw } else { '' }
    $valid = $log -match '\[VISUAL\] start_crossed=true arc=26\d\.\d+ speed=\d+\.\d+ rescues=0'
    "attempt=$n EXIT=$code VALID=$valid" | Add-Content $report
    if ($code -eq 0 -and $valid) { $passed = $true; break }
    # 只重试明确的 Windows 启动期访问冲突，不把行为失败反复刷到绿。
    if ($code -ne -1073741819 -or $log -match '\[GameState\]|SCRIPT ERROR:') { break }
}
foreach ($path in $hashes.Keys) {
    if ((git hash-object -- $path) -ne $hashes[$path]) { throw "Source drift $path" }
}
$result = [int](-not $passed)
"DONE EXIT=$result" | Add-Content $report
exit $result
