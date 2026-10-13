# SPLIT-CHECKS-AI-003 结构校验（TDD：先红后绿）。
#
# 为什么必须有它：本次是"纯迁移"，最大的风险不是逻辑改错，而是**迁移不完整** ——
# 漏搬一个常量/函数、调用点漏改、把不该搬的（ADR-001 三个永久居民 / match 分派表 /
# 邻族 pause-flip-reverse-escape 等）顺手扫进来、或者把注入写反（模块去
# get_node / 反向持有场景 / await 多一拍）。这些都不会让 parse 报错，只会在 A/B 里
# 表现为"行为没变但结构不对"。
# 所以把"迁完后的结构事实"写成可执行断言，动手前跑红、迁完跑绿。
#
# 与 split-checks-bench-structcheck.ps1 的差异（AI 族的四个特有事实）：
#   ① **本族有 5 个入口、0 个内部辅助函数**（bench 是 2 入口 + 6 内部）；
#      残留 token 表因此是 5 函数 + 9 常量 = 14；
#   ② **await 政策是"恰 8 处、两种形态"**：6 处 physics_frame（注入 Callable）
#      + 2 处 `_sample_physics_ms.call(...)`（checks 族共用采样器，注入 Callable，
#      见 ai.gd 文件头决策 ③ —— 这是本族与 bench 最大的不同：bench 不 await main 的方法）；
#   ③ **注入面更宽**：车/赛道/障碍场/物理世界 + 对手生成模块实例 + 自动驾驶模块实例
#      + 2 个 Callable。模块级 var 恰 10 个（8 注入 + 2 只读代理），多一个就是有人
#      往模块里塞了隐藏状态；
#   ④ **.uid 断言延续 bench 的"13 位 + 与现存无碰撞"**（本批现存 28 个）。
#
# 用法：pwsh -File godot-logs\split-checks-ai-structcheck.ps1 [-OutName <日志名>]
# 退出码：0 = 全绿；1 = 有断言失败（红）。
param(
    [string]$Root = "",
    [string]$OutName = ""
)
$ErrorActionPreference = "Continue"
if ($Root -eq "") { $Root = Split-Path -Parent $PSScriptRoot }   # godot-logs 的父目录 = git 根
$Proj = Join-Path $Root "godot-racer"
$Main = Join-Path $Proj "scenes\main.gd"
$Mod = Join-Path $Proj "scripts\checks\ai.gd"
$ModUid = Join-Path $Proj "scripts\checks\ai.gd.uid"

$results = New-Object System.Collections.Generic.List[string]
function Add-R([string]$name, [bool]$ok, [string]$detail) {
    $tag = if ($ok) { "PASS" } else { "FAIL" }
    $results.Add(("[{0}] {1} -- {2}" -f $tag, $name, $detail))
}

# 去掉整行注释后再匹配，避免把文件头决策记录里点名的符号当成真实代码引用
# （先例：split-opponent / split-screenshot / split-checks-bench 同款去噪）。
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
Add-R "scripts/checks/ai.gd 存在" $exists $(if ($exists) { "scripts/checks/ai.gd" } else { "文件不存在（尚未创建）" })

$extendsOk = $modRaw -match '(?m)^extends\s+RefCounted\s*$'
$classNameHits = ([regex]::Matches($modRaw, '(?m)^class_name\s+')).Count
Add-R "模块 extends RefCounted 且无 class_name（§2.4 铁律）" ($extendsOk -and $classNameHits -eq 0) (
    "extends RefCounted={0} class_name 定义数={1}（期望 True/0）" -f $extendsOk, $classNameHits)

# ---------------------------------------------------------------- ② main.gd 代码零残留
# 迁完后这些 token 在 main.gd 的**代码**里一次都不该出现（breadcrumb 注释按设计留守，
# 见文件头 —— 判据跑在去注释代码上，注释既不豁免也不误伤）。
# ⚠ `_check_ai_start` 等不是 `_checks_ai`（新模块实例名）的子串，不会误命中；
#   `run_ai_start` 也不含 `_check_ai_start` 子串，同理安全。
$residTokens = @(
    # 5 个函数
    "_check_opponents", "_check_ai_diag", "_check_avoid", "_check_obstacles", "_check_ai_start",
    # 9 个随迁常量（闸门未登记、非 ADR-001 永久居民）
    "AI_RECOVER_WARN_SEC", "AI_TARGET_MIN_KMH", "AI_TARGET_PINNED_PCT", "AI_TARGET_PINNED_KMH",
    "AI_TARGET_RED_MAX_KMH", "AI_TARGET_NEAR_PHYS_FRAC", "AI_TARGET_NEAR_CAP_PCT",
    "AI_TARGET_NEAR_CAP_FRAC", "AI_BEND_GUARD_SEG"
)
$residTotal = 0
$residDetail = ""
foreach ($n in $residTokens) {
    $c = ([regex]::Matches($mainCode, [regex]::Escape($n))).Count
    if ($c -gt 0) { $residDetail += (" {0}={1}" -f $n, $c) }
    $residTotal += $c
}
Add-R "main.gd 代码零残留（5 函数 + 9 常量，共 14 个 token）" ($residTotal -eq 0) (
    "残留总数 = {0}{1}" -f $residTotal, $residDetail)

