# 单一真相源守卫（SINGLE-SOURCE-OF-TRUTH GUARD）
#
# 为什么必须有这个东西：
#   这个仓库把**同一条物理事实**手写成了多个副本，靠注释里的一句"与 X 对齐"维持同步。
#   实测（2026-10-13，HEAD=4032f6d）：
#     · max_steer        → vehicle.gd:32 与 ai_opponent.gd:29 各定义一份
#     · steer_speed_falloff → vehicle.gd:36 与 ai_opponent.gd:35 各定义一份
#     · _steer_limit() 公式体 → vehicle.gd:1030 与 ai_opponent.gd:581 **逐字相同**
#     · max_lateral_accel → racing_line.gd:35(GRIP_BASE) / vehicle.gd:44 / ai_opponent.gd:41 三份
#     · 满舵判定 → bench.gd:393 用 0.45，而车辆真源 max_steer = 0.5（**已经对不上**）
#   于是任何一次单点修改都必然留下不同步的副本 —— 这正是"改了却像没改对地方"的根因之一。
#   （文档侧同病：AGENTS.md 的 SPLIT-* 有 21 处手写副本，见 2026-10-13 项目日志。）
#
# ⚠ 刻意「不注册进 run-all-checks.ps1」—— 与 steerbench-repro.ps1 / brakebench-repro.ps1
#   同一条理由（bench.gd:445 与 :773 有原话）：注册会破坏 check-readme 的
#   「N 项 ↔ 文档计数」契约，而改那条契约需要用户签字。
#   所以本脚本默认**只报告、永不失败**；加 -Strict 才以非零码判红。
#   等用户签字后，再决定要不要把它并进验收链。
#
# 用法：
#   pwsh -File .\check-dup-source.ps1            # 报告模式（看现状，不判红）
#   pwsh -File .\check-dup-source.ps1 -Strict    # 判红模式（出现 ✘ 即 exit 1）
param(
    [switch]$Strict
)

$ErrorActionPreference = "Continue"

# ⚠ 强制 UTF-8：本机默认 [Console]::OutputEncoding = gb2312(CP936)，而本脚本输出 ✔/✘
# （U+2714/U+2718）。不设这两行，本机看到的会是 `?`，无法目视判定。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here
$ScriptsDir = Join-Path $Root "godot-racer\scripts"

if (-not (Test-Path $ScriptsDir)) {
    Write-Host "找不到脚本目录: $ScriptsDir" -ForegroundColor Red
    exit 2
}

# 在 godot-racer/scripts 下（排除 addons/）逐行扫描，返回 { File, Line, Text }
function Find-Line {
    param([string]$Pattern)
    $res = New-Object System.Collections.ArrayList
    $files = Get-ChildItem -Path $ScriptsDir -Filter *.gd -Recurse -File |
             Where-Object { $_.FullName -notmatch '\\addons\\' -and $_.FullName -notmatch '\\\.godot\\' }
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Root.Length + 1)
        $i = 0
        foreach ($ln in (Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
            $i++
            if ($ln -match $Pattern) {
                [void]$res.Add([pscustomobject]@{ File = $rel; Line = $i; Text = $ln.Trim() })
            }
        }
    }
    return @($res)
}

function Show-Hits {
    param($Hits)
    foreach ($h in $Hits) {
        Write-Host ("        {0}:{1}  {2}" -f $h.File, $h.Line, $h.Text) -ForegroundColor DarkGray
    }
}

$passCount = 0
$failCount = 0
function Check {
    param([string]$Title, [bool]$Ok, $Hits, [string]$Detail = "")
    if ($Ok) {
        Write-Host ("  ✔ {0}" -f $Title) -ForegroundColor Green
        $script:passCount++
    } else {
        Write-Host ("  ✘ {0}" -f $Title) -ForegroundColor Red
        if ($Detail -ne "") { Write-Host ("      {0}" -f $Detail) -ForegroundColor Yellow }
        if ($null -ne $Hits) { Show-Hits $Hits }
        $script:failCount++
    }
}

Write-Host ""
Write-Host "=== 单一真相源守卫（只读诊断）===" -ForegroundColor Cyan
Write-Host ("工程: {0}" -f $ScriptsDir) -ForegroundColor DarkGray
Write-Host ""

# ---- ①② 转向常量：字面量只允许出现在 racing_line.gd（去重后的判据） ----
# 去重前判据是"定义点唯一"；但 @export 必须两边各声明一次（否则编辑器里调不了），
# 所以真正的判据是 "**值**只有一个来源" —— 也就是不许再有字面量副本。
$litSteer = Find-Line '^\s*(@export\s+)?var\s+max_steer\s*:=\s*[0-9]'
$litFall = Find-Line '^\s*(@export\s+)?var\s+steer_speed_falloff\s*:=\s*[0-9]'
$litAll = @($litSteer) + @($litFall)
Check -Title ("转向常量无字面量副本（max_steer {0} 处 / steer_speed_falloff {1} 处字面量）" -f $litSteer.Count, $litFall.Count) `
      -Ok ($litAll.Count -eq 0) -Hits $litAll `
      -Detail "两边都应写 `:= RacingLine.STEER_MAX` / `:= RacingLine.STEER_FALLOFF`，值只在 racing_line.gd 定义一次"

