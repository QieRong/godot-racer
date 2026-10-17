# 按顺序跑完全部验收检查，最后汇总成一张表。
#
# 为什么要这个：验收项已经有十余项（还在长），一项一项手敲命令既慢又容易漏。
# 这个脚本保证"每次提交前跑的是同一套"，并把结果汇总到一眼能看的地方。
#
# 用法：
#   pwsh -File .\run-all-checks.ps1              # 全部
#   pwsh -File .\run-all-checks.ps1 -Quick       # 只跑快的（跳过 lap/stress/opponents）
#   pwsh -File .\run-all-checks.ps1 -Only avoid,pause
#   pwsh -File .\run-all-checks.ps1 -Quick -RenderFps 120   # 全部用 120 FPS 跑一遍
param(
    [switch]$Quick,
    [string[]]$Only = @(),
    # REL-STEP2A：把**渲染**帧率透传给每一项（60 / 120）。0 = 不加这个参数，
    # 沿用玩家存档 / 工程默认 60。物理始终 120 Hz，不受它影响。
    # ⚠ 它走的是 GameState 的"命令行覆盖"路径 —— **不会**改写玩家自己的存档值。
    [int]$RenderFps = 0
)

if ($RenderFps -ne 0 -and $RenderFps -ne 60 -and $RenderFps -ne 120) {
    Write-Host ("-RenderFps 只接受 60 / 120（收到 {0}）" -f $RenderFps) -ForegroundColor Red
    exit 2
}

$ErrorActionPreference = "Continue"

# ⚠ 强制 UTF-8 控制台 —— 本机陷阱：默认 [Console]::OutputEncoding = gb2312(CP936)。
# 为什么必须在最顶部：本脚本靠 `$out -match $c.ok` 比对子进程 stdout，
# 而各项的通过标志里带 `✔`(U+2714)。gb2312 无法表示 `✔`，子进程 stdout 会把它降级成 `?`
# （实测：不设 UTF-8 时 15/15 **全线假红**，逐项打印成 `--> 失败 ?`，见 godot-logs/red-quick-gb2312.txt）。
# 这两行在脚本一开始就生效，保证本进程与它派生的每个 pwsh 子进程都用 UTF-8 收发。
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Here = $PSScriptRoot
$Root = Split-Path -Parent $Here

function Get-GitEvidence {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return [pscustomobject]@{ Head = '不可用（未找到 git）'; Worktree = '未知' }
    }
    $headLines = @(& $git.Source -C $Root rev-parse --verify HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or $headLines.Count -eq 0) {
        return [pscustomobject]@{ Head = '不可用（非 Git 工作区）'; Worktree = '未知' }
    }
    $head = [string]$headLines[0]
    $dirtyLines = @(& $git.Source -C $Root status --porcelain 2>$null)
    $worktree = if ($LASTEXITCODE -ne 0) {
        '未知（无法读取 Git 状态）'
    } elseif ($dirtyLines.Count -eq 0) {
        '干净'
    } else {
        # ⚠ PowerShell 的 -f 只认 `{0}` 这种 .NET 复合格式占位符，**不认** C 风格的 `%d`。
        # 写成 `'...（%d 个路径）' -f $n` 不会替换、也不会报错，直接把字面 "%d" 打出来（静默显示 bug）。
        ('有未提交修改（{0} 个路径）' -f $dirtyLines.Count)
    }
    return [pscustomobject]@{ Head = $head; Worktree = $worktree }
}

$gitEvidence = Get-GitEvidence
Write-Host ("Git HEAD: {0}" -f $gitEvidence.Head)
Write-Host ("Git 工作区：{0}" -f $gitEvidence.Worktree)

