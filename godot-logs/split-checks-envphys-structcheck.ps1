# SPLIT-CHECKS-ENVPHYS-004 结构校验（TDD：先红后绿）。
#
# 为什么必须有它：本次是"纯迁移"，最大的风险不是逻辑改错，而是**迁移不完整** ——
# 漏搬一个常量/helper、调用点漏改、把不该搬的（ADR-001 三个永久居民 / match 分派表 /
# 邻族 reset-lap-reverse-escape-minimap 等）顺手扫进来、或者把注入写反（模块去
# get_node / 反向持有场景 / await 多一拍）。这些都不会让 parse 报错，只会在 A/B 里
# 表现为"行为没变但结构不对"。
# 所以把"迁完后的结构事实"写成可执行断言，动手前跑红、迁完跑绿。
#
# 与 split-checks-ai-structcheck.ps1 的差异（ENVPHYS 族的四个特有事实）：
#   ① **本族 7 个公开入口 + 10 个私有 helper + setup**（ai 是 5 入口 0 helper）：
#      public = run_wallslide / run_stuck / probe_blocker / run_phys / run_weather /
#      run_friction / run_flip；private = _visual_lateral_extent / _luminance /
#      _friction_probe / _flip_state / _flip_case_inverted / _flip_case_belly /
#      _flip_case_hover / _flip_hunt_trial / _report_hunt_finding / _flip_case_hunt；
#      残留 token 表 = 7 函数 + 6 常量 = 13；
#   ② **await 政策是"恰 29 处、四种形态"**：16 处 `await _physics_frame.call()`
#      + 1 处 `await _friction_probe(...)` + 9 处 `await _flip_case_*()` +
#      3 处 `await _flip_hunt_trial(...)`（全部是**本族内部**的 await，不 await main 的方法）；
#   ③ **注入面更宽**：车/赛道/世界环境/物理世界 + 对手生成模块实例 + 1 个 Callable
#      + 2 个模块级状态；模块级 var 恰 9 个，多一个就是有人往模块里塞了隐藏状态；
#   ④ **.uid 断言延续"13 位 + 与现存无碰撞"**。
#
# 用法：pwsh -File godot-logs\split-checks-envphys-structcheck.ps1 [-OutName <日志名>]
# 退出码：0 = 全绿；1 = 有断言失败（红）。
param(
    [string]$Root = "",
    [string]$OutName = ""
)
$ErrorActionPreference = "Continue"
if ($Root -eq "") { $Root = Split-Path -Parent $PSScriptRoot }   # godot-logs 的父目录 = git 根
$Proj = Join-Path $Root "godot-racer"
$Main = Join-Path $Proj "scenes\main.gd"
$Mod = Join-Path $Proj "scripts\checks\env_phys.gd"
$ModUid = Join-Path $Proj "scripts\checks\env_phys.gd.uid"

$results = New-Object System.Collections.Generic.List[string]
function Add-R([string]$name, [bool]$ok, [string]$detail) {
    $tag = if ($ok) { "PASS" } else { "FAIL" }
    $results.Add(("[{0}] {1} -- {2}" -f $tag, $name, $detail))
}

# 去掉整行注释后再匹配，避免把文件头决策记录里点名的符号当成真实代码引用
# （先例：split-opponent / split-screenshot / split-checks-bench / split-checks-ai 同款去噪）。
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
Add-R "scripts/checks/env_phys.gd 存在" $exists $(if ($exists) { "scripts/checks/env_phys.gd" } else { "文件不存在（尚未创建）" })

$extendsOk = $modRaw -match '(?m)^extends\s+RefCounted\s*$'
$classNameHits = ([regex]::Matches($modRaw, '(?m)^class_name\s+')).Count
Add-R "模块 extends RefCounted 且无 class_name（§2.4 铁律）" ($extendsOk -and $classNameHits -eq 0) (
    "extends RefCounted={0} class_name 定义数={1}（期望 True/0）" -f $extendsOk, $classNameHits)

