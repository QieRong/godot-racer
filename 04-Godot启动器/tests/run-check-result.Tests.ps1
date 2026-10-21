# 运行真实 runner，替身仅替代引擎进程；不启动 Godot、不改验收阈值。
$script:launcherDir = Split-Path -Parent $PSScriptRoot

Describe 'run-check final evidence and process status' {
    function New-Log([string]$Status = 'COMPLETE', [int]$Failures = 0) {
        $outcome = @{check='aidiag'; finished=$true; measurement_status=$Status;
            failed_assertions=$Failures; assertion_records=1; exit_code_requested=0}
        return "RUNID|{`"check`":`"aidiag`"}`nASSERT|{`"result`":`"PASS`"}`n[CHECK] 完成，退出`nOUTCOME|$($outcome | ConvertTo-Json -Compress)"
    }

    function Invoke-RunnerFixture([string]$Log, [int]$ProcessExit = 0) {
        $root = Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        $launcher = Join-Path $root 'launcher'
        New-Item -ItemType Directory -Path $launcher, (Join-Path $root 'godot-logs'), (Join-Path $root 'godot-racer') | Out-Null
        Copy-Item (Join-Path $script:launcherDir 'run-check.ps1') $launcher
        $helper = Join-Path $script:launcherDir 'check-result.ps1'
        if (Test-Path $helper) { Copy-Item $helper $launcher }
        Set-Content -Encoding UTF8 (Join-Path $launcher 'tape-preflight.ps1') 'exit 0'
        $wrapper = Join-Path $root 'invoke.ps1'
        Set-Content -Encoding UTF8 $wrapper @'
function Test-Path { param($Path, $LiteralPath) if ($Path -eq 'E:\godot\Godot_v4.4.1-stable_win64.exe') { return $true }; if ($LiteralPath) { Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath } else { Microsoft.PowerShell.Management\Test-Path $Path } }
function Start-Sleep { param($Seconds) }
function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory, [switch]$NoNewWindow, [switch]$PassThru)
    Add-Content (Join-Path $PSScriptRoot 'starts.txt') 'start'
    $index = [array]::IndexOf($ArgumentList, '--log-file')
    Set-Content -Encoding UTF8 $ArgumentList[$index + 1] $env:RUNNER_FIXTURE_LOG
    $p = [pscustomobject]@{HasExited=$true; ExitCode=[int]$env:RUNNER_FIXTURE_EXIT; Handle=1}
    $p | Add-Member ScriptMethod Refresh {}
    $p | Add-Member ScriptMethod WaitForExit {}
    $p | Add-Member ScriptMethod Kill {}
    return $p
}
& (Join-Path $PSScriptRoot 'launcher/run-check.ps1') -Check aidiag -SkipLint -MaxTries 3 -LogName fixture
exit $LASTEXITCODE
'@
        $oldLog = $env:RUNNER_FIXTURE_LOG
        $oldExit = $env:RUNNER_FIXTURE_EXIT
        try {
            $env:RUNNER_FIXTURE_LOG = $Log
            $env:RUNNER_FIXTURE_EXIT = "$ProcessExit"
            $output = & pwsh -NoProfile -File $wrapper 2>&1 | Out-String
            $code = $LASTEXITCODE
            return @{Code=$code; Output=$output; Starts=@(Get-Content (Join-Path $root 'starts.txt')).Count;
                SavedAttempts=@(Get-ChildItem (Join-Path $root 'godot-logs') -Filter '*.attempt-*.log').Count}
        } finally {
            $env:RUNNER_FIXTURE_LOG = $oldLog
            $env:RUNNER_FIXTURE_EXIT = $oldExit
        }
    }

    It 'accepts complete evidence and normal exit' {
        $r = Invoke-RunnerFixture (New-Log)
        $r.Code | Should Be 0
    }
    It 'rejects known aidiag incomplete outcome even with completion text' {
        $r = Invoke-RunnerFixture (New-Log 'INPUT_EVIDENCE_INCOMPLETE' 2)
        $r.Code | Should Be 7
        $r.Starts | Should Be 1
    }
    It 'rejects assertion failure even when outcome claims zero failures' {
        $r = Invoke-RunnerFixture ((New-Log) -replace '"result":"PASS"', '"result":"FAIL"')
        $r.Code | Should Be 7
    }
    It 'rejects crash after PASS and never retries a started check' {
        $r = Invoke-RunnerFixture (New-Log) -ProcessExit -1073741819
        $r.Code | Should Be 7
        $r.Starts | Should Be 1
    }
    It 'rejects completion text without final outcome' {
        $r = Invoke-RunnerFixture '[CHECK] 完成，退出'
        $r.Code | Should Be 7
    }
    It 'rejects malformed final JSON' {
        $r = Invoke-RunnerFixture ((New-Log) + "`nOUTCOME|{broken}")
        $r.Code | Should Be 7
    }
    It 'rejects an outcome for a different check' {
        $r = Invoke-RunnerFixture ((New-Log) -replace '"check":"aidiag"', '"check":"pause"')
        $r.Code | Should Be 7
    }
    It 'rejects zero assertions rather than passing an empty test' {
        $r = Invoke-RunnerFixture ((New-Log) -replace '"assertion_records":1', '"assertion_records":0')
        $r.Code | Should Be 7
    }
    It 'rejects runtime script errors despite PASS evidence' {
        $r = Invoke-RunnerFixture ((New-Log) + "`nSCRIPT ERROR: Invalid access to property visible on Nil")
        $r.Code | Should Be 5
    }
    It 'keeps calibration output distinct from formal acceptance' {
        $r = Invoke-RunnerFixture (New-Log 'CALIBRATION_ONLY')
        $r.Code | Should Be 7
    }
    It 'accepts cross-scene checks with the final RUNID assertion count' {
        $r = Invoke-RunnerFixture ("RUNID|{}`nASSERT|{`"result`":`"PASS`"}`n" + (New-Log))
        $r.Code | Should Be 0
    }
    It 'does not erase failures from the scene before reload' {
        $r = Invoke-RunnerFixture ("RUNID|{}`nASSERT|{`"result`":`"FAIL`"}`n" + (New-Log))
        $r.Code | Should Be 7
    }
    It 'only retries startup crashes and preserves each earlier attempt log' {
        $r = Invoke-RunnerFixture 'startup diagnostic only' -ProcessExit -1073741819
        $r.Code | Should Be 7
        $r.Starts | Should Be 3
        $r.SavedAttempts | Should Be 2
    }
    It 'rejects killed or timed out processes even if final evidence is complete' {
        . (Join-Path $script:launcherDir 'check-result.ps1')
        (Get-CheckResult -LogText (New-Log) -Check aidiag -ProcessExitCode 0 -Killed $true).Passed | Should Be $false
        (Get-CheckResult -LogText (New-Log) -Check aidiag -ProcessExitCode 0 -TimedOut $true).Passed | Should Be $false
        (Get-CheckResult -LogText (New-Log) -Check aidiag).Passed | Should Be $false
    }
}