# ---------------------------------------------------------------- ③ main.gd 侧接线恰各一处
$constHits = ([regex]::Matches($mainRaw, '(?m)^const\s+ChecksAi\s+:=\s*preload\("res://scripts/checks/ai\.gd"\)')).Count
$varHits = ([regex]::Matches($mainRaw, '(?m)^var\s+_checks_ai\s+:=\s*ChecksAi\.new\(\)')).Count
$setupHits = ([regex]::Matches($mainCode, '_checks_ai\.setup\(')).Count
$runOpp = ([regex]::Matches($mainCode, 'await\s+_checks_ai\.run_opponents\(')).Count
$runDiag = ([regex]::Matches($mainCode, 'await\s+_checks_ai\.run_ai_diag\(')).Count
$runAvoid = ([regex]::Matches($mainCode, 'await\s+_checks_ai\.run_avoid\(')).Count
$runObs = ([regex]::Matches($mainCode, 'await\s+_checks_ai\.run_obstacles\(')).Count
$runStart = ([regex]::Matches($mainCode, 'await\s+_checks_ai\.run_ai_start\(')).Count
$wireOk = ($constHits -eq 1 -and $varHits -eq 1 -and $setupHits -eq 1 -and
    $runOpp -eq 1 -and $runDiag -eq 1 -and $runAvoid -eq 1 -and $runObs -eq 1 -and $runStart -eq 1)
Add-R "main.gd 接线恰各一处（const/var/setup + 5 个 run_* 分派）" $wireOk (
    "const={0}/1 var={1}/1 setup={2}/1 opp={3}/1 diag={4}/1 avoid={5}/1 obs={6}/1 start={7}/1" -f
    $constHits, $varHits, $setupHits, $runOpp, $runDiag, $runAvoid, $runObs, $runStart)

# ---------------------------------------------------------------- ④ 永久居民不许搬（闸门约束）
# check-docs.ps1 L59 正则 `const\s+<NAME>\s*:=\s*(\d+)` 从 main.gd 原文取值，
# check-readme.ps1 直接解析 `match _check:` 块分支名 —— 搬走即闸门假红。ADR-001 明文禁止。
$elevConst = $mainRaw -match '(?m)^const\s+LAYOUT_ELEV_CASES\s*:=\s*10\s*$'
$racingConst = $mainRaw -match '(?m)^const\s+LAYOUT_RACING_CASES\s*:=\s*6\s*$'
$revConst = $mainRaw -match '(?m)^const\s+REVERSE_CASES\s*:=\s*6\s*$'
$matchTable = $mainRaw -match '(?m)^\s*match\s+_check:'
Add-R "ADR-001 永久居民仍在 main.gd（三 CASES 常量 + match _check: 分派表）" (
    $elevConst -and $racingConst -and $revConst -and $matchTable) (
    "ELEV={0} RACING={1} REVERSE={2} match表={3}（期望全 True）" -f $elevConst, $racingConst, $revConst, $matchTable)

