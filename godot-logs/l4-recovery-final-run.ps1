$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
Set-Location (Split-Path -Parent $PSScriptRoot)
$report = 'godot-logs/l4-recovery-final-progress.log'
('HEAD=' + (git rev-parse HEAD)) | Set-Content $report
git status --short | Add-Content $report
$hashes = @{
    'godot-racer/scripts/ai_opponent.gd'='4086292fb43fbe7a733040138d6347bd5d3a6d3f'
    'godot-racer/scripts/racing_line.gd'='6c73df86b877c7d732f8fa6513cebcab30db4e24'
    'godot-racer/scripts/obstacle_field.gd'='bdf4d050e3e1f0f17ebaf3fc661c8d4503d725e4'
    'godot-racer/scripts/autopilot.gd'='e7dc6e923b31d996ca3db0f63bf42d787ca07a9d'
}
function Assert-Source {
    foreach ($path in $hashes.Keys) {
        if ((git hash-object -- $path) -ne $hashes[$path]) { throw "Source drift $path" }
    }
}
try {
    Assert-Source
    foreach ($path in $hashes.Keys) { "$path BLOB=$($hashes[$path])" | Add-Content $report }
    $console = 'E:\godot\Godot_v4.4.1-stable_win64_console.exe'
    foreach ($test in @('test_lateral_tracking','test_lane_tracking_envelope','test_probe_braking')) {
        & $console --headless --path godot-racer --log-file "$PWD/godot-logs/l4-recovery-$test.log" --script "res://tools/$test.gd" *> "godot-logs/l4-recovery-$test.out"
        "$test EXIT=$LASTEXITCODE" | Add-Content $report
        if ($LASTEXITCODE -ne 0) { throw "unit failure $test" }
    }
    'START corrected visual' | Add-Content $report
    & $console --path godot-racer --log-file "$PWD/godot-logs/l4-recovery-visual.log" --script "$PWD/godot-logs/capture-l4-pass.gd" -- --check=opponents --level=3 "--capture-out=$PWD/godot-logs/l4-recovery-pass.png" *> godot-logs/l4-recovery-visual.out
    $code = $LASTEXITCODE
    $log = Get-Content godot-logs/l4-recovery-visual.log -Raw
    $valid = $log -match '\[VISUAL\] start_crossed=true arc=26\d\.\d+ speed=\d+\.\d+ rescues=0'
    "visual EXIT=$code VALID=$valid" | Add-Content $report
    if ($code -ne 0 -or -not $valid) { throw 'invalid visual' }
    Assert-Source
    'DONE EXIT=0' | Add-Content $report
} catch {
    "ERROR $_" | Add-Content $report
    'DONE EXIT=1' | Add-Content $report
    exit 1
}
