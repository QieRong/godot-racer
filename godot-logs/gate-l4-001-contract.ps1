# GATE-L4-001：执行真实套件脚本、替换引擎子进程，验证覆盖与失败传播。
# 临时夹具不启动 Godot，不修改生产脚本；运行证据另存。
param([string]$Root = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$failed = 0
function Assert-Contract([bool]$Condition, [string]$Name) {
    if ($Condition) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name"; $script:failed++ }
}
$runner = Join-Path $Root '04-Godot启动器/run-all-checks.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($runner, [ref]$tokens, [ref]$errors)
Assert-Contract ($errors.Count -eq 0) 'PowerShell syntax'
$assignment = $ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$all'
}, $true)
$rows = @(& ([scriptblock]::Create($assignment.Extent.Text + "`n" + '$all')))
$opponents = @($rows | Where-Object n -eq 'opponents')
Assert-Contract ($rows.Count -eq 20) '20 suite rows'
Assert-Contract (@($rows | Where-Object { -not $_.slow }).Count -eq 15) 'Quick remains 15'
Assert-Contract ($opponents.Count -eq 2 -and @($opponents | Where-Object lv -eq 3).Count -eq 1 -and @($opponents | Where-Object lv -eq 4).Count -eq 1) 'L4 and L5 exactly once'
Assert-Contract (@($opponents | Where-Object { -not $_.slow -or $_.ok -ne '对手验收 ✔' }).Count -eq 0) 'unchanged opponent criterion; both slow'

$fixture = Join-Path $Root ('godot-logs/gate-l4-001-fixture-' + [guid]::NewGuid().ToString('N'))
$launcher = Join-Path $fixture 'launcher'
New-Item -ItemType Directory -Path $launcher,(Join-Path $fixture 'godot-logs') -Force | Out-Null
Copy-Item -LiteralPath $runner -Destination (Join-Path $launcher 'run-all-checks.ps1')
@'
param([string]$Check, [int]$MaxTries, [int]$Level=-1, [string]$LogName='')
if (-not $LogName) { $LogName = "check-$Check" }
$log = Join-Path (Split-Path -Parent $PSScriptRoot) "godot-logs/$LogName.log"
"check=$Check level=$Level tries=$MaxTries" | Set-Content -LiteralPath $log -Encoding utf8
"level=$Level tries=$MaxTries" | Add-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'calls.txt')
Write-Host "STUB level=$Level log=$LogName tries=$MaxTries"
if ("$Level" -eq $env:GATE_L4_TEST_FAIL_LEVEL) { Write-Host '对手验收 ✘'; exit 0 }
Write-Host '对手验收 ✔'
exit 0
'@ | Set-Content -LiteralPath (Join-Path $launcher 'run-check.ps1') -Encoding utf8
$previous = $env:GATE_L4_TEST_FAIL_LEVEL
try {
    foreach ($case in @('none', '3', '4')) {
        $env:GATE_L4_TEST_FAIL_LEVEL = $case
        Set-Content -LiteralPath (Join-Path $fixture 'calls.txt') -Value ''
        $output = & pwsh -NoProfile -File (Join-Path $launcher 'run-all-checks.ps1') -Only opponents 2>&1 | Out-String
        $code = $LASTEXITCODE
        Write-Host "CASE fail=$case exit=$code"
        $expected = if ($case -eq 'none') { 0 } else { 1 }
        Assert-Contract ($code -eq $expected) "failure propagation ($case)"
        $calls = Get-Content (Join-Path $fixture 'calls.txt') -Raw
        Assert-Contract ($calls -match 'level=3 tries=4' -and $calls -match 'level=4 tries=4') "both levels executed; retries unchanged ($case)"
        foreach ($level in @(3,4)) {
            $path = Join-Path $fixture "godot-logs/check-opponents-L$($level + 1).log"
            Assert-Contract ((Test-Path $path) -and (Get-Content $path -Raw) -match "level=$level ") "independent L$($level + 1) log ($case)"
        }
        if ($case -ne 'none') {
            Assert-Contract ($output -match ('有 1 项失败：opponents \(L' + ([int]$case + 1) + '\)')) "failure names level ($case)"
        }
    }
} finally {
    $env:GATE_L4_TEST_FAIL_LEVEL = $previous
    # 只清理由本脚本创建、且解析后仍位于本仓库 godot-logs 下的唯一夹具。
    $resolved = [IO.Path]::GetFullPath($fixture)
    $allowed = [IO.Path]::GetFullPath((Join-Path $Root 'godot-logs')) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($allowed, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe fixture path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host "CONTRACT_FAILURES=$failed"
if ($failed -gt 0) { exit 1 }
exit 0