$constSteer = Find-Line '^\s*const\s+STEER_MAX\s*:='
$constFall = Find-Line '^\s*const\s+STEER_FALLOFF\s*:='
$okConst = ($constSteer.Count -eq 1) -and ($constFall.Count -eq 1) `
    -and (@($constSteer)[0].File -like '*racing_line.gd') `
    -and (@($constFall)[0].File -like '*racing_line.gd')
Check -Title ("常量唯一定义在 racing_line.gd（STEER_MAX {0} 处 / STEER_FALLOFF {1} 处）" -f $constSteer.Count, $constFall.Count) `
      -Ok $okConst -Hits (@($constSteer) + @($constFall)) `
      -Detail "→ 值只在这里定义，vehicle.gd 与 ai_opponent.gd 只引用"

# ---- ③ 转向权限公式体只能有一份（TDD 铁律：禁止复制公式） ----
$formula = Find-Line 'max_steer\s*\*\s*\(1\.0\s*-\s*clampf\('
$ok3 = ($formula.Count -eq 1) -and (@($formula)[0].File -like '*racing_line.gd')
Check -Title ("转向权限公式体唯一且在 racing_line.gd（实测 {0} 处）" -f $formula.Count) `
      -Ok $ok3 -Hits $formula `
      -Detail "该项目铁律：几何与限速唯一真相源在 racing_line.gd，禁止复制公式"

# ---- ④ max_lateral_accel / GRIP_BASE 的数值必须一致 ----
$latDefs = Find-Line '^\s*(@export\s+)?var\s+max_lateral_accel\s*:=\s*[0-9.]+'
$gripDefs = Find-Line '^\s*const\s+GRIP_BASE\s*:=\s*[0-9.]+'
$latVals = @()
foreach ($h in @($latDefs) + @($gripDefs)) {
    if ($h.Text -match '([0-9]+\.[0-9]+)') { $latVals += [double]$Matches[1] }
}
$latUnique = @($latVals | Sort-Object -Unique)
$ok4 = ($latUnique.Count -le 1) -and ($latVals.Count -ge 1)
Check -Title ("侧向加速度基准值一致（max_lateral_accel ×{0} / GRIP_BASE ×{1}）" -f $latDefs.Count, $gripDefs.Count) `
      -Ok $ok4 -Hits (@($latDefs) + @($gripDefs)) `
      -Detail "· 三份同值只是巧合式的同步；改 GRIP_BASE 时另两份不会跟着动（layout.gd 有守卫，vehicle/ai 没有）"

# ---- ⑤ 台架的「满舵」判定值必须等于车辆真源 max_steer ----
# 真源现在是 racing_line.gd 的 `const STEER_MAX`（去重后），不再是 vehicle.gd 的 @export 行。
$floatSteer = 0.0
if ($constSteer.Count -ge 1 -and $constSteer[0].Text -match '([0-9]+\.[0-9]+)') {
    $floatSteer = [double]$Matches[1]
}
$benchHits = Find-Line 'at_max_steer\s*:=\s*absf\(.*?-\s*([0-9]+\.[0-9]+)\)'
$benchVal = $null
foreach ($h in $benchHits) {
    if ($h.Text -match '-\s*([0-9]+\.[0-9]+)\)') { $benchVal = [double]$Matches[1]; break }
}
if ($null -ne $benchVal) {
    $ok5 = ([math]::Abs($benchVal - $floatSteer) -lt 1e-9)
    Check -Title ("台架满舵判定值 == vehicle.max_steer（台架 {0} vs 真源 {1}）" -f $benchVal, $floatSteer) `
          -Ok $ok5 -Hits $benchHits `
          -Detail "台架命名是 at_max_steer，实际测的是 0.45 —— 车辆真正的满舵区（0.45~0.5）从未被覆盖"
} else {
    Write-Host "  · 台架满舵判定未找到（bench.gd 可能已改写），跳过" -ForegroundColor DarkGray
}

# ---- ⑥（信息量，不判红）参考速度 40.0 的散落 ----
$ref40 = Find-Line '/\s*40\.0'
Write-Host ("  · 参考速度 40.0 共出现 {0} 处（信息量，不判红）" -f $ref40.Count) -ForegroundColor DarkGray
Show-Hits $ref40

# ---- 汇总 ----
Write-Host ""
Write-Host ("=== 汇总：{0} 项通过 / {1} 项不一致 ===" -f $passCount, $failCount) -ForegroundColor Cyan
if ($failCount -gt 0) {
    Write-Host "修法见 .workbuddy/memory 2026-10-13 日志「代码侧副本」一节；改动核心物理文件前需先签字。" -ForegroundColor DarkGray
}

if ($Strict -and $failCount -gt 0) { exit 1 }
exit 0
