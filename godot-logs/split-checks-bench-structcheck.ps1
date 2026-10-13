# SPLIT-CHECKS-BENCH-002 结构校验（TDD：先红后绿）。
#
# 为什么必须有它：本次是"纯迁移"，最大的风险不是逻辑改错，而是**迁移不完整** ——
# 漏搬一个常量/函数、调用点漏改、把不该搬的（ADR-001 三个永久居民 / match 分派表 /
# flip-reverse-escape-friction-layout 邻族）顺手扫进来、或者把注入写反（模块去
# get_node / 反向持有场景 / await 多一拍）。这些都不会让 parse 报错，只会在 A/B 里
# 表现为"行为没变但结构不对"。
# 所以把"迁完后的结构事实"写成可执行断言，动手前跑红、迁完跑绿。
#
# 与 split-checks-layout-structcheck.ps1 的差异（bench 族的四个特有决策）：
#   ① **残留检查同样跑在"去注释代码"上**（同 layout：代码零残留才是迁移完整性的
#      正确判据，注释里的历史引用不是漏搬）；
#   ② **永久居民断言扩到三个 CASES 常量 + match 分派表**：layout 批只钉了两个
#      LAYOUT_*_CASES，本批把 REVERSE_CASES 与分派表一起钉死（check-docs.ps1
#      L47-51 登记表三个全在 main.gd，check-readme.ps1 直接解析 match 块）；
#   ③ **await 政策是"恰 4 处、三种形态"，不是 0**：本族原本有真实 await
#      （2 处 get_tree().physics_frame → 注入 Callable；2 处族内 _run 调用留模块内）。
#      screenshot_mode 先例（恰 2 处）同款机器钉死，禁第三人加 await 改协程深度；
#   ④ **.uid 断言升级为"13 位 + 与现存 26 个无碰撞"**：layout 批只查格式，本批
#      把碰撞检查一起机器化（ Godot uid 撞车会静默解析到别人的脚本）。
#
# 用法：pwsh -File godot-logs\split-checks-bench-structcheck.ps1 [-OutName <日志名>]
# 退出码：0 = 全绿；1 = 有断言失败（红）。
param(
    [string]$Root = "",
    [string]$OutName = ""
)
$ErrorActionPreference = "Continue"
if ($Root -eq "") { $Root = Split-Path -Parent $PSScriptRoot }   # godot-logs 的父目录 = git 根
$Proj = Join-Path $Root "godot-racer"
$Main = Join-Path $Proj "scenes\main.gd"
$Mod = Join-Path $Proj "scripts\checks\bench.gd"
$ModUid = Join-Path $Proj "scripts\checks\bench.gd.uid"

$results = New-Object System.Collections.Generic.List[string]
function Add-R([string]$name, [bool]$ok, [string]$detail) {
    $tag = if ($ok) { "PASS" } else { "FAIL" }
    $results.Add(("[{0}] {1} -- {2}" -f $tag, $name, $detail))
}

# 去掉整行注释后再匹配，避免把文件头决策记录里点名的符号当成真实代码引用
# （先例：split-opponent-structcheck.ps1 / split-screenshot-structcheck.ps1 同款去噪）。
function Strip-Comments([string]$t) {
    $lines = @($t -split "`r?`n")
    $kept = @($lines | Where-Object { $_ -notmatch '^\s*#' })
    return ($kept -join "`n")
}

$mainRaw = if (Test-Path $Main) { Get-Content $Main -Raw } else { "" }
$modRaw = if (Test-Path $Mod) { Get-Content $Mod -Raw } else { "" }
$mainCode = Strip-Comments $mainRaw
$modCode = Strip-Comments $modRaw

$mainLines = 0
$mainFuncs = 0
if (Test-Path $Main) {
    $ml = Get-Content $Main
    $mainLines = $ml.Count
    $mainFuncs = ([regex]::Matches($mainRaw, '(?m)^func\s+')).Count
}

