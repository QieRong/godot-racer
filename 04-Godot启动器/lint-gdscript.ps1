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
} else {
    Write-Host "lint-gdscript: 发现 $($problems.Count) 处问题 —— 这些会让脚本整个解析失败！"
    foreach ($p in $problems) {
        Write-Host ("  {0}:{1}  [{2}]" -f (Split-Path -Leaf $p.File), $p.Line, $p.Kind)
        Write-Host ("      {0}" -f $p.Text)
    }
    Write-Host ""
    Write-Host "修法：把中文串里的 ASCII 直引号换成「」（或去掉引号）。"
    exit 1
}

# ---------------------------------------------------------------------------
# 第三类检查：**一行里塞了两条语句**（"把两行粘成一行"）
#
# 为什么要有这一条（2026-09 实际事故，白耗半小时）：
#   AI 做"删掉一行"的编辑时误把换行一起吃掉了，于是
#       var resc := int(ai.call("rescue_count")) if ai.has_method("rescue_count") else -1	print("[自检] AI 诊断结果：")
#   `main.gd` **整个解析失败** → 赛道不生成、车自由落体（353 km/h、小地图全黑）。
#   这正是上面第一类检查开头描述的那个症状，但**原因不同**（不是引号，是换行）。
#
# 为什么必须机器查：Godot 报的是 `Expected end of statement after variable declaration,
# found "Identifier"`，**不给行号**（聚合 preload 只报 Could not preload main.gd）；
#   而人眼 review 一整屏 diff 时，一行末尾多粘一段几乎看不见。
#
# 判据（刻意保守，只抓"几乎必然是两条语句"的形态，避免误报）：
#   A. 一行里出现"标点/字母 后面直接跟 TAB"—— GDScript 的缩进只在**行首**，
#      行中间出现 TAB 一定是两段被粘在一起（合法代码里行中不会有 TAB）。
#   B. 一行里出现两次 `var ` 声明，或 `var ... := ...` 之后**又**出现 `print(`/`return`/
#      `if` 这类语句起始关键字。
#   只在**字符串外**判断（引号/注释内的内容不算）。
#
# 用法与上面一致（默认扫整个 godot-racer 工程）。
$glued = @()
function Test-CodeGlue([string]$line) {
    # ⚠ 必须先跳过**行首**缩进：缩进里的 TAB 完全合法，只有"行中间"的 TAB 才是粘行。
    #   第一版没跳，结果每个正常缩进的行都被报成粘行（几十条假红）—— 判据设计错误。
    $body = $line.TrimStart([char]9, [char]32)
    if ($body.Length -eq 0) { return $null }
    $tab = $body.IndexOf([char]9)
    if ($tab -lt 0) { return $null }
    # ⚠ 但"TAB 对齐注释"是合法写法（`hud.gd:129` 就是），不能报。
    #   判据：取**第一个 TAB 之后**的正文，它若是注释（或以注释开头）→ 无害。
    #   （真·粘行的 TAB 后面跟的一定是语句，不是 `#`。）
    $afterTab = $body.Substring($tab + 1).TrimStart([char]9, [char]32)
    if ($afterTab.StartsWith('#')) { return $null }
    # 再排除一种：TAB 之前已经有 `#`（说明 TAB 落在注释正文里）
    if ($body.Substring(0, $tab).Contains('#')) { return $null }
    return "行中间出现 TAB（缩进只应在行首，这里多半是两行被粘成一行）"
}
function Test-StatementGlue([string]$line) {
    # 把字符串与注释剥掉，只在"代码骨架"上数语句起始关键字
    $code = ""
    $inStr = $false
    for ($i = 0; $i -lt $line.Length; $i++) {
        $ch = $line[$i]
        if ($inStr) {
            if ($ch -eq '\') { $i++; continue }
            if ($ch -eq '"') { $inStr = $false }
            continue
        }
        if ($ch -eq '#') { break }
        if ($ch -eq '"') { $inStr = $true; continue }
        $code += $ch
    }
    $code = $code.TrimStart([char]9, [char]32)
    $varCount = ([regex]::Matches($code, '(^|\s)var\s')).Count
    if ($varCount -ge 2) { return "一行里出现 $varCount 个 var 声明（两行被粘成一行）" }
    # ⚠ 关键词表里**故意没有 `if`**：GDScript 的行内三元 `var x := 1.0 if c else 0.0`
    #   是合法且常用的写法，把它算进来会一口气报出十几条假红（第一版就是这么误报的）。
    #   而被粘住的 `if` 语句一定同时命中"行中 TAB"或"var 计数 ≥2"，不会漏。
    if ($varCount -ge 1 -and $code -match '\S\s{1,}(print|printerr|return|for|while|func|push_error|push_warning)\s*[\(\s]') {
        return "一行里 var 声明之后又跟了语句（两行被粘成一行）"
    }
    return $null
}
foreach ($f in $files) {
    $lines = Get-Content $f.FullName
    for ($li = 0; $li -lt $lines.Count; $li++) {
        $line = $lines[$li]
        if ($line.Trim().Length -eq 0) { continue }
        $why = Test-CodeGlue $line
        if (-not $why) { $why = Test-StatementGlue $line }
        if ($why) {
            $glued += [pscustomobject]@{
                File = $f.FullName; Line = $li + 1; Kind = $why; Text = $line.Trim()
            }
        }
    }
}
if ($glued.Count -gt 0) {
    Write-Host ""
    Write-Host "lint-gdscript: 发现 $($glued.Count) 处「两条语句挤在一行」—— 会让脚本整个解析失败！"
    foreach ($g in $glued) {
        Write-Host ("  {0}:{1}  [{2}]" -f (Split-Path -Leaf $g.File), $g.Line, $g.Kind)
        Write-Host ("      {0}" -f $g.Text)
    }
    Write-Host ""
    Write-Host "修法：把被粘住的两条语句拆成两行（编辑器里回车一下即可），然后重跑本脚本。"
    exit 1
}
Write-Host "lint-gdscript: 未发现「两行粘成一行」✔"

# ---------------------------------------------------------------------------
# 第二类检查：.bat 的行尾必须是 CRLF
#
# 为什么放在这里查：.gitattributes 里的 `*.bat text eol=crlf` **只管检出时**的换行，
# 用工具/脚本直接写文件时不会帮你转。cmd 按 CRLF 切行，只有 LF 会把多行黏成
# 一条命令 —— 双击就是"窗口一闪而过"（报 'xxx' 不是内部或外部命令）。
# 这个坑踩过两次：第一次手写 bat；第二次我用 PowerShell 生成启动器时又踩了。
# 所以改成机器检查，和引号问题一起挡在启动之前。
$batDir = $PSScriptRoot
$crlfBad = @()
foreach ($bat in Get-ChildItem -Path $batDir -Filter *.bat -File -ErrorAction SilentlyContinue) {
    $b = [System.IO.File]::ReadAllBytes($bat.FullName)
    $bareLf = 0
    for ($i = 0; $i -lt $b.Length; $i++) {
        if ($b[$i] -eq 10 -and ($i -eq 0 -or $b[$i - 1] -ne 13)) { $bareLf++ }
    }
    if ($bareLf -gt 0) { $crlfBad += [pscustomobject]@{ Name = $bat.Name; BareLf = $bareLf } }
}
if ($crlfBad.Count -gt 0) {
    Write-Host ""
    Write-Host "lint-gdscript: 发现 $($crlfBad.Count) 个 .bat 用了裸 LF 换行 —— 双击会一闪而过！"
    foreach ($c in $crlfBad) { Write-Host ("  {0}：裸 LF {1} 处" -f $c.Name, $c.BareLf) }
    Write-Host ""
    Write-Host "修法（把行尾全换成 CRLF，注意别把已有 CRLF 变成 CRCRLF）："
    Write-Host '  Get-ChildItem *.bat | ForEach-Object { $t = [IO.File]::ReadAllText($_.FullName)'
    Write-Host '    $t = $t.Replace("`r`n","`n").Replace("`n","`r`n")'
    Write-Host '    [IO.File]::WriteAllText($_.FullName, $t, [Text.Encoding]::ASCII) }'
    exit 1
}

Write-Host "lint-gdscript: .bat 行尾全部是 CRLF ✔"
exit 0
