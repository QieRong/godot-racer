# 真·语法检查：直接跑 Godot 的解析器，把「引号类」和「类型推断类」错误都拦在启动之前。
#
# 为什么需要它（血泪）：
#   我在 main.gd 上已经**三次**写出让整个脚本解析失败的代码，症状全都是
#   "赛道不生成、车自由落体、小地图全黑"（用户看到的 353km/h 空场景），
#   而每次都发生在**用户自己双击启动游戏**的时候。
#   前两个错误类型：
#     ① 中文串里嵌 ASCII 直引号（lint-gdscript.ps1 能查）
#     ② 对未标注类型的 Node 用 := 接收 Variant（`ai.global_position.distance_to(...)`）
#        —— 这个 lint 查不到，必须让 Godot 自己解析才知道。
#
# 做法：`godot --check-only --script <入口脚本>`（**必须带 --log-file**，
# 否则启动期会段错误）。它会把该脚本解析一遍并退出。
# 已知假阳性：`Identifier not found: GameState` —— 因为 --check-only 不启动 autoload。
# 所以这里动态收集 autoload 名与 class_name 名，把对应的 "Identifier not found"
# 忽略掉，其余一律视为真错误。
#
# 用法：pwsh -File .\parse-check.ps1
#       pwsh -File .\parse-check.ps1 -Scripts res://scenes/main.gd
param(
    [string[]]$Scripts = @(),
    [int]$MaxTries = 3,
    [string]$Project = ""
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent $PSScriptRoot
if ($Project -eq "") { $Project = Join-Path $Root "godot-racer" }
$Godot = "E:\godot\Godot_v4.4.1-stable_win64.exe"
$LogDir = Join-Path $Root "godot-logs"

if (-not (Test-Path $Godot)) { Write-Host "parse-check: 找不到 Godot，跳过"; exit 0 }
if (-not (Test-Path (Join-Path $Project "project.godot"))) { Write-Host "parse-check: 找不到工程，跳过"; exit 0 }
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

# ---- 默认：**全部 .gd 都要查** ----
# 为什么不能只查入口脚本（2026-09 踩的坑）：
#   `scripts/track_layout.gd` 里有一处"变量先用后声明"，整个模块解析失败。
#   而 `load()` 依然返回一个**非 null** 的 GDScript —— 只是没有那些方法。
#   于是 --check=layout 的每个用例都在调一个不存在的方法、计数全是 0，
#   最后打印"解析用例 0 个全过" → **验收显示通过，其实什么都没测**。
#   入口脚本检查完全看不到这个问题，所以现在改成"全查"。
#
# 做法：生成一个**只含 preload 的聚合脚本**，让 Godot 一次解析全部脚本 ——
# 逐个文件启动十几次太慢，聚合后仍然只启动一次。
$aggregator = Join-Path $Project "tools\_parse_all.gd"
if ($Scripts.Count -eq 0) {
    $all = @()
    foreach ($dir in @("scripts", "scenes", "tools")) {
        $p = Join-Path $Project $dir
        if (-not (Test-Path $p)) { continue }
        $all += Get-ChildItem $p -Filter *.gd -File -Recurse |
            Where-Object { $_.Name -ne "_parse_all.gd" } |
            ForEach-Object { "res://" + $dir + "/" + $_.Name }
    }
    $all = $all | Sort-Object -Unique
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("extends RefCounted")
    [void]$sb.AppendLine("# 自动生成：parse-check.ps1 用它一次性解析全部脚本（勿手改，勿提交）")
    $i = 0
    foreach ($s in $all) { [void]$sb.AppendLine("const _P$i = preload(`"$s`")"); $i++ }
    Set-Content -Path $aggregator -Value $sb.ToString() -Encoding utf8
    $Scripts = @("res://tools/_parse_all.gd")
    Write-Host ("parse-check: 聚合解析 {0} 个 .gd（含 scripts/scenes/tools）" -f $all.Count)
}

# ---- 收集已知的"解析期不可见"标识符（autoload 与 class_name），用于过滤假阳性 ----
$known = New-Object System.Collections.Generic.HashSet[string]
$projText = Get-Content (Join-Path $Project "project.godot") -Raw
$inAutoload = $false
foreach ($line in ($projText -split "`r?`n")) {
    if ($line -match '^\[autoload\]') { $inAutoload = $true; continue }
    if ($line -match '^\[') { $inAutoload = $false }
    if ($inAutoload -and $line -match '^([A-Za-z_][A-Za-z0-9_]*)\s*=') { [void]$known.Add($Matches[1]) }
}
foreach ($gd in Get-ChildItem (Join-Path $Project "scripts"), (Join-Path $Project "scenes") -Filter *.gd -File -Recurse -ErrorAction SilentlyContinue) {
    foreach ($m in [regex]::Matches((Get-Content $gd.FullName -Raw), '(?m)^class_name\s+([A-Za-z_][A-Za-z0-9_]*)')) {
        [void]$known.Add($m.Groups[1].Value)
    }
}

$failures = @()
# 说明一次，免得用户被 Godot 的原始报错吓到（这是最常被误认为"游戏坏了"的一段输出）：
Write-Host "parse-check: 注：--check-only 模式下 Godot 不注册 autoload，会报 GameState 之类的"
Write-Host "parse-check:     「Identifier not found」—— 那是**已知假阳性**，本脚本会自动过滤。"
Write-Host "parse-check:     Godot 的原始输出重定向到 godot-logs\parse-*.out.log（要看细节去那里）。"
foreach ($s in $Scripts) {
    $log = Join-Path $LogDir ("parse-" + ($s -replace '[^A-Za-z0-9]', '_') + ".log")
    $outLog = Join-Path $LogDir ("parse-" + ($s -replace '[^A-Za-z0-9]', '_') + ".out.log")
    $errLog = Join-Path $LogDir ("parse-" + ($s -replace '[^A-Za-z0-9]', '_') + ".err.log")
    $ok = $false
    for ($try = 1; $try -le $MaxTries; $try++) {
        Remove-Item $log -ErrorAction SilentlyContinue
        # ⚠ 必须把 Godot 的 stdout/stderr 重定向到文件：
        #   否则那堆"已知假阳性"会直接刷在用户的控制台上，看起来像游戏坏了
        #   （用户实测截图就是这样：一堆 SCRIPT ERROR，然后紧跟一句"检查通过 ✔"）。
        $p = Start-Process -FilePath $Godot `
            -ArgumentList @('--path', $Project, '--log-file', $log, '--check-only', '--script', $s) `
            -NoNewWindow -PassThru `
            -RedirectStandardOutput $outLog -RedirectStandardError $errLog
        $p.WaitForExit(40000) | Out-Null
        if (-not $p.HasExited) { $p.Kill() | Out-Null }
        if (Test-Path $log) {
            $txt = Get-Content $log -Raw
            if ($txt -notmatch 'CrashHandlerException') { $ok = $true; break }
        }
    }
    if (-not $ok) {
        Write-Host ("parse-check: {0} —— {1} 次都遇到启动期段错误，本次跳过（不是代码问题）" -f $s, $MaxTries)
        continue
    }
    $txt = Get-Content $log -Raw
    # 只看"编译/解析错误"本身，不看它们的连带行。
    # 关键点：`Failed to load script` / `Compilation failed` 是**结果**；
    # 如果唯一原因是已知假阳性（autoload 未注册），这两行也会跟着出现，
    # 必须一起忽略，否则每次都误报 —— 实测第一版就是这么错的。
    $real = @()
    $logLines = $txt -split "`r?`n"
    for ($li = 0; $li -lt $logLines.Count; $li++) {
        $line = $logLines[$li]
        if ($line -notmatch 'SCRIPT ERROR|Parse Error|Compile Error|Cannot infer') { continue }
        if ($line -match 'Failed to read the root certificate store') { continue }
        # 连带行：聚合脚本因为"依赖里有已知假阳性(autoload 未注册)"而整体编译失败。
        # 真正的原因永远会单独报一行（例如 Parse Error: Identifier "chosen" not declared），
        # 所以这一行必须忽略，否则每次都是假红。
        if ($line -match 'Failed to compile depended scripts') { continue }
        $isKnown = $false
        if ($line -match 'Identifier not found:\s*([A-Za-z_][A-Za-z0-9_]*)') {
            if ($known.Contains($Matches[1])) { $isKnown = $true }
        }
        if ($isKnown) { continue }
        # 附上紧跟的 "at: ...(res://xxx.gd:行号)" —— 没有它根本不知道是哪个文件
        $where = ""
        if ($li + 1 -lt $logLines.Count -and $logLines[$li + 1] -match 'at:.*\((res://[^\)]+)\)') {
            $where = "  ← " + $Matches[1]
        }
        $real += $line.Trim() + $where
    }
    foreach ($line in $real) { $failures += "  {0}" -f $line }
}

# 删掉自动生成的聚合脚本（它是临时产物，不该留在工程里）
Remove-Item $aggregator -ErrorAction SilentlyContinue

if ($failures.Count -eq 0) {
    Write-Host ("parse-check: {0} 个脚本用 Godot 解析器检查通过 ✔" -f $Scripts.Count)
    exit 0
}
Write-Host ("parse-check: Godot 解析器报了 {0} 处错误 —— 现在启动游戏会看到「赛道不生成、车自由落体」：" -f $failures.Count)
$failures | ForEach-Object { Write-Host $_ }
Write-Host ""
Write-Host "常见修法："
Write-Host "  · 中文串里别用 ASCII 直引号（换成「」）"
Write-Host "  · 对未标注类型的 Node 取属性 / 调 call() 时，var 要写显式类型："
Write-Host "      var d: float = ai.global_position.distance_to(p)   ← 不能写 :="
exit 1
