# 顺序后台验收；父终端退出不丢日志。所有引擎任务串行运行。
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$prefix = Join-Path $PSScriptRoot 'gate-l4-001'
"HEAD=$(git rev-parse HEAD)" | Set-Content "$prefix-validation.log" -Encoding utf8
git status --short | Add-Content "$prefix-validation.log" -Encoding utf8
$checks = @(
    @{ name='lint'; script='lint-gdscript.ps1'; args=@() },
    @{ name='parse'; script='parse-check.ps1'; args=@() },
    @{ name='docs'; script='check-docs.ps1'; args=@() },
    @{ name='readme'; script='check-readme.ps1'; args=@() },
    @{ name='dup'; script='check-dup-source.ps1'; args=@() },
    @{ name='opponents'; script='run-all-checks.ps1'; args=@('-Only','opponents') },
    @{ name='quick'; script='run-all-checks.ps1'; args=@('-Quick') }
)
foreach ($check in $checks) {
    "START $($check.name)" | Add-Content "$prefix-validation.log"
    $arguments = $check.args
    & pwsh -NoProfile -File (Join-Path $root "04-Godot启动器/$($check.script)") @arguments *> "$prefix-$($check.name).log"
    $code = $LASTEXITCODE
    "$($check.name) EXIT=$code" | Add-Content "$prefix-validation.log"
    # 已知 opponents 红灯不阻止其余回归；其它失败停止，先定位原因。
    if ($code -ne 0 -and $check.name -ne 'opponents') { exit $code }
}
'DONE' | Add-Content "$prefix-validation.log"