# ---------------------------------------------------------------- ① 新模块存在且形态正确
$exists = Test-Path $Mod
Add-R "scripts/checks/bench.gd 存在" $exists $(if ($exists) { "scripts/checks/bench.gd" } else { "文件不存在（尚未创建）" })

$extendsOk = $modRaw -match '(?m)^extends\s+RefCounted\s*$'
$classNameHits = ([regex]::Matches($modRaw, '(?m)^class_name\s+')).Count
Add-R "模块 extends RefCounted 且无 class_name（§2.4 铁律）" ($extendsOk -and $classNameHits -eq 0) (
    "extends RefCounted={0} class_name 定义数={1}（期望 True/0）" -f $extendsOk, $classNameHits)

# ---------------------------------------------------------------- ② main.gd 代码零残留
# 迁完后这些 token 在 main.gd 的**代码**里一次都不该出现（连注释都不留的判据不适用于
# 本族：模块声明块/breadcrumb 注释按设计留守，见文件头差异说明 ① —— 判据跑在去注释
# 代码上，注释不豁免也不误伤）。
# ⚠ `_check_steerbench` 不是 `_checks_bench`（新模块实例名）的子串，不会误命中；
#   `run_steerbench` 也不含 `_steerbench_run` 子串，同理安全。
$residTokens = @(
    # 8 个函数
    "_steerbench_sample", "_steerbench_aggregate", "_steerbench_run", "_check_steerbench",
    "_brakebench_sample", "_brakebench_aggregate", "_brakebench_run", "_check_brakebench",
    # 11 个随迁常量（闸门未登记、非 ADR-001 永久居民）
    "STEERBENCH_WINDOW_SEC", "STEERBENCH_REPEATS", "STEERBENCH_MIN_VALID_FRAMES", "STEERBENCH_CV_LIMIT",
    "BRAKEBENCH_REPEATS", "BRAKEBENCH_MAX_WINDOW_SEC", "BRAKEBENCH_MIN_VALID_FRAMES",
    "BRAKEBENCH_STEADY_LO", "BRAKEBENCH_STEADY_HI", "BRAKEBENCH_MIN_ABRAKE", "BRAKEBENCH_STOP_MPS"
)
$residTotal = 0
$residDetail = ""
foreach ($n in $residTokens) {
    $c = ([regex]::Matches($mainCode, [regex]::Escape($n))).Count
    if ($c -gt 0) { $residDetail += (" {0}={1}" -f $n, $c) }
    $residTotal += $c
}
Add-R "main.gd 代码零残留（8 函数 + 11 常量，共 19 个 token）" ($residTotal -eq 0) (
    "残留总数 = {0}{1}" -f $residTotal, $residDetail)

# ---------------------------------------------------------------- ③ main.gd 侧接线恰各一处
$constHits = ([regex]::Matches($mainRaw, '(?m)^const\s+ChecksBench\s+:=\s*preload\("res://scripts/checks/bench\.gd"\)')).Count
$varHits = ([regex]::Matches($mainRaw, '(?m)^var\s+_checks_bench\s+:=\s*ChecksBench\.new\(\)')).Count
$setupHits = ([regex]::Matches($mainCode, '_checks_bench\.setup\(')).Count
$runSteerHits = ([regex]::Matches($mainCode, 'await\s+_checks_bench\.run_steerbench\(')).Count
$runBrakeHits = ([regex]::Matches($mainCode, 'await\s+_checks_bench\.run_brakebench\(')).Count
$wireOk = ($constHits -eq 1 -and $varHits -eq 1 -and $setupHits -eq 1 -and $runSteerHits -eq 1 -and $runBrakeHits -eq 1)
Add-R "main.gd 接线恰各一处（const/var/setup/run_steerbench/run_brakebench）" $wireOk (
    "const={0}/1 var={1}/1 setup={2}/1 steer={3}/1 brake={4}/1" -f $constHits, $varHits, $setupHits, $runSteerHits, $runBrakeHits)

