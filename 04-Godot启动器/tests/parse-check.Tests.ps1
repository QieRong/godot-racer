$script:parseCheck = Join-Path $PSScriptRoot '..\parse-check.ps1'
$script:project = Join-Path $PSScriptRoot '..\..\godot-racer'

Describe 'parse-check 缺失依赖契约' {
    It '默认模式会拒绝不存在的工程，而不是把检查跳过为成功' {
        $missingProject = Join-Path $TestDrive 'missing-project'

        & pwsh -NoProfile -File $script:parseCheck -Project $missingProject

        $LASTEXITCODE | Should Be 2
    }

    It '默认模式会拒绝显式指定的不存在 Godot' {
        $missingGodot = Join-Path $TestDrive 'missing-godot.exe'

        & pwsh -NoProfile -File $script:parseCheck -Project $script:project -GodotPath $missingGodot

        $LASTEXITCODE | Should Be 2
    }

    It '明确允许缺失时会报告 AllowMissing 跳过' {
        $missingGodot = Join-Path $TestDrive 'missing-godot.exe'

        $output = & pwsh -NoProfile -File $script:parseCheck -Project $script:project -GodotPath $missingGodot -AllowMissing 2>&1 | Out-String

        $LASTEXITCODE | Should Be 0
        $output | Should Match 'AllowMissing'
    }
}