# ---------------------------------------------------------------- ② main.gd 代码零残留
# 迁完后这些 token 在 main.gd 的**代码**里一次都不该出现（breadcrumb 注释按设计留守，
# 见文件头 —— 判据跑在去注释代码上，注释既不豁免也不误伤）。
# ⚠ `_checks_envphys` 不含 `_check_phys` / `_check_stuck` 等子串（中间隔着 `s_envphys`），
#   不会误命中；`run_stuck` / `probe_blocker` 也不含 `_check_stuck` / `_probe_blocker` 子串。
$residTokens = @(
    # 7 个函数
    "_check_wallslide", "_check_stuck", "_probe_blocker", "_check_phys",
    "_check_weather", "_check_friction", "_check_flip",
    # 6 个随迁常量（闸门未登记、非 ADR-001 永久居民）
    "MIN_WEATHER_CONTRAST", "BELLY_TEST_KMH", "BELLY_TEST_SECONDS",
    "BELLY_ONSET", "BELLY_RECOVER", "FLIP_UPRIGHT_ANGLE"
)
$residTotal = 0
$residDetail = ""
foreach ($n in $residTokens) {
    $c = ([regex]::Matches($mainCode, [regex]::Escape($n))).Count
    if ($c -gt 0) { $residDetail += (" {0}={1}" -f $n, $c) }
    $residTotal += $c
}
Add-R "main.gd 代码零残留（7 函数 + 6 常量，共 13 个 token）" ($residTotal -eq 0) (
    "残留总数 = {0}{1}" -f $residTotal, $residDetail)

# ---------------------------------------------------------------- ③ main.gd 侧接线恰各一处
$constHits = ([regex]::Matches($mainRaw, '(?m)^const\s+ChecksEnvPhys\s*:=\s*preload\("res://scripts/checks/env_phys\.gd"\)')).Count
$varHits = ([regex]::Matches($mainRaw, '(?m)^var\s+_checks_envphys\s*:=\s*ChecksEnvPhys\.new\(\)')).Count
$setupHits = ([regex]::Matches($mainCode, '_checks_envphys\.setup\(')).Count
$runWall = ([regex]::Matches($mainCode, 'await\s+_checks_envphys\.run_wallslide\(')).Count
$runStuck = ([regex]::Matches($mainCode, 'await\s+_checks_envphys\.run_stuck\(')).Count
$runPhys = ([regex]::Matches($mainCode, 'await\s+_checks_envphys\.run_phys\(')).Count
$runWeather = ([regex]::Matches($mainCode, 'await\s+_checks_envphys\.run_weather\(')).Count
$runFric = ([regex]::Matches($mainCode, 'await\s+_checks_envphys\.run_friction\(')).Count
$runFlip = ([regex]::Matches($mainCode, 'await\s+_checks_envphys\.run_flip\(')).Count
$runProbe = ([regex]::Matches($mainCode, '(?<!await\s)_checks_envphys\.probe_blocker\(')).Count
$wireOk = ($constHits -eq 1 -and $varHits -eq 1 -and $setupHits -eq 1 -and
    $runWall -eq 1 -and $runStuck -eq 1 -and $runPhys -eq 1 -and $runWeather -eq 1 -and
    $runFric -eq 1 -and $runFlip -eq 1 -and $runProbe -eq 1)
Add-R "main.gd 接线恰各一处（const/var/setup + 6 run_* 分派 + probe_blocker 调用）" $wireOk (
    "const={0}/1 var={1}/1 setup={2}/1 wall={3}/1 stuck={4}/1 phys={5}/1 weather={6}/1 fric={7}/1 flip={8}/1 probe={9}/1" -f
    $constHits, $varHits, $setupHits, $runWall, $runStuck, $runPhys, $runWeather, $runFric, $runFlip, $runProbe)

