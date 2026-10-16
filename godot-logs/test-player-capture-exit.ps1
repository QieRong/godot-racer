# 独立截图工具回归：图片有效、跨起点进入原窗口、无脚本错误、真实进程正常退出。
# 原 lap 必须自行完成且无失败；不重试、不接受已有图片、不改变控制/关卡/验收判据。
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$CaseName,
    [string]$CaptureScript = '',
    [ValidateRange(1, 1800)][int]$TimeoutSec = 420
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if ($CaptureScript -eq '') { $CaptureScript = Join-Path $PSScriptRoot 'capture-l4-player-pass.gd' }
$prefix = Join-Path $PSScriptRoot $CaseName
$png = "$prefix.png"
$receipt = "$prefix-receipt.log"
foreach ($suffix in @('.png', '.log', '.stdout.log', '.stderr.log', '-receipt.log')) {
    if (Test-Path -LiteralPath "$prefix$suffix") { throw "证据已存在，换 CaseName：$prefix$suffix" }
}
$head = & git -C $repo rev-parse HEAD
@("HEAD=$head", "CAPTURE_SCRIPT=$CaptureScript", 'SCOPE=capture exit and original lap completion; no control changes') |
    Set-Content -LiteralPath $receipt -Encoding utf8
$fixtureBlob = & git -C $repo hash-object -- $CaptureScript
"FIXTURE_BLOB=$fixtureBlob" | Add-Content -LiteralPath $receipt -Encoding utf8
$argList = @('--path', ('"' + (Join-Path $repo 'godot-racer') + '"'),
    '--verbose', '--log-file', ('"' + "$prefix.log" + '"'),
    '--script', ('"' + $CaptureScript + '"'), '--', '--check=lap', '--level=3',
    ('"--capture-out=' + $png + '"'))
$process = Start-Process -FilePath 'E:\godot\Godot_v4.4.1-stable_win64_console.exe' `
    -ArgumentList $argList -WorkingDirectory $repo -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput "$prefix.stdout.log" -RedirectStandardError "$prefix.stderr.log"
"PID=$($process.Id)" | Add-Content -LiteralPath $receipt -Encoding utf8
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
while (-not $process.WaitForExit(1000) -and [DateTime]::UtcNow -lt $deadline) {}
$timedOut = -not $process.HasExited
if ($timedOut) { $process.Kill($true); $process.WaitForExit() }
$exitCode = $process.ExitCode
$text = (Get-Content -LiteralPath "$prefix.stdout.log" -Raw) +
    (Get-Content -LiteralPath "$prefix.stderr.log" -Raw)
$pngOk = $false
if (Test-Path -LiteralPath $png) {
    $bytes = [IO.File]::ReadAllBytes($png)
    $pngOk = $bytes.Length -gt 32 -and
        [Convert]::ToHexString($bytes[0..7]) -eq '89504E470D0A1A0A' -and
        [Convert]::ToHexString($bytes[($bytes.Length-12)..($bytes.Length-1)]) -eq '0000000049454E44AE426082'
}
$crossed = $text -match '\[VISUAL\] player crossed_start'
$validFrame = $text -match '\[VISUAL\] player start_crossed=true arc=(26\d|27\d|280)\.\d+ speed=\d+\.\d+ .*result=0'
$scriptErrors = $text -match 'SCRIPT ERROR|Parse Error|ERROR:'
$lapCompleted = $text -match '\[CHECK\] 完成，退出' -and
    $text -match '跑圈验收 ✔ 连续多圈计时正常、无意外重置'
$checkFailures = $text -match '✘'
$leakedState = $text -match 'Leaked instance: GDScriptFunctionState'
$passed = -not $timedOut -and $exitCode -eq 0 -and $pngOk -and $crossed -and $validFrame -and
    -not $scriptErrors -and $lapCompleted -and -not $checkFailures -and -not $leakedState
@("PROCESS_EXIT=$exitCode", "TIMED_OUT=$timedOut", "PNG_VALID=$pngOk", "CROSSED_START=$crossed",
    "CAPTURE_VALID=$validFrame", "SCRIPT_ERRORS=$scriptErrors", "LAP_COMPLETED=$lapCompleted",
    "CHECK_FAILURES=$checkFailures", "LEAKED_FUNCTION_STATE=$leakedState", "PASS=$passed",
    "DONE EXIT=$(if ($passed) { 0 } else { 1 })") |
    Add-Content -LiteralPath $receipt -Encoding utf8
Get-Content -LiteralPath $receipt
if (-not $passed) { exit 1 }