# ---------------------------------------------------------------- ⑤ 模块 API + 5 入口 + 9 常量 + 恰 10 var
$apiOk = $true
$apiDetail = ""
foreach ($sig in @("func setup(", 'const Autopilot := preload("res://scripts/autopilot.gd")')) {
    $c = ([regex]::Matches($modRaw, [regex]::Escape($sig))).Count
    if ($c -lt 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $sig, $c)
}
# 5 个公开入口逐个点名（防漏搬：structcheck 的全部意义就在这）
foreach ($n in @("run_opponents", "run_ai_diag", "run_avoid", "run_obstacles", "run_ai_start")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
# 9 个随迁常量逐个点名
foreach ($n in @("AI_RECOVER_WARN_SEC", "AI_TARGET_MIN_KMH", "AI_TARGET_PINNED_PCT", "AI_TARGET_PINNED_KMH",
    "AI_TARGET_RED_MAX_KMH", "AI_TARGET_NEAR_PHYS_FRAC", "AI_TARGET_NEAR_CAP_PCT",
    "AI_TARGET_NEAR_CAP_FRAC", "AI_BEND_GUARD_SEG")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^const\s+' + $n + '\s*:='))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}定义={1}" -f $n, $c)
}
# 状态：本族原实现零模块级状态 ⇒ 迁移后只允许 10 个 var（8 注入 + 2 只读代理）。
# 多一个 var = 有人往模块里加了隐藏状态。
$modVarHits = ([regex]::Matches($modRaw, '(?m)^var\s+')).Count
foreach ($n in @("_car", "_track", "_obstacle_field", "_opponent_spawner", "_autopilot",
    "_world_3d", "_physics_frame", "_sample_physics_ms", "_opponents", "_ai_started")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^var\s+' + $n + '\b'))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
if ($modVarHits -ne 10) { $apiOk = $false }
$apiDetail += (" 模块级var总数={0}(期望10)" -f $modVarHits)
Add-R "模块含 setup + 5 公开入口 + 9 常量 + 恰 10 注入/代理 var（零多余状态）" $apiOk ("实测：" + $apiDetail)

# ---------------------------------------------------------------- ⑥ 日志锚串在模块里（保 A/B 日志逐字一致）
# 纯迁移的 A/B 判据是"判定行/✔✘ 计数逐字相同"；这些锚串是日志的主体，
# 少任何一条都说明迁移时改坏了 print 文案（A/B 会红，但那里已太晚）。
# ⚠ 其中 5 条是 run-all-checks.ps1 的**验收判据串**（按 check 名逐项），必须原样在模块里。
$anchors = @(
    "[自检] 对手验收：%d 台，目标各自跑完",
    "[自检] 对手用时 %.1f 秒（%d 帧），最小完成圈数 = %d",
    "[自检] 对手验收通过判据：每台 ≥1 圈、零自救、未出界",
    "[自检] 物理开销请单独用 --check=phys 测",
    "[自检] 对手验收 ✔ 全部对手都能独立跑完 ≥1 圈、零自救、未出界",
    "[自检] 对手验收 ✘ 见上方 ✘ 行",
    "[自检] AI 诊断：本关「%s」没有对手，跳过 ⊘",
    "[自检] AI 诊断开始（走真实游玩路径，不显式发车）",
    "[自检]   抢跑检查：玩家未动时 armed=%s",
    "[自检] AI 诊断结果：",
    "[自检] AI 诊断 ✔ 不抢跑、不发车后停顿、不依赖自救",
    "[自检] AI 诊断 ✘ 见上方 ✘ 行（把这段日志连同速度曲线一起看）",
    "[自检] AI 目标速度 vs 物理上限（任务 15 判据，逐 2.5s 采样）：",
    "[自检] AI 目标速度判定 ✔ 目标已达最高限速量级、且从未超过物理上限",
    "[自检] AI 目标速度判定 ✘ 见上方 ✘ 行（这一组就是任务 15 的需求指标）",
    "[自检]   发车后最终目标：最大 %.1f km/h（出现在 t=%.1fs，当时物理上限 %.1f）；< %.0f km/h 的帧占 %d/%d = %.1f%%",
    "[自检]   贴着限制跑的帧：策略侧 ≥ 极速×85%% = %.1f%%（%d/%d）；地面侧 ≥ 物理上限×85%% = %.1f%%（%d/%d）；取较大者 %.1f%%",
    "[自检]   （辅助读数）最终目标 ≥ 物理上限 × %.0f%% 的帧：%d/%d = %.1f%%",
    "[自检] 本关没有对手，避让验收 ⊘ 跳过",
    "[自检] 避让验收：把玩家当成路障摆在 AI 车道（横向 %+.2fm）前方，看 AI 会不会绕开",
    "[自检]   玩家路障已就位：弧长 %.1f（AI 前方 28m），横向 %+.2fm",
    "[自检] 避让验收 ✔ AI 会主动绕开玩家，且不接触",
    "[自检] 避让验收 ✘ 见上方 ✘ 行",
    "[自检] 本关「%s」obstacle_count=%d dynamic=%d，本来就没有障碍，验收 ⊘ 跳过",
    "[自检] 障碍物验收：共 %d 个（动态 %d 个）；路面半宽 %.2fm，护栏 %.2fm",
    "[自检]   静态障碍物理节点数 = %d（必须为 1；动态路障是 AnimatableBody3D，不计）",
    "[自检] 障碍物验收 ✔ 位置/碰撞/通行缝隙/合并节点 全部通过",
    "[自检] 障碍物验收 ✘ 见上方 ✘ 行",
    "[自检] 本关没有对手，并排发车验收 ⊘ 跳过",
    "[自检] 并排发车验收：先让玩家静止 %.1f 秒，看对手是否原地等待",
    "[自检] 并排发车验收 ✔ 对手原地等待 → 玩家起步 → 对手同步发动",
    "[自检] 并排发车验收 ✘ 见上方 ✘ 行",
    "[CHECK] 找不到 Track 节点",
    "[自检]   t=%4.1fs  AI armed=%s 速度=%5.1f",
    "[自检]   退化向量实测（arc=%.1fm）"
)
$anchorOk = $true
$anchorDetail = ""
foreach ($a in $anchors) {
    $c = ([regex]::Matches($modRaw, [regex]::Escape($a))).Count
    if ($c -lt 1) { $anchorOk = $false ; $anchorDetail += (" [缺失:{0}]" -f $a) }
}
Add-R "35 条日志锚串全部在模块里（print 文案零改动，含 5 条验收判据串）" $anchorOk (
    $(if ($anchorOk) { "35/35 命中" } else { $anchorDetail }))

# ---------------------------------------------------------------- ⑦ await 政策：恰 8 处、两种形态
# 本族原有真实 await 8 处（ai.gd 文件头决策 ③④）：
#   · 6 处 `await get_tree().physics_frame`（run_opponents 1 / run_ai_diag 1 /
#     run_avoid 2 / run_ai_start 2）→ 注入 Callable 后为 `await _physics_frame.call()`；
#   · 2 处 `await _sample_physics_ms(...)`（都在 run_opponents）→
#     `await _sample_physics_ms.call(...)`，checks 族共用采样器注入 Callable
#     （⚠ 这是本族与 bench 的关键差别：bench 不 await main 的方法）。
# main.gd 分发口那 5 个 `await _checks_ai.run_*()` 留在 main 自己那层协程 ——
# 协程深度与迁移前一致（opponent_spawner 实证：多一层协程 = physics_frame 恢复时机差
# 1 物理帧 = 25856 行日志发散）。
$awaitInMod = ([regex]::Matches($modCode, '(?<![\.\w])await\s+')).Count
$pfHits = ([regex]::Matches($modCode, 'await\s+_physics_frame\.call\(\)')).Count
$smHits = ([regex]::Matches($modCode, 'await\s+_sample_physics_ms\.call\(')).Count
$treeHits = ([regex]::Matches($modCode, 'get_tree\(\)|get_viewport\(\)')).Count
$awaitOk = ($awaitInMod -eq 8 -and $pfHits -eq 6 -and $smHits -eq 2 -and $treeHits -eq 0)
Add-R "ai.gd 内 await 恰 8 处（6 physics_frame.call + 2 _sample_physics_ms.call；get_tree=0）" $awaitOk (
    "await={0}/8 physics_frame={1}/6 sample={2}/2 get_tree/viewport={3}/0" -f
    $awaitInMod, $pfHits, $smHits, $treeHits)

# ---------------------------------------------------------------- ⑧ 模块边界：不接触场景树
# 车/赛道/障碍场/物理世界由 setup() 注入；模块里不该再有 get_node / get_tree / get_viewport。
$getNodeHits = ([regex]::Matches($modCode, '(?<![\.\w])get_node(_or_null)?\(')).Count
$worldHits = ([regex]::Matches($modCode, 'get_world_3d\(')).Count
$boundaryOk = ($getNodeHits -eq 0 -and $treeHits -eq 0 -and $worldHits -eq 0)
Add-R "模块无 get_node/get_tree/get_viewport/get_world_3d（全部经 setup 注入）" $boundaryOk (
    "get_node={0} get_tree/viewport={1} get_world_3d={2}（期望 0/0/0）" -f $getNodeHits, $treeHits, $worldHits)

# ---------------------------------------------------------------- ⑨ 没被误迁：邻族与 layout/bench 接线原样
$neighborOk = ($mainRaw -match 'func\s+_check_reverse\s*\(') -and ($mainRaw -match 'const\s+REVERSE_CASES\s*:=\s*6') `
    -and ($mainRaw -match 'func\s+_check_escape\s*\(') -and ($mainRaw -match 'func\s+_check_flip\s*\(') `
    -and ($mainRaw -match 'func\s+_check_friction\s*\(') -and ($mainRaw -match 'func\s+_check_phys\s*\(') `
    -and ($mainRaw -match 'func\s+_check_pause\s*\(') -and ($mainRaw -match 'func\s+_check_lap\s*\(') `
    -and ($mainRaw -match 'func\s+_sample_physics_ms\s*\(') -and ($mainRaw -match 'func\s+_avg_physics_ms\s*\(') `
    -and ($mainCode -match '_checks_layout\.setup\(') -and ($mainCode -match 'await\s+_checks_layout\.run\(') `
    -and ($mainCode -match '_checks_bench\.setup\(') -and ($mainCode -match 'await\s+_checks_bench\.run_steerbench\(')
Add-R "邻族（reverse/escape/flip/friction/phys/pause/lap）与 layout/bench 接线仍留在 main.gd" $neighborOk (
    $(if ($neighborOk) { "14 个锚点都在（批次边界未越界）" } else { "有锚点丢失（越界删了）" }))

# 分发口：两道闸门用同一个正则提取分支名，这里镜像一遍 ——
# 5 个 AI 分支必须在、且分支总数仍是 26（防误删/误增分发项）。
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
$needBranches = @("opponents", "aidiag", "avoid", "obstacles", "aistart")
$missing = @($needBranches | Where-Object { $impl -notcontains $_ })
$dispatchOk = ($missing.Count -eq 0) -and ($impl.Count -eq 26)
Add-R "match _check: 分发口含 opponents/aidiag/avoid/obstacles/aistart 且共 26 项（闸门视图不变）" $dispatchOk (
    "分支数={0} 缺失={1}（期望 26 / 无）" -f $impl.Count, $(if ($missing.Count -eq 0) { "无" } else { $missing -join "," }))

# 受保护路径一律不许动：启动器脚本 / 无关游戏脚本 / 验收闸门 / 工程配置。
# 用 git status 全量比对（不逐条传中文路径，避免参数编码把结论搞假）。
# ⚠ 非 ASCII 路径在 git 输出里会被转义成 `\345` 八进制；两种形态都匹配（bench 批修订）。
$protected = @("04-Godot启动器/", "scripts/menu.gd", "scripts/vehicle.gd", "scripts/ai_opponent.gd",
    "scripts/racing_line.gd", "scripts/track_layout.gd", "project.godot",
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

# ---------------------------------------------------------------- ⑩ .uid 文件在盘、13 位、与现存无碰撞
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
Add-R "ai.gd.uid 存在、13 位、与现存 uid 无碰撞" $uidOk $uidDetail

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
# 期望值按计划编辑逐段口算，再用 `git diff --numstat` 复核（迁移前 3346 行 / 58 func）：
#   删除 793 行（四处迁出块，均只删"文档块 + 函数实体"，不删其尾部 2 空行）：
#     · AI_* 常量块 L635-691 = 57；
#     · _check_opponents 文档+实体 L1142-1216 = 75；
#     · _check_ai_diag 文档+实体 L1315-1688 = 374；
#     · avoid/obstacles/aistart 三连 L1829-2115 = 287（三块文档+实体连续，中间空行一起删）。
#   插入 24 行：
#     · 模块声明块 11（前导空行 + 8 注释 + const + var）；
#     · setup 接线 5（3 注释 + 2 行调用）；
#     · 四处 breadcrumb 注释 8（各 2 行）。
#   3346 - 793 + 24 = 2577；func：-5（本族 5 个函数全部外迁，main 不新增函数）= 53。
#   git diff --numstat 复核：+29/-798（+29 = 24 插入 + 5 行 dispatch 改动；
#   -798 = 793 + 5 行 dispatch 改动）→ 净 -769 = 2577-3346 ✔
$wantLines = 2577
$wantFuncs = 53
Add-R "main.gd 规模 = 2577 行 / 53 func（迁移后准确值）" ($mainLines -eq $wantLines -and $mainFuncs -eq $wantFuncs) (
    "实测 行={0}/func={1}（期望 {2}/{3}；迁移前 3346/58）" -f $mainLines, $mainFuncs, $wantLines, $wantFuncs)

# ---------------------------------------------------------------- 输出
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$head = "================ SPLIT-CHECKS-AI-003 结构校验（{0}）================" -f $stamp
$fail = @($results | Where-Object { $_.StartsWith("[FAIL]") })
$summary = "汇总：{0} 项断言，{1} 项失败" -f $results.Count, $fail.Count
$out = @($head) + $results + @("", $summary)
$logName = if ($OutName -ne "") { $OutName } else { "split-checks-ai-structcheck.log" }
$logFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) $logName
if ($MyInvocation.MyCommand.Path) {
    $out | Out-File -FilePath $logFile -Encoding utf8
}
$out | ForEach-Object { Write-Host $_ }
if ($fail.Count -gt 0) { exit 1 }
exit 0
