# SPLIT-CHECKS-BASIC-005a 结构校验（TDD：先红后绿）。
#
# 本次是"纯迁移"，最大风险不是逻辑改错，而是**迁移不完整** —— 漏搬一个 helper、调用点漏改、
# 把不该搬的（ADR-001 三个永久居民 / match 分派表 / 邻族 lap-stress-reverse）顺手扫进来、
# 或把注入写反（模块去 get_node / 反向持有场景 / await 多一拍）。这些都不会让 parse 报错，
# 只会在 A/B 里表现为"行为没变但结构不对"。所以把"迁完后的结构事实"写成可执行断言，
# 动手前跑红、迁完跑绿。
#
# 与 split-checks-envphys-structcheck.ps1 的差异（BASIC 族的特有事实）：
#   ① **7 个公开入口 + 2 个私有 helper + 1 个共享 helper**：
#      public = run_enclosure / run_reset / run_out_of_bounds / run_minimap /
#      run_reset_key / run_escape / run_pause；
#      private = _check_minimap_obstacles / _menu_press_escape；另 `_cp`（找 order_index==0
#      的检查点，仅 run_escape 调用）也随本族迁入（**与计划书把 _cp 放 lap 相反** —— 实际
#      调用方向是交叉的，放消费方一侧避免两模块互相注入 Callable 的环；见 basic.gd 文件头）；
#      残留 token 表 = 10 个函数签名 + 1 处 `_cp(` 调用点；
#   ② **await 政策是"恰 12 处、三种形态"**：8 处 `await _physics_frame.call()`
#      （run_reset 1 / run_reset_key 5 / run_out_of_bounds 1 / run_escape 1）+ 3 处
#      `await _tree.process_frame`（run_minimap 1 / run_pause 2）+ 1 处
#      `await _check_minimap_obstacles(mm)`（run_minimap 内，本族私有）；
#      全部是**本族内部**的 await，不 await main 的方法；
#   ③ **注入面**：车 / 赛道 / 小地图 / 暂停菜单 / 障碍场 / 物理世界 + 1 个 SceneTree
#      + 1 个 physics_frame Callable + 1 个 mark_keep_alive Callable；模块级 var 恰 9 个，
#      多一个就是有人往模块里塞了隐藏状态（本族不用 HUD —— HUD 只被 lap 族的 reverse helper 用）；
#   ④ **.uid 断言延续"13 位 + 与现存无碰撞"**。
#
# 用法：pwsh -File godot-logs\split-checks-basic-structcheck.ps1 [-OutName <日志名>]
# 退出码：0 = 全绿；1 = 有断言失败（红）。
param(
    [string]$Root = "",
    [string]$OutName = ""
)
$ErrorActionPreference = "Continue"
if ($Root -eq "") { $Root = Split-Path -Parent $PSScriptRoot }   # godot-logs 的父目录 = git 根
$Proj = Join-Path $Root "godot-racer"
$Main = Join-Path $Proj "scenes\main.gd"
$Mod = Join-Path $Proj "scripts\checks\basic.gd"
$ModUid = Join-Path $Proj "scripts\checks\basic.gd.uid"

$results = New-Object System.Collections.Generic.List[string]
function Add-R([string]$name, [bool]$ok, [string]$detail) {
    $tag = if ($ok) { "PASS" } else { "FAIL" }
    $results.Add(("[{0}] {1} -- {2}" -f $tag, $name, $detail))
}

# 去掉整行注释后再匹配，避免把文件头决策记录里点名的符号当成真实代码引用。
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
Add-R "scripts/checks/basic.gd 存在" $exists $(if ($exists) { "scripts/checks/basic.gd" } else { "文件不存在（尚未创建）" })

$extendsOk = $modRaw -match '(?m)^extends\s+RefCounted\s*$'
$classNameHits = ([regex]::Matches($modRaw, '(?m)^class_name\s+')).Count
Add-R "模块 extends RefCounted 且无 class_name（§2.4 铁律）" ($extendsOk -and $classNameHits -eq 0) (
    "extends RefCounted={0} class_name 定义数={1}（期望 True/0）" -f $extendsOk, $classNameHits)