# ---------------------------------------------------------------- ④ 永久居民不许搬（闸门约束）
# check-docs.ps1 L59 正则 `const\s+<NAME>\s*:=\s*(\d+)` 从 main.gd 原文取值，
# check-readme.ps1 直接解析 `match _check:` 块分支名 —— 搬走即闸门假红。ADR-001 明文禁止。
$elevConst = $mainRaw -match '(?m)^const\s+LAYOUT_ELEV_CASES\s*:=\s*10\s*$'
$racingConst = $mainRaw -match '(?m)^const\s+LAYOUT_RACING_CASES\s*:=\s*6\s*$'
$revConst = $mainRaw -match '(?m)^const\s+REVERSE_CASES\s*:=\s*6\s*$'
# ⚠ match 分派表在 _check_tick() 函数体内、带 tab 缩进，锚定必须允许行首空白
# （layout 批用 IndexOf 不锚定；这里锚 `^\s*` 防注释里提到同名文本造成假阳性）。
$matchTable = $mainRaw -match '(?m)^\s*match\s+_check:'
Add-R "ADR-001 永久居民仍在 main.gd（三 CASES 常量 + match _check: 分派表）" (
    $elevConst -and $racingConst -and $revConst -and $matchTable) (
    "ELEV={0} RACING={1} REVERSE={2} match表={3}（期望全 True）" -f $elevConst, $racingConst, $revConst, $matchTable)

