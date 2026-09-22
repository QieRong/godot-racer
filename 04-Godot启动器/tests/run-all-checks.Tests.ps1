$script:runAllSource = Join-Path $PSScriptRoot '..\run-all-checks.ps1'

Describe 'run-all-checks 验收调度契约' {
    It '会执行 aidiag，并在汇总中记录启动时的 Git HEAD' {
        $root = Join-Path $TestDrive 'fixture'
        $launcher = Join-Path $root '04-Godot启动器'
        $bin = Join-Path $root 'bin'
        $probe = Join-Path $root 'checks.txt'
        New-Item -ItemType Directory -Force -Path $launcher, $bin | Out-Null
        Copy-Item $script:runAllSource (Join-Path $launcher 'run-all-checks.ps1')

        Set-Content (Join-Path $launcher 'check-docs.ps1') 'Write-Output "文档与实现一致 ✔"'
        Set-Content (Join-Path $launcher 'check-readme.ps1') 'Write-Output "README 与项目一致 ✔"'
        Set-Content (Join-Path $launcher 'run-check.ps1') @'
param([string]$Check, [int]$MaxTries, [int]$Level)
Add-Content -Path $env:RUN_ALL_PROBE -Value $Check
if ($Check -eq 'aidiag') { Write-Output 'AI 诊断 ✔ 不抢跑、不发车后停顿、不依赖自救' }
'@
        Set-Content (Join-Path $bin 'git.cmd') @'
@echo off
if "%~3"=="rev-parse" echo deadbeefcafebabe
'@

        $oldPath = $env:Path
        $oldProbe = $env:RUN_ALL_PROBE
        try {
            $env:Path = "$bin;$oldPath"
            $env:RUN_ALL_PROBE = $probe
            $output = & pwsh -NoProfile -File (Join-Path $launcher 'run-all-checks.ps1') -Only aidiag 2>&1 | Out-String

            $LASTEXITCODE | Should Be 0
            (Get-Content -Raw $probe) | Should Match 'aidiag'
            $output | Should Match 'Git HEAD: deadbeefcafebabe'
        } finally {
            $env:Path = $oldPath
            $env:RUN_ALL_PROBE = $oldProbe
        }
    }
}
