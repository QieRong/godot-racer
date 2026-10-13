# SPLIT-CHECKS-LAYOUT-001 结构校验（TDD：先红后绿）。
#
# 为什么必须有它：本次是"纯迁移"，最大的风险不是逻辑改错，而是**迁移不完整** ——
# 漏搬一个状态/函数、调用点漏改、把不该搬的（ADR-001 三个永久居民常量 / reverse 族 /
# escape 族）顺手扫进来、或者把注入写反（模块去 get_node / 反向持有场景）。
# 这些都不会让 parse 报错，只会在 A/B 里表现为"行为没变但结构不对"。
# 所以把"迁完后的结构事实"写成可执行断言，动手前跑红、迁完跑绿。
#
# 与 split-screenshot-structcheck.ps1 的差异（layout 族的两个特有决策）：
#   ① **残留检查跑在"去注释代码"上**：ADR-001 要求 LAYOUT_ELEV_CASES /
#      LAYOUT_RACING_CASES 连注释一起留守 main.gd，而 ELEV 的注释里 legitimately
#      提到 `_layout_pass`（解释"为什么这个数字要单独卡"的历史缘由）—— 代码零残留
#      才是迁移完整性的正确判据，注释里的历史引用不是漏搬。
#   ② **多两条"不许搬"断言**：两个闸门登记的常量必须仍在 main.gd（check-docs.ps1
#      L59 正则以 main.gd 原文取值，搬走即闸门假红）。
#
# 用法：pwsh -File godot-logs\split-checks-layout-structcheck.ps1
# 退出码：0 = 全绿；1 = 有断言失败（红）。
param(
    [string]$Root = ""
)
$ErrorActionPreference = "Continue"
if ($Root -eq "") { $Root = Split-Path -Parent $PSScriptRoot }   # godot-logs 的父目录 = git 根
$Proj = Join-Path $Root "godot-racer"
$Main = Join-Path $Proj "scenes\main.gd"
$Mod = Join-Path $Proj "scripts\checks\layout.gd"
$ModUid = Join-Path $Proj "scripts\checks\layout.gd.uid"

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
Add-R "scripts/checks/layout.gd 存在" $exists $(if ($exists) { "scripts/checks/layout.gd" } else { "文件不存在（尚未创建）" })

$extendsOk = $modRaw -match '(?m)^extends\s+RefCounted\s*$'
$classNameHits = ([regex]::Matches($modRaw, '(?m)^class_name\s+')).Count
Add-R "模块 extends RefCounted 且无 class_name（§2.4 铁律）" ($extendsOk -and $classNameHits -eq 0) (
    "extends RefCounted={0} class_name 定义数={1}（期望 True/0）" -f $extendsOk, $classNameHits)

# ---------------------------------------------------------------- ② main.gd 代码零残留
# 迁完后这些 token 在 main.gd 的**代码**里一次都不该出现（连注释都不留的判据不适用于
# 本族：两个 ADR-001 常量的注释按设计留守，见文件头差异说明 ①）。
# ⚠ `_check_layout` 不是 `_checks_layout`（新模块实例名）的子串，不会误命中。
$residTokens = @(
    # 24 个函数
    "_check_layout", "_check_layout_parser", "_check_layout_elevation", "_check_layout_racing",
    "_check_layout_target_speed", "_check_layout_level", "_layout_ok", "_layout_err",
    "_layout_close_ok", "_layout_build_err", "_layout_elev_call", "_layout_elev_record",
    "_layout_elev_ok", "_layout_elev_err", "_layout_racing_fn", "_layout_racing_record",
    "_layout_racing_vel", "_layout_racing_brake", "_layout_target_record", "_layout_target_eq",
    "_layout_target_ratio", "_layout_target_ceiling", "_layout_target_legacy_guard",
    "_layout_round_trip",
    # 10 个状态
    "_layout_pass", "_layout_fail", "_layout_geom_fail", "_layout_elev_cases",
    "_layout_elev_failed", "_layout_racing_cases", "_layout_racing_failed",
    "_layout_racing_grip", "_layout_target_cases", "_layout_target_failed",
    # 2 个随迁常量（闸门未登记、非永久居民）
    "LAYOUT_TARGET_CASES", "A_LAT_BASE"
)
$residTotal = 0
$residDetail = ""
foreach ($n in $residTokens) {
    $c = ([regex]::Matches($mainCode, [regex]::Escape($n))).Count
    if ($c -gt 0) { $residDetail += (" {0}={1}" -f $n, $c) }
    $residTotal += $c
}
Add-R "main.gd 代码零残留（24 函数 + 10 状态 + 2 常量，共 36 个 token）" ($residTotal -eq 0) (
    "残留总数 = {0}{1}" -f $residTotal, $residDetail)

