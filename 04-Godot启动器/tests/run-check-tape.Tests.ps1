# tape-preflight.ps1 契约测试（Pester 3.4 兼容；进程内直调，不启 Godot）。
#
# 钉死的行为（2026-10-19 任务 B）：
#   · 正式验收口径只走**已冻结**输入带回放 —— run-check.ps1 在启动 Godot **之前**
#     调用 tape-preflight.ps1 做文件级预检：清单存在 / state=FROZEN / 数据文件在侧且为
#     裸文件名 / input_tape_hash 相符；任一不满足 → exit 8 秒级失败。
#   · 实时驱动**不做静默兜底**：只保留在 -AiTapeMode calibrate（校准生成候选带）。
#     依据题 D 裁定「测量条件未建立 = 非通过」，不允许拿不稳定的实时驱动挑最好的一次。
#   · 只作用于 -Check aidiag：其它检查、calibrate 模式、自定义 -AiTapeManifest 一律跳过。
#   · 与代码版本相关的绑定（level_config / driver / acceptance_contract /
#     track_geometry）仍由引擎内 ai_tape.setup() 判定，预检不复制第二份真相。
#
# ⚠ 断言模式一律用 ASCII 错误码（TAPE_*）：本机控制台 CP936，中文经子进程/pipeline
#   传递会被降级，比对中文会假红。状态行走 Write-Output（可被 pipeline 捕获），
#   中文指引用 Write-Host（只给人看，不进断言）。
$script:launcherDir = Split-Path -Parent $PSScriptRoot
$script:tapePreflight = Join-Path $script:launcherDir 'tape-preflight.ps1'
$script:frozenSource = Join-Path (Split-Path -Parent $script:launcherDir) 'godot-racer\data\checks\frozen'

Describe 'tape-preflight 冻结带预检（冻结优先，缺失/作废秒级失败）' {

    # fixture 只造 godot-racer/data/checks/frozen 树：预检是纯文件检查，
    # 不启动任何引擎，因此不需要（也不能有）Godot 工程。
    function New-TapeFixture {
        param(
            [bool]$WithManifest = $true,
            [string]$State = 'FROZEN',
            [bool]$DataIntact = $true
        )
        $root = Join-Path $TestDrive ('fx-' + [Guid]::NewGuid().ToString('N'))
        $frozen = Join-Path $root 'godot-racer\data\checks\frozen'
        New-Item -ItemType Directory -Force -Path $frozen | Out-Null
        if ($WithManifest) {
            Copy-Item (Join-Path $script:frozenSource 'scenario.json') (Join-Path $frozen 'scenario.json')
            Copy-Item (Join-Path $script:frozenSource 'input-tape.json') (Join-Path $frozen 'input-tape.json')
            if ($State -ne 'FROZEN') {
                $mp = Join-Path $frozen 'scenario.json'
                $txt = Get-Content -Raw -LiteralPath $mp
                $txt = $txt -replace '"state":"FROZEN"', ('"state":"' + $State + '"')
                Set-Content -LiteralPath $mp -Value $txt -NoNewline
            }
            if (-not $DataIntact) {
                Add-Content -LiteralPath (Join-Path $frozen 'input-tape.json') -Value 'tamper'
            }
        }
        return $root
    }

    It '冻结带完好 → exit 0 + TAPE_PREFLIGHT_OK + manifest 指纹' {
        $root = New-TapeFixture
        $expect = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $script:frozenSource 'scenario.json')).Hash
        $out = & $script:tapePreflight -Check aidiag -ProjDir $root 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out | Should Match 'TAPE_PREFLIGHT_OK state=FROZEN'
        $out | Should Match ('manifest_sha256=' + $expect)
        $out | Should Match 'frames=5041'
    }

    It '冻结清单缺失 → TAPE_MANIFEST_MISSING，exit 8' {
        $root = New-TapeFixture -WithManifest $false
        $out = & $script:tapePreflight -Check aidiag -ProjDir $root 2>&1 | Out-String
        $LASTEXITCODE | Should Be 8
        $out | Should Match 'TAPE_PREFLIGHT_FAIL code=TAPE_MANIFEST_MISSING'
    }

    It 'state 非 FROZEN → TAPE_NOT_FROZEN，exit 8' {
        $root = New-TapeFixture -State 'CALIBRATED_NOT_FROZEN'
        $out = & $script:tapePreflight -Check aidiag -ProjDir $root 2>&1 | Out-String
        $LASTEXITCODE | Should Be 8
        $out | Should Match 'TAPE_PREFLIGHT_FAIL code=TAPE_NOT_FROZEN'
        $out | Should Match 'state=CALIBRATED_NOT_FROZEN'
    }

    It '数据文件哈希不符 → TAPE_DATA_HASH_MISMATCH，exit 8' {
        $root = New-TapeFixture -DataIntact $false
        $out = & $script:tapePreflight -Check aidiag -ProjDir $root 2>&1 | Out-String
        $LASTEXITCODE | Should Be 8
        $out | Should Match 'TAPE_PREFLIGHT_FAIL code=TAPE_DATA_HASH_MISMATCH'
    }

    It '数据文件缺失 → TAPE_DATA_FILE_MISSING，exit 8' {
        $root = New-TapeFixture
        Remove-Item -LiteralPath (Join-Path $root 'godot-racer\data\checks\frozen\input-tape.json')
        $out = & $script:tapePreflight -Check aidiag -ProjDir $root 2>&1 | Out-String
        $LASTEXITCODE | Should Be 8
        $out | Should Match 'TAPE_PREFLIGHT_FAIL code=TAPE_DATA_FILE_MISSING'
    }

    It '非 aidiag 检查 → 跳过（NOT_AIDIAG），exit 0' {
        $root = New-TapeFixture -WithManifest $false
        $out = & $script:tapePreflight -Check enclosure -ProjDir $root 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out | Should Match 'TAPE_PREFLIGHT_SKIP reason=NOT_AIDIAG'
    }

    It 'calibrate 模式 → 跳过（CALIBRATE_MODE），exit 0（实时驱动只用于生成候选带）' {
        $root = New-TapeFixture -WithManifest $false
        $out = & $script:tapePreflight -Check aidiag -AiTapeMode calibrate -ProjDir $root 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out | Should Match 'TAPE_PREFLIGHT_SKIP reason=CALIBRATE_MODE'
    }

    It '自定义 -AiTapeManifest → 跳过（CUSTOM_MANIFEST），exit 0' {
        $root = New-TapeFixture -WithManifest $false
        $out = & $script:tapePreflight -Check aidiag -AiTapeManifest 'res://data/checks/frozen-superseded-1/scenario.json' -ProjDir $root 2>&1 | Out-String
        $LASTEXITCODE | Should Be 0
        $out | Should Match 'TAPE_PREFLIGHT_SKIP reason=CUSTOM_MANIFEST'
    }
}
