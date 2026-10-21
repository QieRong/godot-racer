param([string]$Godot = 'E:\godot\Godot_v4.4.1-stable_win64.exe',
    [string]$EvidenceName = 'countdown-readability-20261021-matrix')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$project = Join-Path $repo 'godot-racer'
$outDir = Join-Path $repo ('godot-logs/' + $EvidenceName)
if (Test-Path -LiteralPath $outDir) { throw 'Use a fresh EvidenceName to preserve previous evidence.' }
New-Item -ItemType Directory -Path $outDir | Out-Null
$rows = @()
foreach ($width in @(1280, 1920)) {
    foreach ($ai in @($true, $false)) {
        foreach ($level in 0..4) {
            $name = 'l{0}-{1}-ai{2}' -f ($level + 1), $width, [int]$ai
            $log = Join-Path $outDir ($name + '.log')
            $prefix = (Join-Path $outDir $name).Replace('\', '/')
            $engineArgs = @('--verbose', '--rendering-method', 'gl_compatibility', '--path', $project,
                '--audio-driver', 'Dummy', '--log-file', $log,
                '--script', 'res://tests/countdown_readability_test.gd', '--',
                "--read-level=$level", "--read-width=$width", "--read-out=$prefix")
            if (-not $ai) { $engineArgs += '--read-no-ai' }
            # 直接启动实际exe并记录PID；外部watchdog也能覆盖原生崩溃弹窗阻塞。
            $start = [Diagnostics.ProcessStartInfo]::new()
            $start.FileName = $Godot
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            foreach ($argument in $engineArgs) { $start.ArgumentList.Add($argument) }
            $engine = [Diagnostics.Process]::Start($start)
            [pscustomobject]@{ Pid=$engine.Id; Exe=$Godot; Args=$engineArgs; Started=(Get-Date -Format o) } |
                ConvertTo-Json -Depth 4 | Set-Content (Join-Path $outDir ($name + '.process.json'))
            $stdout = $engine.StandardOutput.ReadToEndAsync()
            $stderr = $engine.StandardError.ReadToEndAsync()
            $timedOut = -not $engine.WaitForExit(60000)
            if ($timedOut) { $engine.Kill(); $engine.WaitForExit() }
            $stdout.GetAwaiter().GetResult() | Set-Content (Join-Path $outDir ($name + '.console.log'))
            $stderr.GetAwaiter().GetResult() | Set-Content (Join-Path $outDir ($name + '.stderr.log'))
            $engineExit = $engine.ExitCode
            Set-Content (Join-Path $outDir ($name + '.exit.txt')) $engineExit
            $raw = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
            $summary = [regex]::Match($raw, 'READABILITY_SUMMARY LEVEL=\d+ WIDTH=\d+ AI=\w+ PASS=(\d+) FAIL=(\d+)')
            $leaked = $raw -match 'ObjectDB instances leaked|Leaked instance:|resources still in use'
            $ok = -not $timedOut -and -not $leaked -and $engineExit -eq 0 -and $summary.Success -and
                [int]$summary.Groups[1].Value -gt 0 -and [int]$summary.Groups[2].Value -eq 0 -and
                $raw -notmatch 'SCRIPT ERROR|Parse Error|READABILITY_TIMEOUT|READABILITY FAIL|AUDIO_DRAIN_TIMEOUT'
            $rows += [pscustomobject]@{ Case=$name; Pid=$engine.Id; Passed=$ok; Exit=$engineExit; Timeout=$timedOut; Leaked=$leaked; Summary=$summary.Value }
            $engine.Dispose()
            $rows | Export-Csv -LiteralPath (Join-Path $outDir 'results.csv') -NoTypeInformation -Encoding utf8
            Write-Host ("{0}: {1}, exit={2} {3}" -f $name, $ok, $engineExit, $summary.Value)
        }
    }
}
$bad = @($rows | Where-Object { -not $_.Passed }).Count
Write-Host ("READABILITY_MATRIX PASS={0} FAIL={1}" -f ($rows.Count - $bad), $bad)
exit ([int]($bad -gt 0))