# ---------------------------------------------------------------- ③ main.gd 侧接线恰各一处
$constHits = ([regex]::Matches($mainRaw, '(?m)^const\s+ChecksLayout\s+:=\s*preload\("res://scripts/checks/layout\.gd"\)')).Count
$varHits = ([regex]::Matches($mainRaw, '(?m)^var\s+_checks_layout\s+:=\s*ChecksLayout\.new\(\)')).Count
$setupHits = ([regex]::Matches($mainCode, '_checks_layout\.setup\(')).Count
$runHits = ([regex]::Matches($mainCode, 'await\s+_checks_layout\.run\(')).Count
$wireOk = ($constHits -eq 1 -and $varHits -eq 1 -and $setupHits -eq 1 -and $runHits -eq 1)
Add-R "main.gd 接线恰各一处（const/var/setup/await run）" $wireOk (
    "const={0}/1 var={1}/1 setup={2}/1 run={3}/1" -f $constHits, $varHits, $setupHits, $runHits)

# ---------------------------------------------------------------- ④ 永久居民不许搬（闸门约束）
# check-docs.ps1 L59 正则 `const\s+<NAME>\s*:=\s*(\d+)` 从 main.gd 原文取值；
# 这两个常量搬走 → 闸门报"找不到常量"→ 验收假红。ADR-001 明文禁止。
$elevConst = $mainRaw -match '(?m)^const\s+LAYOUT_ELEV_CASES\s*:=\s*10\s*$'
$racingConst = $mainRaw -match '(?m)^const\s+LAYOUT_RACING_CASES\s*:=\s*6\s*$'
Add-R "ADR-001 永久居民仍在 main.gd（LAYOUT_ELEV_CASES:=10 / LAYOUT_RACING_CASES:=6）" ($elevConst -and $racingConst) (
    "ELEV={0} RACING={1}（期望 True/True）" -f $elevConst, $racingConst)