# ---------------------------------------------------------------- ② main.gd 代码零残留
# 10 个已迁函数：用 `^func NAME(` 签名精确匹配（`_check_reset` 是 `_check_reset_key` 的前缀、
# `_check_minimap` 是 `_check_minimap_obstacles` 的前缀，子串匹配会误判）。
$residFuncs = @(
    "_check_enclosure", "_check_reset", "_check_out_of_bounds", "_check_minimap",
    "_check_reset_key", "_check_escape", "_check_pause", "_check_minimap_obstacles",
    "_menu_press_escape", "_cp"
)
$residTotal = 0
$residDetail = ""
foreach ($n in $residFuncs) {
    $c = ([regex]::Matches($mainCode, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -gt 0) { $residDetail += (" func:{0}={1}" -f $n, $c) }
    $residTotal += $c
}
# 调用点残留：`_cp(0)` 与 `_menu_press_escape()` 不应再出现在 main.gd 代码里。
$cpCall = ([regex]::Matches($mainCode, '(?<![_\w])_cp\(')).Count
$mpeCall = ([regex]::Matches($mainCode, '(?<![_\w])_menu_press_escape\(')).Count
if ($cpCall -gt 0) { $residDetail += (" _cp调用={0}" -f $cpCall) }
if ($mpeCall -gt 0) { $residDetail += (" _menu_press_escape调用={0}" -f $mpeCall) }
$residTotal += $cpCall + $mpeCall
Add-R "main.gd 代码零残留（10 函数签名 + 2 处调用点）" ($residTotal -eq 0) (
    "残留总数 = {0}{1}" -f $residTotal, $residDetail)

# ---------------------------------------------------------------- ③ main.gd 侧接线恰各一处
$constHits = ([regex]::Matches($mainRaw, '(?m)^const\s+ChecksBasic\s*:=\s*preload\("res://scripts/checks/basic\.gd"\)')).Count
$varHits = ([regex]::Matches($mainRaw, '(?m)^var\s+_checks_basic\s*:=\s*ChecksBasic\.new\(\)')).Count
$setupHits = ([regex]::Matches($mainCode, '_checks_basic\.setup\(')).Count
$runEnc = ([regex]::Matches($mainCode, '(?<!await\s)_checks_basic\.run_enclosure\(')).Count
$runReset = ([regex]::Matches($mainCode, 'await\s+_checks_basic\.run_reset\(')).Count
$runOob = ([regex]::Matches($mainCode, 'await\s+_checks_basic\.run_out_of_bounds\(')).Count
$runMini = ([regex]::Matches($mainCode, 'await\s+_checks_basic\.run_minimap\(')).Count
$runRK = ([regex]::Matches($mainCode, 'await\s+_checks_basic\.run_reset_key\(')).Count
$runEsc = ([regex]::Matches($mainCode, 'await\s+_checks_basic\.run_escape\(')).Count
$runPause = ([regex]::Matches($mainCode, 'await\s+_checks_basic\.run_pause\(')).Count
$wireOk = ($constHits -eq 1 -and $varHits -eq 1 -and $setupHits -eq 1 -and
    $runEnc -eq 1 -and $runReset -eq 1 -and $runOob -eq 1 -and $runMini -eq 1 -and
    $runRK -eq 1 -and $runEsc -eq 1 -and $runPause -eq 1)
Add-R "main.gd 接线恰各一处（const/var/setup + 7 分派：enclosure 无 await）" $wireOk (
    "const={0}/1 var={1}/1 setup={2}/1 enc={3}/1 reset={4}/1 oob={5}/1 mini={6}/1 rk={7}/1 esc={8}/1 pause={9}/1" -f
    $constHits, $varHits, $setupHits, $runEnc, $runReset, $runOob, $runMini, $runRK, $runEsc, $runPause)

# ---------------------------------------------------------------- ④ 永久居民不许搬（闸门约束）
$elevConst = $mainRaw -match '(?m)^const\s+LAYOUT_ELEV_CASES\s*:=\s*10\s*$'
$racingConst = $mainRaw -match '(?m)^const\s+LAYOUT_RACING_CASES\s*:=\s*6\s*$'
$revConst = $mainRaw -match '(?m)^const\s+REVERSE_CASES\s*:=\s*6\s*$'
$matchTable = $mainRaw -match '(?m)^\s*match\s+_check:'
Add-R "ADR-001 永久居民仍在 main.gd（三 CASES 常量 + match _check: 分派表）" (
    $elevConst -and $racingConst -and $revConst -and $matchTable) (
    "ELEV={0} RACING={1} REVERSE={2} match表={3}（期望全 True）" -f $elevConst, $racingConst, $revConst, $matchTable)

# ---------------------------------------------------------------- ⑤ 模块 API + 入口/helper + 恰 10 var
$apiOk = $true
$apiDetail = ""
$setupSig = "func setup(car: VehicleBody3D, track: Node, minimap: Node"
$c = ([regex]::Matches($modRaw, [regex]::Escape($setupSig))).Count
if ($c -lt 1) { $apiOk = $false }
$apiDetail += (" setup={0}" -f $c)
foreach ($n in @("run_enclosure", "run_reset", "run_out_of_bounds", "run_minimap",
    "run_reset_key", "run_escape", "run_pause")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
foreach ($n in @("_check_minimap_obstacles", "_menu_press_escape", "_cp")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
# 9 个注入 var：车/赛道/小地图/暂停菜单/障碍场/物理世界/SceneTree/physics_frame
# + 1 场景能力 Callable（mark_keep_alive）。本族不用 HUD（HUD 只在 lap 族的 reverse helper 用）。
$modVarHits = ([regex]::Matches($modRaw, '(?m)^var\s+')).Count
foreach ($n in @("_car", "_track", "_minimap", "_pause_menu", "_obstacle_field",
    "_world_3d", "_tree", "_physics_frame", "_mark_keep_alive")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^var\s+' + $n + '\b'))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
if ($modVarHits -ne 9) { $apiOk = $false }
$apiDetail += (" 模块级var总数={0}(期望9)" -f $modVarHits)
Add-R "模块含 setup + 7 公开入口 + 3 私有 helper + 恰 9 注入 var（零多余状态）" $apiOk ("实测：" + $apiDetail)

# ---------------------------------------------------------------- ⑥ 日志锚串在模块里（保 A/B 日志逐字一致）
# ⚠ 3 条是 run-all-checks.ps1 的**验收判据串**（enclosure/minimap/pause），必须原样在模块里。
$anchors = @(
    "[CHECK] 找不到 Track 节点",
    "[自检] 复位验收：8 个赛道外方位，逐个瞬移后调用 reset_to_track()",
    "[自检] 复位验收：%d/%d 成功%s",
    "[自检] 出界兜底：把车放到 %s（界外）静置，等待自动拉回…",
    "[自检] 出界兜底 ✘ 6 秒内没有被拉回",
    "[自检] 围墙封闭 ✔ 全周无缺口（含起终点缝）",
    "[自检] 围墙封闭 ✘ 有 %d 条射线打不到墙，弧长 %.1f ~ %.1f m",
    "[自检] 赛道下 StaticBody3D 物理节点数 = %d（应远小于路段数）",
    "[自检] R 键保护：车在中心线旁按 R → 位移 %.2fm  %s",
    "[自检] 复位无敌帧：刚复位 immune=%s（应 true）；%.1fs 后 immune=%s（应 false）  %s",
    "[自检] 小地图节点：Board=%s RoadRing=%s CarMarker=%s",
    "[自检]   障碍物标记：障碍 %d 个，小地图标记 %d 个",
    "[自检]   ✔ 全部 %d 个障碍标记都落在小地图相机视野内（半宽 %.0f 半高 %.0f）",
    "[自检] 原点复现：%d 帧内最大偏离中心线 %.2fm（护栏 %.1fm），最高速度 %.1f m/s  %s",
    "[自检] 暂停验收：ui_cancel 绑定 ESC = %s",
    "[自检] 暂停验收 ✔ ESC 暂停 → 选「重新开始」→ 新场景状态干净",
    "障碍物标记：障碍"
)
$anchorOk = $true
$anchorDetail = ""
foreach ($a in $anchors) {
    $c = ([regex]::Matches($modRaw, [regex]::Escape($a))).Count
    if ($c -lt 1) { $anchorOk = $false ; $anchorDetail += (" [缺失:{0}]" -f $a) }
}
Add-R ("{0} 条日志锚串全部在模块里（print 文案零改动，含 3 条验收判据串）" -f $anchors.Count) $anchorOk (
    $(if ($anchorOk) { ("{0}/{0} 命中" -f $anchors.Count) } else { $anchorDetail }))

# ---------------------------------------------------------------- ⑦ await 政策：恰 12 处、三种形态
$awaitInMod = ([regex]::Matches($modCode, '(?<![\.\w])await\s+')).Count
$pfHits = ([regex]::Matches($modCode, 'await\s+_physics_frame\.call\(\)')).Count
$treePf = ([regex]::Matches($modCode, 'await\s+_tree\.process_frame')).Count
$mmHits = ([regex]::Matches($modCode, 'await\s+_check_minimap_obstacles\(')).Count
$treeHits = ([regex]::Matches($modCode, 'get_tree\(\)|get_viewport\(\)')).Count
$awaitOk = ($awaitInMod -eq 12 -and $pfHits -eq 8 -and $treePf -eq 3 -and
    $mmHits -eq 1 -and $treeHits -eq 0)
Add-R "basic.gd 内 await 恰 12 处（8 physics_frame.call + 3 _tree.process_frame + 1 minimap_obstacles；get_tree=0）" $awaitOk (
    "await={0}/12 physics_frame={1}/8 tree.process_frame={2}/3 minimap_obs={3}/1 get_tree/viewport={4}/0" -f
    $awaitInMod, $pfHits, $treePf, $mmHits, $treeHits)

# ---------------------------------------------------------------- ⑧ 模块边界：不接触场景树
# 车/赛道/HUD/小地图/暂停菜单/障碍场/物理世界由 setup() 注入；模块里不该再有裸
# get_node / get_tree / get_viewport / get_world_3d（`_minimap.get_node_or_null("Board")`
# 之类的注入节点自身子节点不算，那是该节点的内部）。
$getNodeHits = ([regex]::Matches($modCode, '(?<![\.\w])get_node(_or_null)?\(')).Count
$worldHits = ([regex]::Matches($modCode, 'get_world_3d\(')).Count
$boundaryOk = ($getNodeHits -eq 0 -and $treeHits -eq 0 -and $worldHits -eq 0)
Add-R "模块无裸 get_node/get_tree/get_viewport/get_world_3d（引用全经 setup 注入）" $boundaryOk (
    "get_node={0} get_tree/viewport={1} get_world_3d={2}（期望 0/0/0）" -f $getNodeHits, $treeHits, $worldHits)

# ---------------------------------------------------------------- ⑨ 没被误迁：邻族与 lap 分支原样
$neighborOk = ($mainRaw -match 'const\s+REVERSE_CASES\s*:=\s*6') `
    -and ($mainCode -match '_checks_envphys\.setup\(') -and ($mainCode -match '_checks_ai\.setup\(') `
    -and ($mainCode -match '_checks_layout\.setup\(') -and ($mainCode -match '_checks_bench\.setup\(') `
    -and ($mainCode -match '_checks_lap\.setup\(') -and ($mainCode -match 'await\s+_checks_lap\.run_lap\(') `
    -and ($mainCode -match 'await\s+_checks_envphys\.run_') -and ($mainCode -match 'await\s+_checks_ai\.run_') `
    -and ($mainCode -match 'await\s+_checks_layout\.run\(')
Add-R "邻族（env_phys/bench/ai/layout/lap 接线 + REVERSE_CASES 常量）仍留在 main.gd" $neighborOk (
    $(if ($neighborOk) { "全部锚点都在（批次边界未越界）" } else { "有锚点丢失（越界删了）" }))

# 分发口：两道闸门用同一个正则提取分支名，这里镜像一遍 ——
# 7 个 BASIC 分支必须在、且分支总数仍是 24（防误删/误增分发项）。
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
$needBranches = @("enclosure", "reset", "oob", "minimap", "resetkey", "escape", "pause")
$missing = @($needBranches | Where-Object { $impl -notcontains $_ })
$dispatchOk = ($missing.Count -eq 0) -and ($impl.Count -eq 24)
Add-R "match _check: 分发口含 enclosure/reset/oob/minimap/resetkey/escape/pause 且共 24 项（闸门视图不变）" $dispatchOk (
    "分支数={0} 缺失={1}（期望 24 / 无）" -f $impl.Count, $(if ($missing.Count -eq 0) { "无" } else { $missing -join "," }))

# 受保护路径一律不许动：启动器脚本 / 无关游戏脚本 / 验收闸门 / 工程配置。
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
Add-R "basic.gd.uid 存在、13 位、与现存 uid 无碰撞" $uidOk $uidDetail

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
# 期望值按计划编辑逐段口算，再用 `git diff --numstat` 复核（迁移前 1522 行 / 34 func）。
# （迁移后准确值见运行日志的实测行。）
$wantLines = 659    # 迁移后准确值（1522 - 迁出 889 行 + 声明/接线/面包屑/新 helper 26 行）
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
$head = "================ SPLIT-CHECKS-BASIC-005a 结构校验（{0}）================" -f $stamp
$fail = @($results | Where-Object { $_.StartsWith("[FAIL]") })
$summary = "汇总：{0} 项断言，{1} 项失败" -f $results.Count, $fail.Count
$out = @($head) + $results + @("", $summary)
$logName = if ($OutName -ne "") { $OutName } else { "split-checks-basic-structcheck.log" }
$logFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) $logName
if ($MyInvocation.MyCommand.Path) {
    $out | Out-File -FilePath $logFile -Encoding utf8
}
$out | ForEach-Object { Write-Host $_ }
if ($fail.Count -gt 0) { exit 1 }
exit 0
