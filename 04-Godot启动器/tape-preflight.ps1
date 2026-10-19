# aidiag 冻结输入带预检（被 run-check.ps1 在启动 Godot **之前**调用；独立文件以便单测）。
#
# 为什么单独一个文件：run-check.ps1 肩负启动引擎的长流程，预检逻辑混在里面就只能
# 整脚本跑（真启 Godot）才能测 —— 又慢又可能在测试里弹出引擎窗口。拆开后预检是
# 纯文件检查，Pester 进程内直调即可（tests/run-check-tape.Tests.ps1）。
#
# 契约（退出码）：
#   0  预检通过（stdout: TAPE_PREFLIGHT_OK ...），或本次不适用
#      （TAPE_PREFLIGHT_SKIP reason=...：非 aidiag / calibrate 模式 / 自定义清单）
#   8  冻结带不可用（stdout: TAPE_PREFLIGHT_FAIL code=...）——测量条件未建立，
#      调用方必须失败，不得静默继续
#
# 语义（2026-10-19 任务 B，冻结优先）：
#   正式验收只走**已冻结**输入带回放（-AiTapeMode replay 为默认）。实时驱动
#   **不做静默兜底** —— 它只保留在 -AiTapeMode calibrate（校准生成候选带）。
#   依据题 D 裁定「测量条件未建立 = 非通过」：不允许拿不稳定的实时驱动挑最好的一次。
#
# 判定面（只做**文件级自洽**）：
#   ① godot-racer/data/checks/frozen/scenario.json 存在
#   ② state == FROZEN（CALIBRATED_NOT_FROZEN / 缺失都算未冻结）
#   ③ input_schedule.data_file 是同目录**裸文件名**（与引擎侧同款，拒路径穿越）
#   ④ 数据文件在侧且 input_tape_hash == 其 SHA256
# ⚠ 与代码版本相关的绑定（level_config / driver / acceptance_contract /
#   track_geometry）仍由引擎内 ai_tape.setup() 判定 —— 预检不复制第二份真相，
#   那种"过期冻结带"仍会在引擎内失败（TAPE_NOT_FROZEN / SCENARIO_BINDING_MISMATCH），
#   只是多花一次冷启动；本预检保的是"缺带/作废/损坏"的秒级失败。
#
# ⚠ ASCII 状态行走 Write-Output（可被 pipeline 捕获、供测试与 run-all 汇总断言）；
#   中文指引用 Write-Host（只给人看）。本机控制台 CP936，中文被子进程传递会降级。
param(
    [string]$Check = 'enclosure',
    [ValidateSet('replay','calibrate')][string]$AiTapeMode = 'replay',
    [string]$AiTapeManifest = '',
    [string]$ProjDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Continue'

# ⚠ 退出码写在函数末尾的 `exit 8`（PowerShell 语义：函数内 exit 终止整个脚本，
#   已实测）。曾经想写成 `exit (Fail-Tape ...)` 让调用方更短 —— 函数的
#   Write-Output 会混进返回值，exit 拿到数组后退出码变 0，测试当场抓到
#   （Expected 8 But was 0），故维持裸调用 + 函数内 exit。
function Fail-Tape([string]$Code, [string]$Detail) {
    Write-Host ""
    Write-Host ("!! aidiag 冻结输入带预检失败 [{0}]：{1}" -f $Code, $Detail) -ForegroundColor Red
    Write-Host "!! 正式验收只走冻结回放；实时驱动仅用于 -AiTapeMode calibrate 生成候选带，不做静默兜底。" -ForegroundColor Yellow
    Write-Host "!! 若代码改动使绑定失效：重跑「校准生成 -> ai-tape-freeze.py 冻结」两步后再验收。" -ForegroundColor Yellow
    Write-Output ("TAPE_PREFLIGHT_FAIL code={0} detail={1}" -f $Code, $Detail)
    exit 8
}

# ---- 不适用：直接放行（不拦其它检查、不拦校准模式、不拦自定义清单）----
if ($Check -ne 'aidiag') { Write-Output 'TAPE_PREFLIGHT_SKIP reason=NOT_AIDIAG'; exit 0 }
if ($AiTapeMode -ne 'replay') { Write-Output 'TAPE_PREFLIGHT_SKIP reason=CALIBRATE_MODE'; exit 0 }
if (-not [string]::IsNullOrWhiteSpace($AiTapeManifest)) { Write-Output 'TAPE_PREFLIGHT_SKIP reason=CUSTOM_MANIFEST'; exit 0 }

$tapeDir = Join-Path $ProjDir 'godot-racer\data\checks\frozen'
$manifestPath = Join-Path $tapeDir 'scenario.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Fail-Tape 'TAPE_MANIFEST_MISSING' $manifestPath
}

$manifest = $null
try {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
} catch {
    $manifest = $null
}
if ($null -eq $manifest) {
    Fail-Tape 'TAPE_MANIFEST_INVALID_JSON' $manifestPath
}

$state = [string]$manifest.state
if ($state -ne 'FROZEN') {
    Fail-Tape 'TAPE_NOT_FROZEN' ("state=" + $state)
}

$dataName = [string]$manifest.input_schedule.data_file
if ([string]::IsNullOrWhiteSpace($dataName)) {
    Fail-Tape 'TAPE_DATA_FILE_UNNAMED' 'input_schedule.data_file 为空'
}
if ($dataName -ne (Split-Path -Leaf $dataName)) {
    Fail-Tape 'TAPE_DATA_FILE_NOT_ADJACENT' $dataName
}
$dataPath = Join-Path $tapeDir $dataName
if (-not (Test-Path -LiteralPath $dataPath)) {
    Fail-Tape 'TAPE_DATA_FILE_MISSING' $dataPath
}

$expectHash = [string]$manifest.input_tape_hash
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $dataPath).Hash
if ($expectHash -ne $actualHash) {
    Fail-Tape 'TAPE_DATA_HASH_MISMATCH' ("expect=" + $expectHash + " actual=" + $actualHash)
}

$manifestHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $manifestPath).Hash
Write-Output ("[tape-preflight] TAPE_PREFLIGHT_OK state=FROZEN manifest_sha256={0} data={1} frames={2}" -f $manifestHash, $dataName, $manifest.input_schedule.frame_count)
exit 0
