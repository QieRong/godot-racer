# SPLIT-CHECKS-BASIC-005b 结构校验（TDD：先红后绿）。
#
# 本次是"纯迁移"，最大风险不是逻辑改错，而是**迁移不完整** —— 漏搬一个 helper、调用点漏改、
# 把不该搬的（ADR-001 三个永久居民 / match 分派表 / 邻族 enclosure-reset-pause…）顺手扫进来、
# 或把注入写反（模块去 get_node / 反向持有场景 / await 多一拍）。这些都不会让 parse 报错，
# 只会在 A/B 里表现为"行为没变但结构不对"。所以把"迁完后的结构事实"写成可执行断言，
# 动手前跑红、迁完跑绿。
#
# 与 split-checks-envphys-structcheck.ps1 的差异（LAP 族的特有事实）：
#   ① **3 个公开入口 + 6 个私有 helper**：
#      public = run_lap / run_stress / run_reverse；
#      private = _reset_loop_hit / _reverse_call / _rev_dot / _reverse_case /
#      _check_reverse_e2e / _find_wrong_way_panel；
#      残留 token 表 = 9 个函数签名；
#      ⚠ `_find_wrong_way_panel` 随**本族**迁入（**与计划书把它放 basic 相反** —— 它只被
#      `_check_reverse_e2e` 调用，实际调用方向交叉，放消费方一侧避免两模块互相注入
#      Callable 的环；见 basic.gd / lap.gd 文件头）；
#   ② **await 政策是"恰 8 处、三种形态"**：6 处 `await _physics_frame.call()`
#      （run_lap 3 / run_reverse_e2e 3）+ 1 处 `await driver.call("stress_test", dur)`
#      （run_stress 内）+ 1 处 `await _check_reverse_e2e(cfg)`（run_reverse 内）；
#      全部是**本族内部**的 await，不 await main 的方法；
#   ③ **注入面**：车 / 赛道 / HUD / [DEBUG-L4] 诊断实例 / 自动驾驶实例 / 障碍场 / 对手生成
#      实例 + 只读代理 `_opponents` + env_phys 模块实例（probe_blocker）+ 1 个 SceneTree
#      + 2 个 Callable（physics_frame / add_child）+ 注入的 REVERSE_CASES 条数；
#      模块级 var 恰 15 个；**不得定义 `const REVERSE_CASES`**（ADR-001 永久居民留守 main，
#      经 setup() 注入，§5.3 单一来源）；
#   ④ **.uid 断言延续"13 位 + 与现存无碰撞"**。
#
# 用法：pwsh -File godot-logs\split-checks-lap-structcheck.ps1 [-OutName <日志名>]
# 退出码：0 = 全绿；1 = 有断言失败（红）。
param(
    [string]$Root = "",
    [string]$OutName = ""
)
$ErrorActionPreference = "Continue"
if ($Root -eq "") { $Root = Split-Path -Parent $PSScriptRoot }   # godot-logs 的父目录 = git 根
$Proj = Join-Path $Root "godot-racer"
$Main = Join-Path $Proj "scenes\main.gd"
$Mod = Join-Path $Proj "scripts\checks\lap.gd"
$ModUid = Join-Path $Proj "scripts\checks\lap.gd.uid"

$results = New-Object System.Collections.Generic.List[string]
function Add-R([string]$name, [bool]$ok, [string]$detail) {
    $tag = if ($ok) { "PASS" } else { "FAIL" }
    $results.Add(("[{0}] {1} -- {2}" -f $tag, $name, $detail))
}

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
Add-R "scripts/checks/lap.gd 存在" $exists $(if ($exists) { "scripts/checks/lap.gd" } else { "文件不存在（尚未创建）" })

$extendsOk = $modRaw -match '(?m)^extends\s+RefCounted\s*$'
$classNameHits = ([regex]::Matches($modRaw, '(?m)^class_name\s+')).Count
Add-R "模块 extends RefCounted 且无 class_name（§2.4 铁律）" ($extendsOk -and $classNameHits -eq 0) (
    "extends RefCounted={0} class_name 定义数={1}（期望 True/0）" -f $extendsOk, $classNameHits)

