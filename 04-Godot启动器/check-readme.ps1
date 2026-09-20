# README 一致性检查：让文档跟着项目走，而不是靠人记得改。
#
# 为什么需要它：
#   README 过时是渐进的、无声的 —— 加了新脚本、加了新检查项，文档没人改，
#   过一阵就出现"文档写着的文件早没了""新功能一个字没提"。
#   人眼 review 靠不住（我这轮就只改了"看到的那几处"），所以改成机器校验：
#   文档里提到的**必须存在**，项目里实现的**必须被写上**。两边对不上就报错。
#
# 检查三类：
#   ① 路径：README 里以 `scripts/x.gd`、`scenes/y.tscn` 等出现的路径必须真实存在
#   ② 检查项：README 提到的 --check=<name> 必须在 main.gd 里真的实现了
#   ③ 反向：main.gd 里实现的每个检查项，README 必须提到（防止新功能不写文档）
#
# 用法：pwsh -File .\check-readme.ps1
param(
    [string]$Readme = "",
    [string]$Project = ""
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
if ($Readme -eq "")  { $Readme = Join-Path $Root "README.md" }
if ($Project -eq "") { $Project = Join-Path $Root "godot-racer" }

if (-not (Test-Path $Readme)) { Write-Host "找不到 README：$Readme"; exit 2 }

# 扫描范围 = README + docs/ 下的全部 .md。
# 为什么要把 docs/ 算进来：README 刻意保持简短（别人 clone 下来先看"这是什么、怎么跑"），
# 详细内容（检查项表、工程笔记）都在 docs/ 里。若只扫 README，
# 就会报"README 没提某个检查项"的假警 —— 它其实写在 docs/testing.md 里。
$sources = @($Readme)
$docsDir = Join-Path $Project "docs"
if (Test-Path $docsDir) {
    $sources += (Get-ChildItem $docsDir -Filter *.md -File | Select-Object -ExpandProperty FullName)
}
$md = ($sources | ForEach-Object { Get-Content $_ -Raw }) -join "`n"
Write-Host ("check-readme: 扫描 {0} 个文档（README + docs/）" -f $sources.Count)
$problems = @()

# ---------- ① 路径 ----------
# 只校验"看起来是项目内相对路径"的引用：带 scripts/ scenes/ tools/ assets/ data/ docs/
# 前缀，或带扩展名且不是我们已知的外部/资产目录文件。
$pathPattern = '`((?:scripts|scenes|tools|assets|data|docs|models)/[^`]+?\.(?:gd|tscn|tres|json|py|png|glb|md))`'
foreach ($m in [regex]::Matches($md, $pathPattern)) {
    $rel = $m.Groups[1].Value
    $full = Join-Path $Project ($rel -replace '/', '\')
    if (-not (Test-Path $full)) {
        # 顺带容忍"从工程根写"与"从仓库根写"两种写法
        $alt = Join-Path $Root ($rel -replace '/', '\')
        if (-not (Test-Path $alt)) {
            $problems += "README 引用了不存在的路径：$rel"
        }
    }
}

# ---------- ② 检查项：README 提到的是否实现 ----------
$mainPath = Join-Path $Project "scenes\main.gd"
if (-not (Test-Path $mainPath)) {
    $problems += "找不到 main.gd，无法校验检查项：$mainPath"
} else {
    $main = Get-Content $mainPath -Raw
    # main.gd 的 _check_tick 用 `match _check:` 分发检查项。
    # ⚠ 必须**限定在这个 match 块内**解析：直接全文搜 `"名字":` 会把
    # _apply_environment 里的 `match cfg.weather_type:` 分支
    # （"rain": / "snow": / "sand":）也当成检查项 —— 实测就是这么误报的。
    $impl = @()
    $tickIdx = $main.IndexOf('match _check:')
    if ($tickIdx -lt 0) {
        $problems += "在 main.gd 里找不到 match _check: 分发块（结构变了？）"
    } else {
        $rest = $main.Substring($tickIdx)
        $nextFunc = [regex]::Match($rest, '(?m)^func ')
        $block = if ($nextFunc.Success) { $rest.Substring(0, $nextFunc.Index) } else { $rest }
        $impl = [regex]::Matches($block, '(?m)^\s+"([a-z][a-z0-9_]*)":') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        if ($impl.Count -eq 0) { $problems += "没能从 match _check: 块里解析出检查项（分发格式变了？）" }
    }

    # 反向：实现的每个检查项，README 都必须提到
    foreach ($name in $impl) {
        if ($md -notmatch ('`' + [regex]::Escape($name) + '`')) {
            $problems += "实现了检查项 --check=$name，但 README 里一个字都没提（新功能忘写文档）"
        }
    }
    Write-Host ("check-readme: main.gd 实际实现 {0} 个检查项：{1}" -f $impl.Count, ($impl -join ' '))
}

# ---------- ③ 数字一致性：README 说的检查项数量 ----------
if (Test-Path (Join-Path $PSScriptRoot "run-all-checks.ps1")) {
    $runner = Get-Content (Join-Path $PSScriptRoot "run-all-checks.ps1") -Raw
    $runnerCount = ([regex]::Matches($runner, "@\{ n='")).Count
    # 文档里形如"全部 14 项"、"跑全部验收（14 项 …）"、"14 项全绿"
    foreach ($m in [regex]::Matches($md, '(\d+)\s*项全绿|全部\s*(\d+)\s*项|跑全部验收（(\d+) 项')) {
        $claimed = 0
        for ($g = 1; $g -le 3; $g++) { if ($m.Groups[$g].Success) { $claimed = [int]$m.Groups[$g].Value; break } }
        if ($claimed -gt 0 -and $claimed -ne $runnerCount) {
            $problems += "文档说 $claimed 项，但 run-all-checks.ps1 实际有 $runnerCount 项"
        }
        break
    }
}

# ---------- ④ 关卡数量 ----------
$levelDir = Join-Path $Project "data\levels"
if (Test-Path $levelDir) {
    $realLevels = (Get-ChildItem $levelDir -Filter *.tres -File).Count
    foreach ($m in [regex]::Matches($md, '(\d+)\s*个关卡')) {
        $claimed = [int]$m.Groups[1].Value
        if ($claimed -ne $realLevels) {
            $problems += "README 说 $claimed 个关卡，但 data/levels/ 里实际有 $realLevels 个"
        }
        break
    }
}

# ---------- 结论 ----------
if ($problems.Count -eq 0) {
    Write-Host "check-readme: README 与项目一致 ✔"
    exit 0
}
Write-Host "check-readme: 发现 $($problems.Count) 处文档与项目不一致："
foreach ($p in $problems) { Write-Host "  ✘ $p" }
Write-Host ""
Write-Host "请更新 README.md（它不是"一次写完就不用管"的文档）。"
exit 1
