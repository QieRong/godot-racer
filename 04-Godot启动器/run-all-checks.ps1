# 按顺序跑完全部验收检查，最后汇总成一张表。
#
# 为什么要这个：验收项已经有十余项（还在长），一项一项手敲命令既慢又容易漏。
# 这个脚本保证"每次提交前跑的是同一套"，并把结果汇总到一眼能看的地方。
#
# 用法：
#   pwsh -File .\run-all-checks.ps1              # 全部
#   pwsh -File .\run-all-checks.ps1 -Quick       # 只跑快的（跳过 lap/stress/opponents）
#   pwsh -File .\run-all-checks.ps1 -Only avoid,pause
param(
    [switch]$Quick,
    [string[]]$Only = @()
)

$ErrorActionPreference = "Continue"
$Here = $PSScriptRoot

# 每项：名称 / 关卡（-1 = 用默认 / -9 = 不启动 Godot 的特殊项）/ 通过标志 / 是否耗时
$all = @(
    @{ n='docs';      lv=-8; ok='文档与实现一致 ✔';                   slow=$false },
    @{ n='readme';    lv=-9; ok='README 与项目一致 ✔';               slow=$false },
    @{ n='enclosure'; lv=-1; ok='围墙封闭 ✔';                        slow=$false },
    @{ n='wallslide'; lv=-1; ok='卡墙验收：12/12 通过 ✔';             slow=$false },
    @{ n='minimap';   lv=3;  ok='障碍物标记：障碍';                   slow=$false },
    @{ n='obstacles'; lv=4;  ok='障碍物验收 ✔';                       slow=$false },
    @{ n='aistart';   lv=4;  ok='并排发车验收 ✔';                     slow=$false },
    @{ n='avoid';     lv=4;  ok='避让验收 ✔';                         slow=$false },
    @{ n='pause';     lv=2;  ok='暂停验收 ✔';                         slow=$false },
    @{ n='flip';      lv=-1; ok='翻车恢复验收 ✔';                     slow=$false },
    @{ n='layout';    lv=-1; ok='赛道布局验收 ✔';                     slow=$false },
    @{ n='reverse';   lv=-1; ok='reverse 验收 ✔';                     slow=$false },
    @{ n='weather';   lv=4;  ok='天气验收 ✔';                         slow=$false },
    @{ n='friction';  lv=4;  ok='抓地力验收 ✔';                       slow=$false },
    @{ n='phys';      lv=4;  ok='物理开销 ✔';                         slow=$false },
    @{ n='stress';    lv=-1; ok='压测验收 ✔';                         slow=$true  },
    @{ n='opponents'; lv=4;  ok='对手验收 ✔';                         slow=$true  },
    @{ n='lap';       lv=-1; ok='跑圈验收 ✔';                         slow=$true  }
)

$list = $all
if ($Only.Count -gt 0) {
    $list = $all | Where-Object { $Only -contains $_.n }
} elseif ($Quick) {
    $list = $all | Where-Object { -not $_.slow }
}

$results = @()
$i = 0
foreach ($c in $list) {
    $i++
    Write-Host ""
    Write-Host ("=" * 60)
    Write-Host ("[{0}/{1}] {2}（关卡 {3}）" -f $i, $list.Count, $c.n, $c.lv)
    Write-Host ("=" * 60)
    if ($c.lv -eq -8) {
        # 特殊项：文档**内部**一致性（计数常量 ↔ 文档里的"N 条"、项数 ↔ 实际项数）。
        # 与 readme 项的分工：readme 管"文档 ↔ 项目"（路径/检查项名/项数/关卡数），
        # 这一项管"文档 ↔ 文档与常量"（逐项清单的条数），纯文本比对、不启动 Godot。
        $out = & pwsh -File (Join-Path $Here 'check-docs.ps1') 2>&1 | Out-String
    } elseif ($c.lv -eq -9) {
        # 特殊项：只校验文档与项目是否一致，不启动 Godot
        $out = & pwsh -File (Join-Path $Here 'check-readme.ps1') 2>&1 | Out-String
    } else {
        $args = @('-Check', $c.n, '-MaxTries', '4')
        if ($c.lv -ge 0) { $args += @('-Level', "$($c.lv)") }
        $out = & pwsh -File (Join-Path $Here 'run-check.ps1') @args 2>&1 | Out-String
    }
    $passed = $out -match [regex]::Escape($c.ok)
    # 解析失败的日志一律算失败（那种情况下 [自检] 输出具有欺骗性）
    if ($out -match '解析/编译失败') { $passed = $false }
    $results += [pscustomobject]@{ 检查 = $c.n; 关卡 = $c.lv; 结果 = if ($passed) { '通过' } else { '失败' } }
    Write-Host ("--> {0}" -f $(if ($passed) { '通过 ✔' } else { '失败 ✘' }))
}

Write-Host ""
Write-Host ("=" * 60)
Write-Host " 汇总"
Write-Host ("=" * 60)
$results | Format-Table -AutoSize | Out-String | Write-Host
$fail = @($results | Where-Object { $_.结果 -eq '失败' })
if ($fail.Count -eq 0) {
    Write-Host ("全部 {0} 项通过 ✔" -f $results.Count) -ForegroundColor Green
    exit 0
}
Write-Host ("有 {0} 项失败：{1}" -f $fail.Count, (($fail | ForEach-Object { $_.检查 }) -join ', ')) -ForegroundColor Red
Write-Host "（每项的完整日志在 godot-logs\check-<名称>.log）"
exit 1