# §8 向前约束：新建文件总行数 ≤ 1000（本批两模块都是新建文件，不适用历史遗留豁免）。
$modLines = if ($exists) { (Get-Content $Mod).Count } else { 0 }
Add-R "模块总行数 ≤ 1000（§8 向前约束：新建文件）" ($exists -and $modLines -le 1000) (
    $(if ($exists) { "实测 {0} 行（上限 1000）" -f $modLines } else { "文件不存在（尚未创建）" }))

# ---------------------------------------------------------------- ② main.gd 代码零残留
# 9 个已迁函数签名精确匹配（`_check_reverse` 是 `_check_reverse_e2e` 的前缀 → 用 `\s*\(` 约束）。
$residFuncs = @(
    "_check_lap", "_reset_loop_hit", "_check_stress", "_check_reverse",
    "_reverse_call", "_rev_dot", "_reverse_case", "_check_reverse_e2e", "_find_wrong_way_panel"
)
$residTotal = 0
$residDetail = ""
foreach ($n in $residFuncs) {
    $c = ([regex]::Matches($mainCode, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -gt 0) { $residDetail += (" func:{0}={1}" -f $n, $c) }
    $residTotal += $c
}
Add-R "main.gd 代码零残留（9 个函数签名）" ($residTotal -eq 0) (
    "残留总数 = {0}{1}" -f $residTotal, $residDetail)

# ---------------------------------------------------------------- ③ main.gd 侧接线恰各一处
$constHits = ([regex]::Matches($mainRaw, '(?m)^const\s+ChecksLap\s*:=\s*preload\("res://scripts/checks/lap\.gd"\)')).Count
$varHits = ([regex]::Matches($mainRaw, '(?m)^var\s+_checks_lap\s*:=\s*ChecksLap\.new\(\)')).Count
$setupHits = ([regex]::Matches($mainCode, '_checks_lap\.setup\(')).Count
$runLap = ([regex]::Matches($mainCode, 'await\s+_checks_lap\.run_lap\(')).Count
$runStress = ([regex]::Matches($mainCode, 'await\s+_checks_lap\.run_stress\(')).Count
$runRev = ([regex]::Matches($mainCode, 'await\s+_checks_lap\.run_reverse\(')).Count
$wireOk = ($constHits -eq 1 -and $varHits -eq 1 -and $setupHits -eq 1 -and
    $runLap -eq 1 -and $runStress -eq 1 -and $runRev -eq 1)
Add-R "main.gd 接线恰各一处（const/var/setup + 3 分派）" $wireOk (
    "const={0}/1 var={1}/1 setup={2}/1 lap={3}/1 stress={4}/1 reverse={5}/1" -f
    $constHits, $varHits, $setupHits, $runLap, $runStress, $runRev)

# ---------------------------------------------------------------- ④ 永久居民不许搬（闸门约束）
$elevConst = $mainRaw -match '(?m)^const\s+LAYOUT_ELEV_CASES\s*:=\s*10\s*$'
$racingConst = $mainRaw -match '(?m)^const\s+LAYOUT_RACING_CASES\s*:=\s*6\s*$'
$revConst = $mainRaw -match '(?m)^const\s+REVERSE_CASES\s*:=\s*6\s*$'
$matchTable = $mainRaw -match '(?m)^\s*match\s+_check:'
# 反向计数状态（`_reverse_cases` / `_reverse_failed`）随本族外迁 —— main 里不该再有它们的定义。
$revStateGone = (-not ($mainRaw -match '(?m)^var\s+_reverse_cases\s*:=')) -and (-not ($mainRaw -match '(?m)^var\s+_reverse_failed\s*:='))
Add-R "ADR-001 永久居民仍在 main.gd（三 CASES 常量 + match 分派表）；reverse 计数状态已随族外迁" (
    $elevConst -and $racingConst -and $revConst -and $matchTable -and $revStateGone) (
    "ELEV={0} RACING={1} REVERSE={2} match表={3} 计数状态已迁出={4}（期望全 True）" -f
    $elevConst, $racingConst, $revConst, $matchTable, $revStateGone)

# ---------------------------------------------------------------- ⑤ 模块 API + 入口/helper + 恰 14 var
$apiOk = $true
$apiDetail = ""
$setupSig = "func setup(car: VehicleBody3D, track: Node, hud: CanvasLayer"
$c = ([regex]::Matches($modRaw, [regex]::Escape($setupSig))).Count
if ($c -lt 1) { $apiOk = $false }
$apiDetail += (" setup={0}" -f $c)
foreach ($n in @("run_lap", "run_stress", "run_reverse")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
foreach ($n in @("_reset_loop_hit", "_reverse_call", "_rev_dot", "_reverse_case",
    "_check_reverse_e2e", "_find_wrong_way_panel")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
$c = ([regex]::Matches($modRaw, 'const\s+Autopilot\s*:=\s*preload\("res://scripts/autopilot\.gd"\)')).Count
if ($c -ne 1) { $apiOk = $false }
$apiDetail += (" Autopilot预载={0}" -f $c)
# 15 个模块级 var。
$modVarHits = ([regex]::Matches($modRaw, '(?m)^var\s+')).Count
foreach ($n in @("_car", "_track", "_hud", "_l4_diag", "_autopilot", "_obstacle_field",
    "_opponent_spawner", "_opponents", "_checks_envphys", "_tree", "_physics_frame",
    "_add_child", "_reverse_cases_total", "_reverse_cases", "_reverse_failed")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^var\s+' + $n + '\b'))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
if ($modVarHits -ne 15) { $apiOk = $false }
$apiDetail += (" 模块级var总数={0}(期望15)" -f $modVarHits)
# 不得定义第二份 REVERSE_CASES（ADR-001 永久居民，经 setup 注入）。
$dupConst = ([regex]::Matches($modRaw, '(?m)^const\s+REVERSE_CASES\b')).Count
if ($dupConst -ne 0) { $apiOk = $false }
$apiDetail += (" 重复REVERSE_CASES={0}(期望0)" -f $dupConst)
Add-R "模块含 setup + 3 公开入口 + 6 私有 helper + Autopilot 预载 + 恰 14 var（无重复 CASES 常量）" $apiOk ("实测：" + $apiDetail)

# ---------------------------------------------------------------- ⑥ 日志锚串在模块里（保 A/B 日志逐字一致）
# ⚠ 3 条是 run-all-checks.ps1 的**验收判据串**（lap/stress/reverse），必须原样在模块里。
$anchors = @(
    "[CHECK] 找不到 Track 节点",
    "[自检] 自动驾驶跑圈：目标=中心线前方 %.0fm，全油门，最多跑 6 分钟",
    "[自检] 跑圈验收 ✔ 车头方向正常（未掉头）、无卡住事件",
    "[自检] 跑圈验收 ✔ 连续多圈计时正常、无意外重置",
    "[自检] 跑圈验收 ✘ 出现 %d 次卡住事件 —— 卡墙自救没生效（见上方「卡住事件」行）",
    "[自检] 压测开始：本地确定性鲁莽驾驶 %.0f 秒（固定种子，可复现）",
    "[自检] 压测结果：帧数=%d 卡死事件=%d 最大偏离=%.2fm 用例=%d",
    "[自检] 压测验收 ✔ 没有卡死事件，极端用例兜底全部通过",
    "[自检] 压测验收 ✘ 卡死 %d 次 / 用例兜底失败 %d 例",
    "[自检] reverse 验收：门限取自本关配置「%s」—— 进入 %.0f°、退出 %.0f°、速度 %.0f km/h",
    "[自检] reverse 用例跑了 %d/%d 条，绿 %d 条",
    "[自检] reverse 验收 ✔ %d/%d 条用例全绿 + 端到端提示正常",
    "[自检] reverse 验收 ✘ 用例 %d/%d 条、绿 %d 条；端到端 %s",
    "[自检]   ✘ 端到端②：倒车被误报成「方向反了」（亮了 %d 帧）—— 违反「倒车不属于反方向」"
)
$anchorOk = $true
$anchorDetail = ""
foreach ($a in $anchors) {
    $c = ([regex]::Matches($modRaw, [regex]::Escape($a))).Count
    if ($c -lt 1) { $anchorOk = $false ; $anchorDetail += (" [缺失:{0}]" -f $a) }
}
Add-R ("{0} 条日志锚串全部在模块里（print 文案零改动，含 3 条验收判据串）" -f $anchors.Count) $anchorOk (
    $(if ($anchorOk) { ("{0}/{0} 命中" -f $anchors.Count) } else { $anchorDetail }))

# ---------------------------------------------------------------- ⑦ await 政策：恰 8 处、三种形态
$awaitInMod = ([regex]::Matches($modCode, '(?<![\.\w])await\s+')).Count
$pfHits = ([regex]::Matches($modCode, 'await\s+_physics_frame\.call\(\)')).Count
$drvHits = ([regex]::Matches($modCode, 'await\s+driver\.call\(')).Count
$e2eHits = ([regex]::Matches($modCode, 'await\s+_check_reverse_e2e\(')).Count
$treeHits = ([regex]::Matches($modCode, 'get_tree\(\)|get_viewport\(\)')).Count
$awaitOk = ($awaitInMod -eq 8 -and $pfHits -eq 6 -and $drvHits -eq 1 -and
    $e2eHits -eq 1 -and $treeHits -eq 0)
Add-R "lap.gd 内 await 恰 8 处（6 physics_frame.call + 1 driver.call + 1 _check_reverse_e2e；get_tree=0）" $awaitOk (
    "await={0}/8 physics_frame={1}/6 driver.call={2}/1 reverse_e2e={3}/1 get_tree/viewport={4}/0" -f
    $awaitInMod, $pfHits, $drvHits, $e2eHits, $treeHits)

# ---------------------------------------------------------------- ⑧ 模块边界：不接触场景树
# 引用全经 setup() 注入；模块里不该再有裸 get_node / get_tree / get_viewport / get_world_3d，
# 也不许 preload("res://scenes/main.gd") 反向拿 main 脚本（绕开注入、制造第二份场景真相
# —— 复核钉死项之一）。
$getNodeHits = ([regex]::Matches($modCode, '(?<![\.\w])get_node(_or_null)?\(')).Count
$worldHits = ([regex]::Matches($modCode, 'get_world_3d\(')).Count
$preloadMainHits = ([regex]::Matches($modCode, 'preload\(\s*"res://scenes/main\.gd"\s*\)')).Count
$boundaryOk = ($exists -and $getNodeHits -eq 0 -and $treeHits -eq 0 -and $worldHits -eq 0 -and $preloadMainHits -eq 0)
Add-R "模块无裸 get_node/get_tree/get_viewport/get_world_3d，且无 preload(main.gd)（引用全经 setup 注入）" $boundaryOk (
    "模块存在={0} get_node={1} get_tree/viewport={2} get_world_3d={3} preload(main)={4}（期望 存在/0/0/0/0）" -f
    $exists, $getNodeHits, $treeHits, $worldHits, $preloadMainHits)

# ---------------------------------------------------------------- ⑧b _tree 只以 SceneTree 用（复核钉死项之一）
# 注入的 `_tree` 只能当 SceneTree 用：声明必须显式 `: SceneTree`，且所有 `_tree.<成员>`
# 访问必须落在 SceneTree 的公开 API 白名单里（防有人拿它当 Node / 场景根乱用）。
$treeDeclOk = $modRaw -match '(?m)^var\s+_tree\s*:\s*SceneTree\b'
$sceneTreeApi = @("process_frame", "physics_frame", "paused", "root", "get_nodes_in_group",
    "get_first_node_in_group", "current_scene", "get_node_count", "quit")
$treeMembers = @([regex]::Matches($modCode, '_tree\.([A-Za-z_][A-Za-z0-9_]*)') |
    ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$treeOffenders = @($treeMembers | Where-Object { $sceneTreeApi -notcontains $_ })
$treeOnlyOk = ($treeDeclOk -and $treeOffenders.Count -eq 0)
Add-R "模块 _tree 只以 SceneTree 用（显式类型化 + 成员访问全在 SceneTree API 白名单）" $treeOnlyOk (
    "var _tree: SceneTree={0} 访问成员=[{1}] 越界=[{2}]（期望 True / 白名单内 / 无）" -f
    $treeDeclOk, ($treeMembers -join ","), $(if ($treeOffenders.Count -eq 0) { "无" } else { $treeOffenders -join "," }))

# ---------------------------------------------------------------- ⑨ 没被误迁：邻族与 basic 分支原样
$neighborOk = ($mainCode -match '_checks_basic\.setup\(') -and ($mainCode -match '_checks_envphys\.setup\(') `
    -and ($mainCode -match '_checks_layout\.setup\(') -and ($mainCode -match '_checks_bench\.setup\(') `
    -and ($mainCode -match 'await\s+_checks_basic\.run_') -and ($mainCode -match 'await\s+_checks_envphys\.run_') `
    -and ($mainCode -match 'await\s+_checks_layout\.run\(')
Add-R "邻族（basic/env_phys/bench/layout 接线）仍留在 main.gd" $neighborOk (
    $(if ($neighborOk) { "全部锚点都在（批次边界未越界）" } else { "有锚点丢失（越界删了）" }))

# 分发口：3 个 LAP 分支必须在、且分支总数仍是 24。
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
$needBranches = @("lap", "stress", "reverse")
$missing = @($needBranches | Where-Object { $impl -notcontains $_ })
$dispatchOk = ($missing.Count -eq 0) -and ($impl.Count -eq 24)
Add-R "match _check: 分发口含 lap/stress/reverse 且共 24 项（闸门视图不变）" $dispatchOk (
    "分支数={0} 缺失={1}（期望 24 / 无）" -f $impl.Count, $(if ($missing.Count -eq 0) { "无" } else { $missing -join "," }))

$protected = @("04-Godot启动器/", "scripts/menu.gd", "scripts/vehicle.gd", "scripts/ai_opponent.gd",
    "scripts/racing_line.gd", "scripts/track_layout.gd", "scripts/autopilot.gd", "project.godot",
    "run-all-checks.ps1", "check-docs.ps1", "check-readme.ps1")
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
$statusLines = @(& git -C $Root status --porcelain -uall)
$touched = @()
foreach ($l in $statusLines) {
    foreach ($p in $protected) {
        $hit = $false
        if ($l -match (To-GitQuotedPattern $p)) { $hit = $true }
        elseif ($l -match [regex]::Escape($p)) { $hit = $true }
        if ($hit) { $touched += $l.Trim() }
    }
}
Add-R "受保护路径零改动（启动器/无关脚本/闸门/工程配置）" ($touched.Count -eq 0) (
    $(if ($touched.Count -eq 0) { "git status 中无受保护路径" } else { "被碰到：" + ($touched -join " ; ") }))

# ---------------------------------------------------------------- ⑩ .uid 文件在盘、13 位、无碰撞
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
Add-R "lap.gd.uid 存在、13 位、与现存 uid 无碰撞" $uidOk $uidDetail

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
$wantLines = 659    # 迁移后准确值（与 005a 同步，两模块同一次迁移）
$wantFuncs = 17
$sizeOk = $true
$sizeDetail = "实测 行={0}/func={1}（迁移前 1522/34）" -f $mainLines, $mainFuncs
if ($wantLines -gt 0) {
    $sizeOk = ($mainLines -eq $wantLines -and $mainFuncs -eq $wantFuncs)
    $sizeDetail += ("；期望 {0}/{1}" -f $wantLines, $wantFuncs)
}
Add-R "main.gd 规模指纹（迁移前 1522 行 / 34 func）" $sizeOk $sizeDetail

# ---------------------------------------------------------------- 输出
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$head = "================ SPLIT-CHECKS-BASIC-005b 结构校验（{0}）================" -f $stamp
$fail = @($results | Where-Object { $_.StartsWith("[FAIL]") })
$summary = "汇总：{0} 项断言，{1} 项失败" -f $results.Count, $fail.Count
$out = @($head) + $results + @("", $summary)
$logName = if ($OutName -ne "") { $OutName } else { "split-checks-lap-structcheck.log" }
$logFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) $logName
if ($MyInvocation.MyCommand.Path) {
    $out | Out-File -FilePath $logFile -Encoding utf8
}
$out | ForEach-Object { Write-Host $_ }
if ($fail.Count -gt 0) { exit 1 }
exit 0
