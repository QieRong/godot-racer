# 文档同步检查：把"文档与项目是否一致"变成机器可查的事。
#
# 为什么在 check-readme 之外还要这一个：
#   `check-readme.ps1` 管的是 **README/docs 与项目之间**的对照（路径、检查项名、项数、关卡数）。
#   它管不到**文档自己内部**的两类漂移 —— 而这两类恰恰是最难靠人眼发现的：
#     ① **块数**：文档里"严格递增 / 首尾同高 / 迟滞…"这类**逐项清单**，
#        和实现里的计数常量（`LAYOUT_ELEV_CASES`、`REVERSE_CASES`…）对不对得上。
#        实测：剖面用例从 7 条加到 10 条时文档没跟上；方向提示加了 1 条也没跟上。
#     ② **项数**：文档说"全部 N 项 / Quick N 项"，和 `run-all-checks.ps1` 实际项数
#        对不对得上。实测：往 Quick 集里加了 `reverse` 之后，
#        `docs/testing.md` 的"13 项"立刻变成错的 —— 没有任何检查会告诉我。
#   本脚本不启动 Godot，纯文本比对，几毫秒跑完。挂在 run-all-checks 里当第 0 项。
#
# 用法：pwsh -File .\check-docs.ps1
param(
    [string]$Project = ""
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
if ($Project -eq "") { $Project = Join-Path $Root "godot-racer" }

$problems = @()

# ---------------- 扫描范围：README + docs/*.md + AGENTS.md ----------------
$files = @()
$readme = Join-Path $Root "README.md"
if (Test-Path $readme) { $files += $readme }
$docsDir = Join-Path $Project "docs"
if (Test-Path $docsDir) {
    $files += (Get-ChildItem $docsDir -Filter *.md -File | Select-Object -ExpandProperty FullName)
}
$agents = Join-Path $Project "AGENTS.md"
if (Test-Path $agents) { $files += $agents }

if ($files.Count -eq 0) { Write-Host "check-docs: 找不到要扫描的文档"; exit 2 }
Write-Host ("check-docs: 扫描 {0} 个文档" -f $files.Count)

$texts = @{}
foreach ($f in $files) { $texts[$f] = Get-Content $f -Raw }

# ---------------- ① 计数常量 ↔ 文档里的"N 条" ----------------
# 机制：实现里的常量名要**以 `--check=<名>` 为锚点**在同一行/邻近出现才可靠地配对，
# 那太脆。所以这里反过来做：把"每个检查项自己的用例条数常量"显式登记在下面这张表里。
# 登记表本身写在脚本里（而不是靠猜），改常量时这里也必须改 —— 这正是想要的效果：
# 加/删用例时**有一个地方会提醒你**，而不是指望记得去翻文档。
$counters = @(
    @{ check='layout';  const='LAYOUT_ELEV_CASES';     expect=10; what='剖面用例' },
    @{ check='layout';  const='LAYOUT_RACING_CASES';   expect=6;  what='限速/刹车用例' },
    @{ check='reverse'; const='REVERSE_CASES';         expect=6;  what='方向提示用例' }
)

$mainPath = Join-Path $Project "scenes\main.gd"
if (-not (Test-Path $mainPath)) {
    $problems += "找不到 main.gd：$mainPath"
} else {
    $main = Get-Content $mainPath -Raw
    foreach ($c in $counters) {
        $m = [regex]::Match($main, ('const\s+' + [regex]::Escape($c.const) + '\s*:=\s*(\d+)'))
        if (-not $m.Success) {
            $problems += "main.gd 里找不到常量 $($c.const)（改名了？文档计数就再也对不上了）"
            continue
        }
        $actual = [int]$m.Groups[1].Value
        if ($actual -ne $c.expect) {
            $problems += "$($c.const) = $actual，但 check-docs.ps1 的登记表写的是 $($c.expect)（$($c.what)）—— 改了用例条数就要同步这里和文档"
        }
        # 文档里必须出现“$actual 条”这个说法（在提到该检查项的语境附近找）
        # ⚠ 必须先把整数拼进字符串**再**用正则：PowerShell 的 `+` 由**左操作数**决定语义，
        #   写 `$actual + '\s*条'` 会去做整数转换并抛 "input string was not in a correct format"。
        #   所以左边先放字面串，且整个拼接加括号保证类型是 string。
        $pat = ('\*\*?{0}\s*条|{0}\s*条' -f $actual)
        $found = $false
        foreach ($f in $files) {
            if ($texts[$f] -match $pat) { $found = $true; break }
        }
        if (-not $found) {
            $problems += "$($c.what)实际 $actual 条（$($c.const)），但没有任何文档写到「$actual 条」"
        }
    }
}

# ---------------- ② run-all-checks 项数 ↔ 文档里的"全部 N 项 / Quick N 项" ----------------
$runnerPath = Join-Path $PSScriptRoot "run-all-checks.ps1"
if (Test-Path $runnerPath) {
    $runner = Get-Content $runnerPath -Raw
    $total = ([regex]::Matches($runner, "@\{ n='")).Count
    $quick = ([regex]::Matches($runner, "slow=\`$false")).Count
    Write-Host ("check-docs: run-all-checks 共 {0} 项，其中 Quick {1} 项" -f $total, $quick)

    # “全部 N 项”
    foreach ($f in $files) {
        foreach ($m in [regex]::Matches($texts[$f], '全部\s*(\d+)\s*项')) {
            if ([int]$m.Groups[1].Value -ne $total) {
                $problems += "$([System.IO.Path]::GetFileName($f)) 说「全部 $($m.Groups[1].Value) 项」，实际 $total 项"
            }
        }
    }
    # “Quick N 项”
    foreach ($f in $files) {
        foreach ($m in [regex]::Matches($texts[$f], 'Quick\D{0,6}(\d+)\s*项')) {
            if ([int]$m.Groups[1].Value -ne $quick) {
                $problems += "$([System.IO.Path]::GetFileName($f)) 说「Quick $($m.Groups[1].Value) 项」，实际 $quick 项"
            }
        }
    }
}

# ---------------- ③ 检查项：Quick 集/分发口/文档 三方齐全 ----------------
# ⚠ 这里只管**已实现**的检查项（AGENTS.md 里还列着 elevation/elevation-ai/assets
#   三项是**阶段 2 待做**，故意先用它们占位）。所以要求是：
#   `match _check:` 里实现的每一项，都必须在文档里以 `名字` 出现过 —— 由
#   check-readme.ps1 负责；本脚本只补一条它没有的：**Quick 集里的项必须已实现**。
if (Test-Path $mainPath) {
    $tickIdx = $main.Substring($main.IndexOf('match _check:'))
    $nextFunc = [regex]::Match($tickIdx, '(?m)^func ')
    $block = if ($nextFunc.Success) { $tickIdx.Substring(0, $nextFunc.Index) } else { $tickIdx }
    $impl = [regex]::Matches($block, '(?m)^\s+"([a-z][a-z0-9_]*)":') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    if (Test-Path $runnerPath) {
        $names = [regex]::Matches($runner, "@\{ n='([a-z0-9_]+)'") |
                 ForEach-Object { $_.Groups[1].Value }
        foreach ($n in $names) {
            # 'docs' / 'readme' 是**脚本项**（不启动 Godot、也不在 main.gd 的 --check 分发里），
            # 所以不参与"必须已实现"的校验。
            if ($n -eq 'readme' -or $n -eq 'docs') { continue }
            if ($impl -notcontains $n) {
                $problems += "run-all-checks 里有 '$n'，但 main.gd 的 match _check: 没有这一项（会跑出一个未知检查的假结果）"
            }
        }
    }
}

# ---------------- 结论 ----------------
if ($problems.Count -eq 0) {
    Write-Host "check-docs: 文档与实现一致 ✔"
    exit 0
}
Write-Host ("check-docs: 发现 {0} 处文档与实现不一致：" -f $problems.Count)
foreach ($p in $problems) { Write-Host "  ✘ $p" }
Write-Host ""
Write-Host "请同步文档（docs/testing.md 的计数、跑全部 N 项、Quick N 项…）。"
exit 1