# ---------------------------------------------------------------- ⑤ 模块 API + 8 函数 + 11 常量 + 状态齐全
$apiOk = $true
$apiDetail = ""
foreach ($sig in @("func run_steerbench(", "func run_brakebench(", "func setup(",
    'const Autopilot := preload("res://scripts/autopilot.gd")')) {
    $c = ([regex]::Matches($modRaw, [regex]::Escape($sig))).Count
    if ($c -lt 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $sig, $c)
}
# 8 个内部函数逐个点名（防漏搬：structcheck 的全部意义就在这）
$funcNames = @(
    "_steerbench_sample", "_steerbench_aggregate", "_steerbench_run",
    "_brakebench_sample", "_brakebench_aggregate", "_brakebench_run"
)
foreach ($n in $funcNames) {
    $c = ([regex]::Matches($modRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
# 两个公开入口也按函数定义各查一次（run_steerbench / run_brakebench）
foreach ($n in @("run_steerbench", "run_brakebench")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
# 11 个随迁常量逐个点名
foreach ($n in @("STEERBENCH_WINDOW_SEC", "STEERBENCH_REPEATS", "STEERBENCH_MIN_VALID_FRAMES", "STEERBENCH_CV_LIMIT",
    "BRAKEBENCH_REPEATS", "BRAKEBENCH_MAX_WINDOW_SEC", "BRAKEBENCH_MIN_VALID_FRAMES",
    "BRAKEBENCH_STEADY_LO", "BRAKEBENCH_STEADY_HI", "BRAKEBENCH_MIN_ABRAKE", "BRAKEBENCH_STOP_MPS")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^const\s+' + $n + '\s*:='))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}定义={1}" -f $n, $c)
}
# 状态：本族原实现就没有模块级状态（全部是函数内局部量），迁移后只允许有 3 个注入 var
# （_car / _track / _physics_frame）。多一个 var = 有人往模块里加了隐藏状态。
$modVarHits = ([regex]::Matches($modRaw, '(?m)^var\s+')).Count
foreach ($n in @("_car", "_track", "_physics_frame")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^var\s+' + $n + '\s*:'))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}定义={1}" -f $n, $c)
}
if ($modVarHits -ne 3) { $apiOk = $false }
$apiDetail += (" 模块级var总数={0}(期望3)" -f $modVarHits)
Add-R "模块含 2 公开入口 + setup + 6 内部函数 + 11 常量 + 恰 3 个注入 var（零多余状态）" $apiOk ("实测：" + $apiDetail)

# ---------------------------------------------------------------- ⑥ 日志锚串在模块里（保 A/B 日志逐字一致）
# 纯迁移的 A/B 判据是"台架日志逐行相同"；这些锚串是日志的主体，
# 少任何一条都说明迁移时改坏了 print 文案（A/B 会红，但那里已太晚）。
$anchors = @(
    "[自检] 台架 启动：",
    "[自检] 台架 摆位：",
    "[自检] 台架 steer=",
    "[自检] 台架 === 横向加速度矩阵",
    "[自检] 台架 ✔ 夹具可用",
    "[自检] 台架 ✘ 没有任何一格拿到有效读数",
    "[自检] 台架 ✘ 满舵@40km/h",
    "[自检] 台架 提示：本项是测量",
    "[自检] 台架刹 启动：",
    "[自检] 台架刹 摆位：",
    "[自检] 台架刹 a_brake 定义：",
    "[自检] 台架刹 μ 自核：",
    "[自检] 台架刹 抓地容量：",
    "[自检] 台架刹 v0=",
    "[自检] 台架刹 === a_brake 矩阵",
    "[自检] 台架刹 ✔ 夹具可用",
    "[自检] 台架刹 饱和判定",
    "[自检] 台架刹 提示：跨进程复现判据",
    "[台架帧] steer=",
    "[台架刹帧] v0="
)
$anchorOk = $true
$anchorDetail = ""
foreach ($a in $anchors) {
    $c = ([regex]::Matches($modRaw, [regex]::Escape($a))).Count
    if ($c -lt 1) { $anchorOk = $false }
    $anchorDetail += (" [{0}]={1}" -f $a, $c)
}
Add-R "20 条日志锚串全部在模块里（print 文案零改动）" $anchorOk ("实测：" + $anchorDetail)

# ---------------------------------------------------------------- ⑦ await 政策：恰 4 处、三种形态
# 本族原有真实 await 4 处（screenshot_mode 先例同款钉死）：
#   · 2 处 `await get_tree().physics_frame`（_steerbench_run / _brakebench_run 的帧循环）
#     → 注入 Callable 后为 `await _physics_frame.call()`，是同一个 Signal；
#   · 2 处族内 `await _steerbench_run(...)` / `await _brakebench_run(...)` 留模块内。
# main.gd 分发口的 `await _checks_bench.run_*()` 留在 main 自己那层协程 ——
# 协程深度与迁移前一致（opponent_spawner 实证：多一层协程 = physics_frame 恢复时机差
# 1 物理帧 = 25856 行日志发散）。
$awaitInMod = ([regex]::Matches($modCode, '(?<![\.\w])await\s+')).Count
$pfHits = ([regex]::Matches($modCode, 'await\s+_physics_frame\.call\(\)')).Count
$srHits = ([regex]::Matches($modCode, 'await\s+_steerbench_run\(')).Count
$brHits = ([regex]::Matches($modCode, 'await\s+_brakebench_run\(')).Count
$treeHits2 = ([regex]::Matches($modCode, 'get_tree\(\)|get_viewport\(\)')).Count
$awaitOk = ($awaitInMod -eq 4 -and $pfHits -eq 2 -and $srHits -eq 1 -and $brHits -eq 1 -and $treeHits2 -eq 0)
Add-R "bench.gd 内 await 恰 4 处（2 physics_frame.call + 1 _steerbench_run + 1 _brakebench_run；get_tree=0）" $awaitOk (
    "await={0}/4 physics_frame={1}/2 _steerbench_run={2}/1 _brakebench_run={3}/1 get_tree/viewport={4}/0" -f
    $awaitInMod, $pfHits, $srHits, $brHits, $treeHits2)

# ---------------------------------------------------------------- ⑧ 模块边界：不接触场景树
# Track 由 setup() 注入；模块里不该再有 get_node / get_tree / get_viewport。
$getNodeHits = ([regex]::Matches($modCode, '(?<![\.\w])get_node(_or_null)?\(')).Count
$boundaryOk = ($getNodeHits -eq 0 -and $treeHits2 -eq 0)
Add-R "模块无 get_node/get_tree/get_viewport（车/赛道注入，physics_frame 走 Callable）" $boundaryOk (
    "get_node={0} get_tree/viewport={1}（期望 0/0）" -f $getNodeHits, $treeHits2)

# ---------------------------------------------------------------- ⑨ 没被误迁：邻族与 layout 接线原样
$revOk = ($mainRaw -match 'func\s+_check_reverse\s*\(') -and ($mainRaw -match 'const\s+REVERSE_CASES\s*:=\s*6') `
    -and ($mainRaw -match 'func\s+_check_escape\s*\(') -and ($mainRaw -match 'func\s+_check_flip\s*\(') `
    -and ($mainRaw -match 'func\s+_check_friction\s*\(') -and ($mainRaw -match 'func\s+_check_phys\s*\(') `
    -and ($mainCode -match '_checks_layout\.setup\(') -and ($mainCode -match 'await\s+_checks_layout\.run\(')
Add-R "reverse/escape/flip/friction/phys 族与 layout 接线仍留在 main.gd（批次边界未越界）" $revOk (
    $(if ($revOk) { "八个锚点都在" } else { "有锚点丢失（越界删了）" }))

# 分发口：两道闸门用同一个正则提取分支名，这里镜像一遍 ——
# steerbench / brakebench 分支必须在、且分支总数仍是 26（防误删/误增分发项）。
$tickIdx = $mainRaw.IndexOf('match _check:')
$impl = @()
if ($tickIdx -lt 0) {
    $impl = @()
} else {
    $rest = $mainRaw.Substring($tickIdx)
    $nextFunc = [regex]::Match($rest, '(?m)^func ')
    $block = if ($nextFunc.Success) { $rest.Substring(0, $nextFunc.Index) } else { $rest }
    $impl = [regex]::Matches($block, '(?m)^\s+"([a-z][a-z0-9_]*)":') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
}
$dispatchOk = ($impl -contains "steerbench") -and ($impl -contains "brakebench") -and ($impl.Count -eq 26)
Add-R "match _check: 分发口含 steerbench+brakebench 且共 26 项（闸门视图不变）" $dispatchOk (
    "分支数={0} 含steer={1} 含brake={2}（期望 26/True/True）" -f $impl.Count, ($impl -contains "steerbench"), ($impl -contains "brakebench"))

# 受保护路径一律不许动：启动器脚本 / 无关游戏脚本 / 验收闸门 / 工程配置。
# 用 git status 全量比对（不逐条传中文路径，避免参数编码把结论搞假）。
#
# ⚠ 2026-10-13 修订时抓到的**潜伏 bug**（layout 批实录）：git 默认 core.quotepath=true，
#   非 ASCII 路径在 status/diff 输出里会被转义成 `\345` 八进制（外加双引号）。原断言只按
#   真中文 match → `04-Godot启动器/` 这条**从来匹配不上，受保护目录一直在睁眼瞎**。
#   现两种形态都匹配：① git 转义形态（纯 ASCII，不依赖控制台编码，主判据）；
#   ② 真中文形态（万一哪天 quotepath=false 且控制台按 UTF-8 解码）。
#
# ⚠ 唯一例外（2026-10-13 SPLIT-CHECKS-LAYOUT-001，**用户当日签字**）：
#   `04-Godot启动器/parse-check.ps1` 的聚合器用 `$_.Name`（纯文件名）拼 res:// 路径，
#   scripts/ 出现第一个子目录（scripts/checks/）后既假红、又让子目录脚本实际漏查。
#   允许的修复**仅限一行**：路径构造改为相对路径。例外条件机器钉死（不是 blanket 放行）：
#   该文件 diff 必须恰为 1 增 1 删，且其新增行含 `Substring($Project.Length + 1)`；
#   其它受保护路径的任何改动 → 照样红。
#   （numstat/diff 同样不传中文路径：全量输出在内存里按 parse-check.ps1 过滤。）
$protected = @("04-Godot启动器/", "scripts/menu.gd", "scripts/vehicle.gd", "scripts/ai_opponent.gd",
    "scripts/racing_line.gd", "scripts/track_layout.gd", "project.godot",
    "run-all-checks.ps1", "check-docs.ps1", "check-readme.ps1")
# 把路径转成 git core.quotepath 的转义形态（非 ASCII → \八进制），用于匹配 git 输出。
function To-GitQuotedPattern([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        if ([int]$ch -lt 128) { [void]$sb.Append($ch) }
        else {
            foreach ($b in [System.Text.Encoding]::UTF8.GetBytes([string]$ch)) {
                [void]$sb.Append('\').Append([Convert]::ToString($b, 8))
            }
        }
    }
    return [regex]::Escape($sb.ToString())
}
$parseFixOk = $false
$allNum = @(& git -C $Root diff --numstat)
$parseNum = @($allNum | Where-Object { $_ -match 'parse-check\.ps1' })
$allDiff = @(& git -C $Root diff -U0)
$inParse = $false
$parseAdded = @()
foreach ($dl in $allDiff) {
    if ($dl -match '^diff --git ') { $inParse = ($dl -match 'parse-check\.ps1') }
    elseif ($inParse -and $dl -match '^\+' -and $dl -notmatch '^\+\+\+') { $parseAdded += $dl }
}
if ($parseNum.Count -eq 1 -and $parseNum[0] -match '^1\s+1\s' -and
    ($parseAdded -match 'Substring\(\$Project\.Length \+ 1\)')) {
    $parseFixOk = $true
}
$statusLines = @(& git -C $Root status --porcelain -uall)
$touched = @()
foreach ($l in $statusLines) {
    foreach ($p in $protected) {
        $hit = $false
        if ($l -match (To-GitQuotedPattern $p)) { $hit = $true }
        elseif ($l -match [regex]::Escape($p)) { $hit = $true }
        if ($hit) {
            if ($parseFixOk -and $l -match 'parse-check\.ps1') { continue }
            $touched += $l.Trim()
        }
    }
}
Add-R "受保护路径零改动（启动器/无关脚本/闸门/工程配置）" ($touched.Count -eq 0) (
    $(if ($touched.Count -eq 0) {
            if ($parseFixOk) { "git status 中无受保护路径（唯一例外生效：parse-check.ps1 一行路径修复，用户已签字）" }
            else { "git status 中无受保护路径" }
        } else { "被碰到：" + ($touched -join " ; ") }))

# ---------------------------------------------------------------- ⑩ .uid 文件在盘、13 位、与现存无碰撞
# headless 跑 Godot 不自动生成 .uid → 新手写（先例：layout.gd.uid / screenshot_mode.gd.uid）。
# 碰撞检查：Godot 的 uid 撞车会静默解析到别人的脚本，必须逐个比对（本批起机器化）。
$uidOk = $false
$uidDetail = "文件不存在（尚未创建）"
if (Test-Path $ModUid) {
    $uidText = (Get-Content $ModUid -Raw).Trim()
    $existing = @()
    Get-ChildItem -Path $Proj -Recurse -Filter "*.uid" -File | Where-Object {
        $_.FullName -notlike "*\addons\*" -and $_.FullName -ne $ModUid } | ForEach-Object {
        $existing += (Get-Content $_.FullName -Raw).Trim()
    }
    $fmtOk = $uidText -match '^uid://[a-z0-9]{13}$'
    $collide = $existing -contains $uidText
    $uidOk = ($fmtOk -and -not $collide)
    $uidDetail = ("{0}（格式13位={1}，与现存 {2} 个 uid 碰撞={3}）" -f $uidText, $fmtOk, $existing.Count, $collide)
}
Add-R "bench.gd.uid 存在、13 位、与现存 uid 无碰撞" $uidOk $uidDetail

# ---------------------------------------------------------------- ⑪ 两份 AGENTS.md 逐字节一致
$agentsOk = $false
$agentsDetail = ""
$rootAgents = Join-Path $Root "AGENTS.md"
$projAgents = Join-Path $Proj "AGENTS.md"
if ((Test-Path $rootAgents) -and (Test-Path $projAgents)) {
    $h1 = (Get-FileHash $rootAgents -Algorithm SHA256).Hash
    $h2 = (Get-FileHash $projAgents -Algorithm SHA256).Hash
    $agentsOk = ($h1 -eq $h2)
    $agentsDetail = ("根={0} 工程={1}" -f $h1.Substring(0, 12), $h2.Substring(0, 12))
} else {
    $agentsDetail = "有文件缺失（根存在=$(Test-Path $rootAgents)，工程存在=$(Test-Path $projAgents)）"
}
Add-R "根 AGENTS.md 与 godot-racer/AGENTS.md 逐字节一致" $agentsOk $agentsDetail

# ---------------------------------------------------------------- ⑫ 规模指纹：行数与 func 数
# 期望值按计划编辑逐段口算，再用 `git diff --numstat` 复核（迁移前 4033 行 / 66 func）：
#   删除 706 行：
#     · L2326-3029 两族整块（steerbench 横幅+注释+4 常量+4 函数， brakebench 同构
#       7 常量+4 函数，含段间空行 L2667 与段尾两空行 L3028-3029）= 704 行；
#     · dispatch 两个旧 await 行（L327/L329）= 2 行。
#   插入 18 行：
#     · 模块声明块 10（前导空行 + 7 注释 + const + var）；
#     · setup 接线 3（2 注释 + 调用；原 L158 空行作分隔，不重复插）；
#     · 删除位 breadcrumb 注释 4（3 注释 + 1 尾空行，与 flip 横幅分隔）；
#     · dispatch 两个新 await 行 = 2。
#   4033 - 706 + 18 = 3346；func：-8（两族共 8 个函数全部外迁，main 不新增函数）= 58。
#   git diff --numstat 复核：+18/-705（删除 705 = 704 行整块 + 2 行 dispatch − 1 行
#   原段尾空行与 breadcrumb 尾空行对齐；行数口径 4033−705+18=3346 与口算一致）。
$wantLines = 3346
$wantFuncs = 58
Add-R "main.gd 规模 = 3346 行 / 58 func（迁移后准确值）" ($mainLines -eq $wantLines -and $mainFuncs -eq $wantFuncs) (
    "实测 行={0}/func={1}（期望 {2}/{3}；迁移前 4033/66）" -f $mainLines, $mainFuncs, $wantLines, $wantFuncs)

# ---------------------------------------------------------------- 输出
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$head = "================ SPLIT-CHECKS-BENCH-002 结构校验（{0}）================" -f $stamp
$fail = @($results | Where-Object { $_.StartsWith("[FAIL]") })
$summary = "汇总：{0} 项断言，{1} 项失败" -f $results.Count, $fail.Count
$out = @($head) + $results + @("", $summary)
$logName = if ($OutName -ne "") { $OutName } else { "split-checks-bench-structcheck.log" }
$logFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) $logName
if ($MyInvocation.MyCommand.Path) {
    $out | Out-File -FilePath $logFile -Encoding utf8
}
$out | ForEach-Object { Write-Host $_ }
if ($fail.Count -gt 0) { exit 1 }
exit 0