# ---------------------------------------------------------------- ④ 永久居民不许搬（闸门约束）
# check-docs.ps1 从 main.gd 原文取三个 CASES 常量；check-readme.ps1 直接解析
# `match _check:` 块分支名 —— 搬走即闸门假红。ADR-001 明文禁止。
$elevConst = $mainRaw -match '(?m)^const\s+LAYOUT_ELEV_CASES\s*:=\s*10\s*$'
$racingConst = $mainRaw -match '(?m)^const\s+LAYOUT_RACING_CASES\s*:=\s*6\s*$'
$revConst = $mainRaw -match '(?m)^const\s+REVERSE_CASES\s*:=\s*6\s*$'
$matchTable = $mainRaw -match '(?m)^\s*match\s+_check:'
Add-R "ADR-001 永久居民仍在 main.gd（三 CASES 常量 + match _check: 分派表）" (
    $elevConst -and $racingConst -and $revConst -and $matchTable) (
    "ELEV={0} RACING={1} REVERSE={2} match表={3}（期望全 True）" -f $elevConst, $racingConst, $revConst, $matchTable)

# ---------------------------------------------------------------- ⑤ 模块 API + 7 入口 + 10 helper + 6 常量 + 恰 9 var
$apiOk = $true
$apiDetail = ""
foreach ($sig in @("func setup(car: VehicleBody3D",
                   'const Autopilot := preload("res://scripts/autopilot.gd")')) {
    $c = ([regex]::Matches($modRaw, [regex]::Escape($sig))).Count
    if ($c -lt 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $sig, $c)
}
# 7 个公开入口逐个点名（防漏搬：structcheck 的全部意义就在这）
foreach ($n in @("run_wallslide", "run_stuck", "probe_blocker", "run_phys",
    "run_weather", "run_friction", "run_flip")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
# 10 个私有 helper 逐个点名（改名 / 漏搬都会被这行抓住）
foreach ($n in @("_visual_lateral_extent", "_luminance", "_friction_probe", "_flip_state",
    "_flip_case_inverted", "_flip_case_belly", "_flip_case_hover", "_flip_hunt_trial",
    "_report_hunt_finding", "_flip_case_hunt")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
# 6 个随迁常量逐个点名
foreach ($n in @("MIN_WEATHER_CONTRAST", "BELLY_TEST_KMH", "BELLY_TEST_SECONDS",
    "BELLY_ONSET", "BELLY_RECOVER", "FLIP_UPRIGHT_ANGLE")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^const\s+' + $n + '\s*:='))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}定义={1}" -f $n, $c)
}
# 状态：本族原实现 5 注入 + 1 只读代理 + 1 Callable + 2 状态 = 9 个 var。
# 多一个 var = 有人往模块里加了隐藏状态。
$modVarHits = ([regex]::Matches($modRaw, '(?m)^var\s+')).Count
foreach ($n in @("_car", "_track", "_world_environment", "_world_3d", "_opponent_spawner",
    "_opponents", "_physics_frame", "_flip_reproduced", "_flip_fails")) {
    $c = ([regex]::Matches($modRaw, ('(?m)^var\s+' + $n + '\b'))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $n, $c)
}
if ($modVarHits -ne 9) { $apiOk = $false }
$apiDetail += (" 模块级var总数={0}(期望9)" -f $modVarHits)
Add-R "模块含 setup + 7 公开入口 + 10 私有 helper + 6 常量 + 恰 9 注入/状态 var（零多余状态）" $apiOk ("实测：" + $apiDetail)

# ---------------------------------------------------------------- ⑥ 日志锚串在模块里（保 A/B 日志逐字一致）
# 纯迁移的 A/B 判据是"判定行/✔✘ 计数逐字相同"；这些锚串是日志的主体，
# 少任何一条都说明迁移时改坏了 print 文案（A/B 会红，但那里已太晚）。
# ⚠ 其中 5 条是 run-all-checks.ps1 的**验收判据串**（wallslide/flip/weather/friction/phys），必须原样在模块里。
$anchors = @(
    "[CHECK] 找不到 Track 节点",
    "[自检] 卡墙验收：3 个角度 × 内外两侧，全油门怼墙 4 秒，要求结束时速度 > 12 km/h",
    "[自检]   %s侧 %2.0f° 怼墙：结束速度 %5.1f km/h 最低 %5.1f 偏离 %.2fm 视觉最远 %.2fm（探出墙面 %+.2fm）  %s",
    "[自检]   车尾穿模检查 ✔ 全程视觉最远 %.2fm，探出墙面 %.2fm < 墙厚 %.2fm（藏在墙体里）",
    "[自检] 卡墙验收：%d/%d 通过%s",
    "[自检] ① 墙体实测（中心线为 0，正值=外侧/负值=内侧）",
    "[自检] ② 贴墙推进测试（起点区弧长 0 附近，朝内墙推 2 秒）",
    "[自检] ③ 判定：若②里出现'车外缘越过内墙'且速度接近 0，就是卡墙；",
    "[自检]       [卡住取证] %s：最近实体 %.2fm（%s）",
    "[自检] 物理开销：关卡=%s 对手=%d 台 玩家=1 台（目标 %d Hz）",
    "[自检]   物理开销 ✔ 稳定维持 %d Hz（未掉帧）",
    "[自检]   ✘ 物理步频掉到 %.1f Hz，低于目标 %d Hz —— 物理确实吃不消",
    "[自检] 天气验收：本关天气=%s（%s），期望粒子=%s",
    "[自检]   对比度：粒子亮度 %.2f vs 天空亮度 %.2f → 差 %.2f（要求 ≥ %.2f）",
    "[自检] 天气验收 ✔ 粒子和环境配置符合本关天气，且未拖垮帧率",
    "[自检] 天气验收 ✘ 见上方 ✘ 行",
    "[自检] 抓地力验收：扫描倍率 %s（本关配置 ×%.2f）",
    "[自检] 抓地力验收 ✔ 倍率确实进了物理：倍率越低侧向加速度越小，且梯度可感知",
    "[自检] 抓地力验收 ✘ 倍率没有单调影响物理，链路可能断了",
    "[自检]   用例 A 底朝天：%.2fs 扶正且四轮接地 ✔",
    "[自检]   用例 B 合成腹部贴地 ✔",
    "[自检]   用例 D 自动搜复现：%d 组（角度 × 速度）怼护栏 + 2 组高速翻转 + 4 组高空砸地，每组最多 %.0fs",
    "[自检] 翻车恢复验收：起点弧长 %.0fm（赛道全长 %.0fm）",
    "[自检] 翻车恢复验收 ✔ 用例 A/B 全过；用例 C 复现持续贴地 %d/6 个（0 个只说明合成姿态造不出持续贴地，不代表没问题）",
    "[自检] 翻车恢复验收 ✘ 失败 %d 项（用例 C 复现 %d/6 个）"
)
$anchorOk = $true
$anchorDetail = ""
foreach ($a in $anchors) {
    $c = ([regex]::Matches($modRaw, [regex]::Escape($a))).Count
    if ($c -lt 1) { $anchorOk = $false ; $anchorDetail += (" [缺失:{0}]" -f $a) }
}
Add-R ("{0} 条日志锚串全部在模块里（print 文案零改动，含 5 条验收判据串）" -f $anchors.Count) $anchorOk (
    $(if ($anchorOk) { ("{0}/{0} 命中" -f $anchors.Count) } else { $anchorDetail }))

# ---------------------------------------------------------------- ⑦ await 政策：恰 29 处、四种形态
# 本族原有真实 await 29 处（env_phys.gd 文件头决策 ③）：
#   · 16 处 `await get_tree().physics_frame` → 注入 Callable 后 `await _physics_frame.call()`；
#   · 1 处 `await _friction_probe(...)`（run_friction 内，本族私有探针，保留原形）；
#   · 9 处 `await _flip_case_*()`（run_flip 内，本族私有用例，保留原形）；
#   · 3 处 `await _flip_hunt_trial(...)`（_flip_case_hunt 内，本族私有，保留原形）。
# main.gd 分发口那几个 `await _checks_envphys.run_*()` 留在 main 自己那层协程 ——
# 协程深度与迁移前一致（opponent_spawner 实证：多一层协程 = physics_frame 恢复时机差
# 1 物理帧 = 25856 行日志发散）。
$awaitInMod = ([regex]::Matches($modCode, '(?<![\.\w])await\s+')).Count
$pfHits = ([regex]::Matches($modCode, 'await\s+_physics_frame\.call\(\)')).Count
$fp2Hits = ([regex]::Matches($modCode, 'await\s+_friction_probe\(')).Count
$fcHits = ([regex]::Matches($modCode, 'await\s+_flip_case_')).Count
$fhHits = ([regex]::Matches($modCode, 'await\s+_flip_hunt_trial\(')).Count
$treeHits = ([regex]::Matches($modCode, 'get_tree\(\)|get_viewport\(\)')).Count
$awaitOk = ($awaitInMod -eq 29 -and $pfHits -eq 16 -and $fp2Hits -eq 1 -and
    $fcHits -eq 9 -and $fhHits -eq 3 -and $treeHits -eq 0)
Add-R "env_phys.gd 内 await 恰 29 处（16 physics_frame.call + 1 friction_probe + 9 flip_case + 3 flip_hunt_trial；get_tree=0）" $awaitOk (
    "await={0}/29 physics_frame={1}/16 friction_probe={2}/1 flip_case={3}/9 flip_hunt={4}/3 get_tree/viewport={5}/0" -f
    $awaitInMod, $pfHits, $fp2Hits, $fcHits, $fhHits, $treeHits)

# ---------------------------------------------------------------- ⑧ 模块边界：不接触场景树
# 车/赛道/环境/物理世界由 setup() 注入；模块里不该再有 get_node / get_tree / get_viewport /
# get_world_3d（`_car.get_node_or_null("CarModel")` 之类的 car 自身子节点不算 —— 那是车的内部）。
$getNodeHits = ([regex]::Matches($modCode, '(?<![\.\w])get_node(_or_null)?\(')).Count
$worldHits = ([regex]::Matches($modCode, 'get_world_3d\(')).Count
$boundaryOk = ($getNodeHits -eq 0 -and $treeHits -eq 0 -and $worldHits -eq 0)
Add-R "模块无 get_node/get_tree/get_viewport/get_world_3d（引用全经 setup 注入）" $boundaryOk (
    "get_node={0} get_tree/viewport={1} get_world_3d={2}（期望 0/0/0）" -f $getNodeHits, $treeHits, $worldHits)

# ---------------------------------------------------------------- ⑨ 没被误迁：邻族与 layout/bench/ai 接线原样
$neighborOk = ($mainRaw -match 'func\s+_check_reverse\s*\(') -and ($mainRaw -match 'const\s+REVERSE_CASES\s*:=\s*6') `
    -and ($mainRaw -match 'func\s+_check_escape\s*\(') -and ($mainRaw -match 'func\s+_check_reset\s*\(') `
    -and ($mainRaw -match 'func\s+_check_reset_key\s*\(') -and ($mainRaw -match 'func\s+_check_lap\s*\(') `
    -and ($mainRaw -match 'func\s+_check_stress\s*\(') -and ($mainRaw -match 'func\s+_check_minimap\s*\(') `
    -and ($mainRaw -match 'func\s+_check_pause\s*\(') -and ($mainRaw -match 'func\s+_check_models\s*\(') `
    -and ($mainRaw -match 'func\s+_sample_physics_ms\s*\(') -and ($mainRaw -match 'func\s+_avg_physics_ms\s*\(') `
    -and ($mainCode -match '_checks_layout\.setup\(') -and ($mainCode -match 'await\s+_checks_layout\.run\(') `
    -and ($mainCode -match '_checks_bench\.setup\(') -and ($mainCode -match 'await\s+_checks_bench\.run_steerbench\(') `
    -and ($mainCode -match '_checks_ai\.setup\(') -and ($mainCode -match 'await\s+_checks_ai\.run_')
Add-R "邻族（reset/resetkey/lap/reverse/escape/pause/stress/minimap/models）与 layout/bench/ai 接线仍留在 main.gd" $neighborOk (
    $(if ($neighborOk) { "全部锚点都在（批次边界未越界）" } else { "有锚点丢失（越界删了）" }))

# 分发口：两道闸门用同一个正则提取分支名，这里镜像一遍 ——
# 6 个 ENVPHYS 分支必须在、且分支总数仍是 26（防误删/误增分发项）。
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
$needBranches = @("wallslide", "stuck", "phys", "weather", "friction", "flip")
$missing = @($needBranches | Where-Object { $impl -notcontains $_ })
$dispatchOk = ($missing.Count -eq 0) -and ($impl.Count -eq 26)
Add-R "match _check: 分发口含 wallslide/stuck/phys/weather/friction/flip 且共 26 项（闸门视图不变）" $dispatchOk (
    "分支数={0} 缺失={1}（期望 26 / 无）" -f $impl.Count, $(if ($missing.Count -eq 0) { "无" } else { $missing -join "," }))

# 受保护路径一律不许动：启动器脚本 / 无关游戏脚本 / 验收闸门 / 工程配置。
# 用 git status 全量比对（不逐条传中文路径，避免参数编码把结论搞假）。
# ⚠ 非 ASCII 路径在 git 输出里会被转义成 `\345` 八进制；两种形态都匹配。
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
Add-R "env_phys.gd.uid 存在、13 位、与现存 uid 无碰撞" $uidOk $uidDetail

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
# 期望值按计划编辑逐段口算，再用 `git diff --numstat` 复核（迁移前 2578 行 / 53 func）：
#   删除 998 行（七处迁出块，含各自文档块）：
#     · WALL 431-532 = 102；STUCK 535-643 = 109；PROBE 655-709 = 55；
#     · PHYS 1134-1200 = 67；WEATHER 1349-1434 = 86；FRIC 1437-1562 = 126；FLIP 1574-2026 = 453。
#   插入 33 行：
#     · 模块声明块（注释 + const + var）≈ 12；
#     · setup 接线 ≈ 6；
#     · 七处 breadcrumb 注释 15（2+2+3+2+2+2+2）。
#   2578 - 998 + 33 = 1613；func：-17（本族 17 个函数全部外迁，main 不新增函数）= 36。
$wantLines = 1613
$wantFuncs = 36
Add-R "main.gd 规模 = 1613 行 / 36 func（迁移后准确值）" ($mainLines -eq $wantLines -and $mainFuncs -eq $wantFuncs) (
    "实测 行={0}/func={1}（期望 {2}/{3}；迁移前 2578/53）" -f $mainLines, $mainFuncs, $wantLines, $wantFuncs)

# ---------------------------------------------------------------- 输出
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$head = "================ SPLIT-CHECKS-ENVPHYS-004 结构校验（{0}）================" -f $stamp
$fail = @($results | Where-Object { $_.StartsWith("[FAIL]") })
$summary = "汇总：{0} 项断言，{1} 项失败" -f $results.Count, $fail.Count
$out = @($head) + $results + @("", $summary)
$logName = if ($OutName -ne "") { $OutName } else { "split-checks-envphys-structcheck.log" }
$logFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) $logName
if ($MyInvocation.MyCommand.Path) {
    $out | Out-File -FilePath $logFile -Encoding utf8
}
$out | ForEach-Object { Write-Host $_ }
if ($fail.Count -gt 0) { exit 1 }
exit 0
