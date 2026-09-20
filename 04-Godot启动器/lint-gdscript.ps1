# GDScript 中文字符串"直引号"检查器（preflight lint）。
#
# 为什么必须有这个东西：
#   这个坑我**踩了两次**，每次症状都一样且极具误导性 ——
#     print("...（见上方"检测到瞬移"行）")
#   字符串里嵌了 ASCII 直引号，字符串被提前截断，GDScript 报
#     Parse Error: Expected closing ")" after call arguments.
#   于是**整个 main.gd 加载失败**：level 配置不生效、赛道永不生成、
#   车自由落体（实测 353km/h、背景空、小地图全黑），**每个关卡都是这样**。
#   看上去像"游戏坏了"，实际是一行 print 的引号。
#
# 靠人眼 review 已经失败两次，所以改成机器检查，并且塞进 run-check.ps1 当闸门：
# 只要有一处，就直接不启动 Godot（省下 4 分钟才发现问题的成本）。
#
# 判据：逐字符扫描，维护"是否在字符串内"的状态。
#   - 在字符串外遇到 # → 后面是注释，停止扫描本行（注释里的引号无害）
#   - **闭合引号后面紧跟 CJK 字符** → 几乎必然是误把引号当字面量写进了中文串
#     （合法的闭合引号后面只可能是 ) , % + . ] 空格 等，绝不可能是汉字）
#   - 代码部分引号数为奇数 → 字符串没闭合
#
# 用法：
#   pwsh -File .\lint-gdscript.ps1                 # 扫默认工程
#   pwsh -File .\lint-gdscript.ps1 -Path <目录>
param(
    [string]$Path = ""
)

$ErrorActionPreference = "Continue"
$ProjDir = Split-Path -Parent $PSScriptRoot
if ($Path -eq "") { $Path = Join-Path $ProjDir "godot-racer" }
if (-not (Test-Path $Path)) { Write-Host "找不到目录: $Path"; exit 2 }

function Test-Cjk([char]$ch) {
    $c = [int]$ch
    # CJK 标点(3000-303F) + 假名(3040-30FF) + 汉字(4E00-9FFF) + 全角(FF00-FFEF)
    return (($c -ge 0x3000 -and $c -le 0x303F) -or
            ($c -ge 0x4E00 -and $c -le 0x9FFF) -or
            ($c -ge 0xFF00 -and $c -le 0xFFEF))
}

$problems = @()
$files = Get-ChildItem -Path $Path -Recurse -Filter *.gd -File
foreach ($f in $files) {
    $lines = Get-Content $f.FullName
    # 三引号多行字符串（"""..."""）要跨行跟踪，否则会把它的首尾行误报成"没闭合"。
    # 这个误报真的出现过：openrouter_client.gd 的用例生成提示词就是三引号串。
    $inTriple = $false
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $line = $lines[$li]
        if ($inTriple) {
            $close = $line.IndexOf('"""')
            if ($close -ge 0) { $inTriple = $false }
            continue
        }
        $inStr = $false
        $quotesInCode = 0
        for ($i = 0; $i -lt $line.Length; $i++) {
            $ch = $line[$i]
            if (-not $inStr) {
                if ($ch -eq '#') { break }          # 注释，本行后面不用看了
                if ($ch -eq '"') {
                    # 三引号多行串：进入后本行剩余部分不再按普通字符串分析
                    if ($i + 2 -lt $line.Length -and $line[$i + 1] -eq '"' -and $line[$i + 2] -eq '"') {
                        $rest = $line.Substring($i + 3)
                        if ($rest.Contains('"""')) { $i = $line.Length }   # 同行闭合
                        else { $inTriple = $true; $i = $line.Length }
                        break
                    }
                    $inStr = $true
                    $quotesInCode++
                }
            } else {
                if ($ch -eq '\') { $i++; continue }  # 转义，跳过下一个字符
                if ($ch -eq '"') {
                    $inStr = $false
                    $quotesInCode++
                    # 关键判据：闭合引号后面紧跟 CJK
                    if ($i + 1 -lt $line.Length -and (Test-Cjk $line[$i + 1])) {
                        $problems += [pscustomobject]@{
                            File = $f.FullName; Line = $li + 1
                            Kind = "闭合引号后紧跟中文（几乎必然是字符串里的直引号）"
                            Text = $line.Trim()
                        }
                    }
                }
            }
        }
        if ($inStr) {
            $problems += [pscustomobject]@{
                File = $f.FullName; Line = $li + 1
                Kind = "本行字符串没有闭合"
                Text = $line.Trim()
            }
        }
    }
}

if ($problems.Count -eq 0) {
    Write-Host "lint-gdscript: 扫描 $($files.Count) 个 .gd 文件，未发现直引号问题 ✔"
    exit 0
}

Write-Host "lint-gdscript: 发现 $($problems.Count) 处问题 —— 这些会让脚本整个解析失败！"
foreach ($p in $problems) {
    Write-Host ("  {0}:{1}  [{2}]" -f (Split-Path -Leaf $p.File), $p.Line, $p.Kind)
    Write-Host ("      {0}" -f $p.Text)
}
Write-Host ""
Write-Host "修法：把中文串里的 ASCII 直引号换成「」（或去掉引号）。"
exit 1
