$ErrorActionPreference = 'Stop'
$launcher = Join-Path (Split-Path -Parent $PSScriptRoot) '04-Godot启动器'
$runner = Join-Path $launcher 'run-check.ps1'
$progress = Join-Path $PSScriptRoot 'rel-final-dualfps-progress.csv'
'fps,check,level,run,attempt,exit,status,detail,log' | Set-Content -LiteralPath $progress -Encoding utf8

function Test-Result([string]$logPath, [string]$check) {
    if (-not (Test-Path -LiteralPath $logPath)) { return @{ OK = $false; Detail = 'NO_LOG' } }
    $log = Get-Content -LiteralPath $logPath -Raw -Encoding utf8
    if ($log -notmatch '\[CHECK\] 完成，退出') { return @{ OK = $false; Detail = 'NO_DONE' } }
    if ($log -match 'SCRIPT ERROR|Parse Error|Failed to load script|\[自检\].*✘') {
        return @{ OK = $false; Detail = 'ERROR_OR_RED_ASSERTION' }
    }
    if ($check -eq 'lap') {
        $m = [regex]::Match($log, '跑圈结束：用时 ([\d.]+)s 完成 (\d+) 圈 复位次数=(\d+)')
        $stuck = [regex]::Match($log, '卡住事件：(\d+) 次')
        $speed = [regex]::Match($log, '圈速：上圈=([\d.]+) 最快=([\d.]+)')
        if (-not $m.Success -or -not $stuck.Success -or -not $speed.Success) {
            return @{ OK = $false; Detail = 'MISSING_LAP_METRICS' }
        }
        $ok = [int]$m.Groups[2].Value -ge 3 -and [int]$m.Groups[3].Value -eq 0 -and
            [int]$stuck.Groups[1].Value -eq 0 -and [double]$speed.Groups[2].Value -gt 0 -and
            $log.Contains('跑圈验收 ✔ 车头方向正常') -and
            $log.Contains('跑圈验收 ✔ 连续多圈计时正常')
        $detail = 'laps={0};sec={1};best={2};stuck={3};reset={4};impact={5}' -f
            $m.Groups[2].Value, $m.Groups[1].Value, $speed.Groups[2].Value,
            $stuck.Groups[1].Value, $m.Groups[3].Value,
            ([regex]::Matches($log, '\[DEBUG-L4\] IMPACT n=')).Count
        return @{ OK = $ok; Detail = $detail }
    }
    $m = [regex]::Match($log, '对手用时 ([\d.]+) 秒（(\d+) 帧），最小完成圈数 = (\d+)')
    $cars = @([regex]::Matches($log, '(?m)^\[自检\]   AiCar\d+：\d+ 圈，自救 (\d+) 次，.*✔'))
    if (-not $m.Success -or $cars.Count -eq 0) {
        return @{ OK = $false; Detail = 'MISSING_OPPONENT_METRICS' }
    }
    $rescues = 0
    foreach ($car in $cars) { $rescues += [int]$car.Groups[1].Value }
    $ok = [int]$m.Groups[3].Value -ge 1 -and $rescues -eq 0 -and
        $log.Contains('对手验收 ✔ 全部对手都能独立跑完')
    $detail = 'min_laps={0};sec={1};frames={2};cars={3};rescues={4};collisions=not_instrumented' -f
        $m.Groups[3].Value, $m.Groups[1].Value, $m.Groups[2].Value, $cars.Count, $rescues
    return @{ OK = $ok; Detail = $detail }
}

foreach ($fps in @(60, 120)) {
    foreach ($case in @(@{ Check = 'lap'; Level = 3; Tag = 'lap' },
                      @{ Check = 'opponents'; Level = 3; Tag = 'oppL4' },
                      @{ Check = 'opponents'; Level = 4; Tag = 'oppL5' })) {
        foreach ($run in 1..3) {
            if ($fps -eq 60 -and $case.Tag -eq 'lap' -and $run -eq 1) { continue }
            $base = if ($case.Tag -eq 'lap') {
                "rel-final-dualfps-lap$fps-p$run"
            } else {
                "rel-final-dualfps-$($case.Tag)-$fps-$run"
            }
            $passed = $false
            foreach ($attempt in 1..2) {
                $name = if ($attempt -eq 1) { $base } else { "$base-retry1" }
                $console = Join-Path $PSScriptRoot "$name.console.txt"
                $logPath = Join-Path $PSScriptRoot "$name.log"
                Write-Host "START $name $(Get-Date -Format s)"
                Push-Location $launcher
                try {
                    & pwsh -NoProfile -File $runner -Check $case.Check -Level $case.Level -RenderFps $fps -LogName $name *> $console
                    $exitCode = $LASTEXITCODE
                } finally {
                    Pop-Location
                }
                "EXIT=$exitCode" | Add-Content -LiteralPath $console -Encoding utf8
                $result = Test-Result $logPath $case.Check
                $status = if ($result.OK) { 'PASS' } else { 'FAIL' }
                "$fps,$($case.Check),$($case.Level),$run,$attempt,$exitCode,$status,$($result.Detail),$name.log" |
                    Add-Content -LiteralPath $progress -Encoding utf8
                Write-Host "END $name exit=$exitCode $status $($result.Detail) $(Get-Date -Format s)"
                if ($result.OK) { $passed = $true; break }
            }
            if (-not $passed) { Write-Host "STOP: $base failed twice"; exit 1 }
        }
    }
}
Write-Host 'DONE: all remaining serial checks passed'