# ---------------------------------------------------------------- ⑤ 模块 API 与 12 个状态/常量齐全
$apiOk = $true
$apiDetail = ""
foreach ($sig in @("func run(", "func setup(")) {
    $c = ([regex]::Matches($modRaw, [regex]::Escape($sig))).Count
    if ($c -lt 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $sig, $c)
}
# 24 个函数逐个点名（防漏搬：structcheck 的全部意义就在这）
$funcNames = @(
    "_check_layout_parser", "_check_layout_elevation", "_check_layout_racing",
    "_check_layout_target_speed", "_check_layout_level", "_layout_ok", "_layout_err",
    "_layout_close_ok", "_layout_build_err", "_layout_elev_call", "_layout_elev_record",
    "_layout_elev_ok", "_layout_elev_err", "_layout_racing_fn", "_layout_racing_record",
    "_layout_racing_vel", "_layout_racing_brake", "_layout_target_record", "_layout_target_eq",
    "_layout_target_ratio", "_layout_target_ceiling", "_layout_target_legacy_guard",
    "_layout_round_trip"
)
foreach ($n in $funcNames) {
    $c = ([regex]::Matches($modRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
# 10 个状态 + 2 个随迁常量
foreach ($n in @("_layout_pass", "_layout_fail", "_layout_geom_fail", "_layout_elev_cases",
    "_layout_elev_failed", "_layout_racing_cases", "_layout_racing_failed",
    "_layout_racing_grip", "_layout_target_cases", "_layout_target_failed")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^var\s+' + $n + '\s*:='))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}定义={1}" -f $n, $c)
}
foreach ($n in @("LAYOUT_TARGET_CASES", "A_LAT_BASE")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^const\s+' + $n + '\s*:='))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}定义={1}" -f $n, $c)
}
Add-R "模块含 run/setup + 23 个内部函数 + 10 状态 + 2 随迁常量" $apiOk ("实测：" + $apiDetail)

# ---------------------------------------------------------------- ⑥ 日志锚串在模块里（保 A/B 日志逐字一致）
# 纯迁移的 A/B 判据是"layout 日志逐行相同"；这些锚串是日志的主体，
# 少任何一条都说明迁移时改坏了 print 文案（A/B 会红，但那里已太晚）。
$anchors = @(
    "[自检] 布局验收 ① 解析器用例组",
    "[自检] 布局验收 ① 闭环与曲率",
    "[自检] 布局验收 ③ 高度剖面解析用例组",
    "[自检] 布局验收 ④ 限速 / 刹车距离用例组",
    "[自检] 布局验收 ⑤ AI 最终目标速度用例组",
    "[自检] 布局验收 ② 本关 layout = ",
    "[自检] 赛道布局验收 ✔ 解析用例",
    "[自检] 赛道布局验收 ✘ 解析用例失败",
    "[自检]   剖面用例跑了",
    "[自检]   限速/刹车用例跑了",
    "[自检]   最终目标用例跑了",
    "[自检]   往返唯一性：",
    "[CHECK] 找不到 Track 节点"
)
$anchorOk = $true
$anchorDetail = ""
foreach ($a in $anchors) {
    $c = ([regex]::Matches($modRaw, [regex]::Escape($a))).Count
    if ($c -lt 1) { $anchorOk = $false }
    $anchorDetail += (" [{0}]={1}" -f $a, $c)
}
Add-R "13 条日志锚串全部在模块里（print 文案零改动）" $anchorOk ("实测：" + $anchorDetail)

# ---------------------------------------------------------------- ⑦ 帧一致性铁律：模块内 await 恰 0 处
# 与 opponent_spawner 同标准：本族原本只有 `await _check_layout_level(mod)` 一拍，
# 而 _check_layout_level 自身无 await（no-op），模块化后一拍都不该有。
# main.gd 分发口的 `await _checks_layout.run()` 留在 main 自己那层协程，深度不变。
$awaitInMod = ([regex]::Matches($modCode, '(?<![\.\w])await\s+')).Count
Add-R "layout.gd 内 await 数 == 0（本族无真实挂起点，保协程深度不变）" ($awaitInMod -eq 0) (
    "模块内 await={0}（期望 0）" -f $awaitInMod)

# ---------------------------------------------------------------- ⑧ 模块边界：不接触场景树
# Track 由 setup() 注入；模块里不该再有 get_node / get_tree / get_viewport。
$getNodeHits = ([regex]::Matches($modCode, '(?<![\.\w])get_node(_or_null)?\(')).Count
$treeHits = ([regex]::Matches($modCode, 'get_tree\(\)|get_viewport\(\)')).Count
$boundaryOk = ($getNodeHits -eq 0 -and $treeHits -eq 0)
Add-R "模块无 get_node/get_tree/get_viewport（Track 经 setup 注入）" $boundaryOk (
    "get_node={0} get_tree/viewport={1}（期望 0/0）" -f $getNodeHits, $treeHits)

# ---------------------------------------------------------------- ⑨ 没被误迁：reverse / escape / flip 与分发口原样
$revOk = ($mainRaw -match 'func\s+_check_reverse\s*\(') -and ($mainRaw -match 'const\s+REVERSE_CASES\s*:=\s*6') `
    -and ($mainRaw -match 'func\s+_check_escape\s*\(') -and ($mainRaw -match 'func\s+_check_flip\s*\(')
Add-R "reverse 族 / escape / flip 仍留在 main.gd（批次边界未越界）" $revOk (
    $(if ($revOk) { "四个锚点都在" } else { "有锚点丢失（越界删了）" }))

# 分发口：两道闸门用同一个正则提取分支名，这里镜像一遍 ——
# "layout" 分支必须在、且分支总数仍是 26（防误删/误增分发项）。
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
$dispatchOk = ($impl -contains "layout") -and ($impl.Count -eq 26)
Add-R "match _check: 分发口含 layout 且共 26 项（闸门视图不变）" $dispatchOk (
    "分支数={0} 含layout={1}（期望 26/True）" -f $impl.Count, ($impl -contains "layout"))

# 受保护路径一律不许动：启动器脚本 / 无关游戏脚本 / 验收闸门 / 工程配置。
# 用 git status 全量比对（不逐条传中文路径，避免参数编码把结论搞假）。
#
# ⚠ 2026-10-13 修订时抓到的**潜伏 bug**：git 默认 core.quotepath=true，非 ASCII 路径在
#   status/diff 输出里会被转义成 `\345` 八进制（外加双引号）。原断言只按真中文 match →
#   `04-Godot启动器/` 这条**从来匹配不上，受保护目录一直在睁眼瞎**（只保护到 ASCII 路径）。
#   现两种形态都匹配：① git 转义形态（纯 ASCII，不依赖控制台编码，主判据）；
#   ② 真中文形态（万一哪天 quotepath=false 且控制台按 UTF-8 解码）。
#
# ⚠ 唯一例外（2026-10-13 SPLIT-CHECKS-LAYOUT-001，**用户当日签字**）：
#   `04-Godot启动器/parse-check.ps1` 的聚合器用 `$_.Name`（纯文件名）拼 res:// 路径，
#   scripts/ 出现第一个子目录（scripts/checks/，本批引入）后：① layout.gd 被拼成不存在
#   的 res://scripts/layout.gd → parse-check 假红；② 子目录脚本其实根本没进过聚合
#   （覆盖漏洞）。允许的修复**仅限一行**：路径构造改为相对路径。
#   例外条件机器钉死（不是 blanket 放行）：该文件 diff 必须恰为 1 增 1 删，且其新增行
#   含 `Substring($Project.Length + 1)`；其它受保护路径的任何改动 → 照样红。
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

# ---------------------------------------------------------------- ⑩ .uid 文件在盘且格式合法
# headless 跑 Godot 不自动生成 .uid → 新手写（先例：screenshot_mode.gd.uid）。
$uidOk = $false
$uidDetail = "文件不存在（尚未创建）"
if (Test-Path $ModUid) {
    $uidText = (Get-Content $ModUid -Raw).Trim()
    $uidOk = $uidText -match '^uid://[a-z0-9]{8,}$'
    $uidDetail = $uidText
}
Add-R "layout.gd.uid 存在且格式合法（uid://...）" $uidOk $uidDetail

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
# 期望值按计划编辑逐段口算（迁移前 4801 行 / 90 func）：
#   删除 786 行（原行号，自底向上删）：
#     · 3471-3488 段落头+10 状态（18）  3489-3536 _check_layout（48）
#     · 3537-3654 4 个 _layout_* 辅助 + _check_layout_parser（118）
#     · 3660-3663 ELEV 的 2 状态（4）   3664-3779 elev 组到 _check_layout_elevation（116）
#     · 3782-3804 racing 段落头注释+尾空行（23）  3807-3812 RACING 的 3 状态（6）
#     · 3813-4172 racing/target 两组到 _check_layout_target_speed（360）
#     · 4356-4448 _check_layout_level + _layout_round_trip（93）
#   插入 18 行：模块声明块 10（7 注释+const+var+空行）、setup 接线 4（2 注释+调用+空行）、
#     两个永久居民常量的 breadcrumb 注释 4。
#   4801 - 786 + 18 = 4033；func：-24（本族 24 个函数全部外迁，main 不新增函数）= 66。
# ⚠ 口算曾把 3537-3654 误算成 18 行（3652-3537+1=116 不是 16）→ 期望值一度错为 4132；
#   已按边界断言证实的区间重算更正。判据仍是"精确值"，不是放宽。
$wantLines = 4033
$wantFuncs = 66
Add-R "main.gd 规模 = 4033 行 / 66 func（迁移后准确值）" ($mainLines -eq $wantLines -and $mainFuncs -eq $wantFuncs) (
    "实测 行={0}/func={1}（期望 {2}/{3}；迁移前 4801/90）" -f $mainLines, $mainFuncs, $wantLines, $wantFuncs)

# ---------------------------------------------------------------- 输出
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$head = "================ SPLIT-CHECKS-LAYOUT-001 结构校验（{0}）================" -f $stamp
$fail = @($results | Where-Object { $_.StartsWith("[FAIL]") })
$summary = "汇总：{0} 项断言，{1} 项失败" -f $results.Count, $fail.Count
$out = @($head) + $results + @("", $summary)
$logFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "split-checks-layout-structcheck.log"
if ($MyInvocation.MyCommand.Path) {
    $out | Out-File -FilePath $logFile -Encoding utf8
}
$out | ForEach-Object { Write-Host $_ }
if ($fail.Count -gt 0) { exit 1 }
exit 0