# 每项：名称 / 关卡（-1 = 用默认 / -9 = 不启动 Godot 的特殊项）/ 通过标志 / 是否耗时
$all = @(
    @{ n='docs';      lv=-8; ok='文档与实现一致 ✔';                   slow=$false },
    @{ n='readme';    lv=-9; ok='README 与项目一致 ✔';               slow=$false },
    @{ n='enclosure'; lv=-1; ok='围墙封闭 ✔';                        slow=$false },
    @{ n='wallslide'; lv=-1; ok='卡墙验收：12/12 通过 ✔';             slow=$false },
    @{ n='minimap';   lv=3;  ok='障碍物标记：障碍';                   slow=$false },
    @{ n='obstacles'; lv=4;  ok='障碍物验收 ✔';                       slow=$false },
    @{ n='aistart';   lv=4;  ok='并排发车验收 ✔';                     slow=$false },
    @{ n='aidiag';    lv=-1; ok='AI 诊断 ✔';                          slow=$true  },
    @{ n='avoid';     lv=4;  ok='避让验收 ✔';                         slow=$false },
    @{ n='pause';     lv=2;  ok='暂停验收 ✔';                         slow=$false },
    @{ n='flip';      lv=-1; ok='翻车恢复验收 ✔';                     slow=$false },
    @{ n='layout';    lv=-1; ok='赛道布局验收 ✔';                     slow=$false },
    @{ n='reverse';   lv=-1; ok='reverse 验收 ✔';                     slow=$false },
    @{ n='weather';   lv=4;  ok='天气验收 ✔';                         slow=$false },
    @{ n='friction';  lv=4;  ok='抓地力验收 ✔';                       slow=$false },
    @{ n='phys';      lv=4;  ok='物理开销 ✔';                         slow=$false },
    @{ n='stress';    lv=-1; ok='压测验收 ✔';                         slow=$true  },
    # GATE-L4-001（用户签字）：两关分别保留日志；已知缺陷仍按原判据报红。
    @{ n='opponents'; lv=3;  ok='对手验收 ✔';                         slow=$true; log='check-opponents-L4' },
    @{ n='opponents'; lv=4;  ok='对手验收 ✔';                         slow=$true; log='check-opponents-L5' },
    @{ n='lap';       lv=-1; ok='跑圈验收 ✔';                         slow=$true  }
)

$list = $all
if ($Only.Count -gt 0) {
    # PowerShell 的 -Only docs,readme 在某些调用方式下会作为一个字符串传入。
    # 先拆分再匹配，避免空列表最终被误报为「全部 0 项通过」。
    $Only = @($Only | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $unknown = @($Only | Where-Object { $name = $_; -not @($all | Where-Object { $_.n -eq $name }).Count })
    if ($unknown.Count -gt 0) {
        Write-Host ("未知检查项：{0}" -f ($unknown -join ', ')) -ForegroundColor Red
        exit 2
    }
    $list = $all | Where-Object { $Only -contains $_.n }
} elseif ($Quick) {
    $list = $all | Where-Object { -not $_.slow }
}

$results = @()
if (@($list).Count -eq 0) {
    Write-Host '没有选中任何检查项' -ForegroundColor Red
    exit 2
}
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
        if ($c.log) { $args += @('-LogName', $c.log) }
        if ($RenderFps -gt 0) { $args += @('-RenderFps', "$RenderFps") }
        $out = & pwsh -File (Join-Path $Here 'run-check.ps1') @args 2>&1 | Out-String
    }
    $childExit = $LASTEXITCODE
    $passed = $childExit -eq 0 -and $out -match [regex]::Escape($c.ok)
    # 解析失败的日志一律算失败（那种情况下 [自检] 输出具有欺骗性）
    if ($out -match '解析/编译失败') { $passed = $false }
    $results += [pscustomobject]@{
        检查 = $c.n
        关卡 = $c.lv
        日志 = if ($c.log) { "godot-logs/$($c.log).log" } elseif ($c.lv -ge -1) { "godot-logs/check-$($c.n).log" } else { '控制台输出' }
        结果 = if ($passed) { '通过' } else { '失败' }
        GitHEAD = $gitEvidence.Head
        工作区 = $gitEvidence.Worktree
    }
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
Write-Host ("有 {0} 项失败：{1}" -f $fail.Count, (($fail | ForEach-Object {
    if ($_.关卡 -ge 0) { '{0} (L{1})' -f $_.检查, ($_.关卡 + 1) } else { $_.检查 }
}) -join ', ')) -ForegroundColor Red
Write-Host "（完整日志见汇总表；opponents 分别保存为 check-opponents-L4.log / check-opponents-L5.log）"
exit 1
