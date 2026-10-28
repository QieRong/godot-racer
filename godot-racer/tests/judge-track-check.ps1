param([string]$Directory, [string]$Check)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repo '04-Godot启动器/check-result.ps1')
$receipt = Get-Content -Raw -LiteralPath (Join-Path $Directory 'receipt.json') | ConvertFrom-Json
$log = [IO.File]::ReadAllText((Join-Path $Directory 'stdout.log')) + [IO.File]::ReadAllText((Join-Path $Directory 'stderr.log'))
$result = Get-CheckResult -LogText $log -Check $Check -ProcessExitCode $receipt.exit_code -Killed $receipt.timed_out -TimedOut $receipt.timed_out
$result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $Directory 'strict-check-result.json') -Encoding utf8
$result | ConvertTo-Json -Compress
if (-not $result.Passed) { exit 1 }
exit 0
