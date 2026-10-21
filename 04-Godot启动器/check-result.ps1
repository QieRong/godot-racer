# 只消费已有证据，不重算游戏判据、不改变阈值。由 run-check.ps1 点入。
function Get-CheckResult {
    param(
        [string]$LogText,
        [string]$Check,
        [Nullable[int]]$ProcessExitCode,
        [bool]$Killed = $false,
        [bool]$TimedOut = $false
    )
    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($TimedOut) { $reasons.Add('PROCESS_TIMEOUT') }
    if ($Killed) { $reasons.Add('PROCESS_KILLED') }
    if ($null -eq $ProcessExitCode -or $ProcessExitCode -ne 0) { $reasons.Add("PROCESS_EXIT=$ProcessExitCode") }
    if ($LogText -notmatch '\[CHECK\] 完成') { $reasons.Add('CHECK_NOT_FINISHED') }

    $outcomes = @()
    $segmentAssertions = @()
    foreach ($line in ($LogText -split '\r?\n')) {
        if ($line -match '^RUNID\|') {
            $segmentAssertions = @()
            $outcomes = @()
        } elseif ($line -match '^(ASSERT|OUTCOME)\|(.*)$') {
            $tag = $Matches[1]
            try {
                $record = $Matches[2] | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $record -or $record -is [array] -or $record -isnot [pscustomobject]) { throw 'Not an object' }
                if ($tag -eq 'ASSERT') {
                    $segmentAssertions += $record
                    if ($record.result -eq 'FAIL') { $reasons.Add('ASSERT_FAIL') }
                    if ($record.result -notin @('PASS', 'FAIL', 'INFO', 'SKIP')) { $reasons.Add('ASSERT_RESULT_INVALID') }
                } else {
                    $outcomes += $record
                }
            } catch {
                $reasons.Add("${tag}_JSON_INVALID")
            }
        }
    }
    if ($outcomes.Count -ne 1) {
        $reasons.Add('FINAL_OUTCOME_MISSING_OR_DUPLICATE')
    } else {
        $outcome = $outcomes[0]
        if ($outcome.check -cne $Check) { $reasons.Add('OUTCOME_CHECK_MISMATCH') }
        if ($outcome.finished -isnot [bool] -or $outcome.finished -ne $true) { $reasons.Add('OUTCOME_NOT_FINISHED') }
        if ($outcome.measurement_status -cne 'COMPLETE') { $reasons.Add("MEASUREMENT_STATUS=$($outcome.measurement_status)") }
        if ($null -eq $outcome.failed_assertions -or $outcome.failed_assertions -ne 0) { $reasons.Add('OUTCOME_ASSERTIONS_FAILED') }
        if ($outcome.exit_code_requested -ne 0 -or $null -eq $outcome.exit_code_requested) { $reasons.Add('OUTCOME_EXIT_INVALID') }
        if ($segmentAssertions.Count -eq 0 -or $outcome.assertion_records -ne $segmentAssertions.Count) { $reasons.Add('ASSERTION_COUNT_MISMATCH_OR_EMPTY') }
        if (@($segmentAssertions | Where-Object { $_.result -eq 'PASS' }).Count -eq 0) { $reasons.Add('NO_PASS_ASSERTIONS') }
    }
    return [pscustomobject]@{ Passed=($reasons.Count -eq 0); Reasons=@($reasons.ToArray()) }
}
