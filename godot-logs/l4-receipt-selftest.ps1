$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)
$scriptPath = Join-Path $PSScriptRoot 'l4-player-baseline-run.ps1'
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw 'receipt script parse failure' }
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-L4Acceptance'
}, $true)
if ($null -ne $definition) {
    . ([scriptblock]::Create($definition.Extent.Text))
    $evaluate = { param($log, $expected) Test-L4Acceptance -Log $log -Expected $expected }
} else {
    # 执行原回执真正使用的谓词；不执行其旧 PID 等待或长验收。
    $predicate = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.BinaryExpressionAst] -and
        $node.Extent.Text -eq '$log -match ''跑圈验收 ✔'''
    }, $true)
    if ($null -eq $predicate) { throw 'legacy predicate not found' }
    $evaluate = [scriptblock]::Create('param($log, $expected) ' + $predicate.Extent.Text)
}
$bad = Get-Content godot-logs/l4-player-current-baseline.log -Raw
$good = Get-Content godot-logs/l4-envelope-opponents-1.log -Raw
$cases = @(
    @{ name='real L4 lap with 3 stuck / 5 resets must fail'; log=$bad; expected='跑圈验收 ✔'; pass=$false },
    @{ name='real complete opponents log passes'; log=$good; expected='对手验收 ✔'; pass=$true },
    @{ name='intermediate success cannot mask explicit failure'; log="[自检] 跑圈验收 ✔ intermediate`n[自检] 跑圈验收 ✘ reset`n[CHECK] 完成"; expected='跑圈验收 ✔'; pass=$false },
    @{ name='missing completion is incomplete'; log='[自检] 跑圈验收 ✔'; expected='跑圈验收 ✔'; pass=$false },
    @{ name='script error invalidates success marker'; log="SCRIPT ERROR: Invalid call`n[自检] 跑圈验收 ✔`n[CHECK] 完成"; expected='跑圈验收 ✔'; pass=$false },
    @{ name='completion without acceptance is not success'; log='[CHECK] 完成'; expected='跑圈验收 ✔'; pass=$false }
)
$failed = 0
foreach ($case in $cases) {
    $actual = [bool](& $evaluate $case.log $case.expected)
    $ok = $actual -eq $case.pass
    "$(@('FAIL','PASS')[[int]$ok]) $($case.name) actual=$actual"
    if (-not $ok) { $failed++ }
}
"RECEIPT_EXECUTED=$($cases.Count) RECEIPT_FAILURES=$failed"
exit ([int]($failed -gt 0))
