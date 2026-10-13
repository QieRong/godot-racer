# SPLIT-SCREENSHOT-001 结构校验（TDD：先红后绿）。
#
# 为什么必须有它：本次是"纯迁移"，最大的风险不是逻辑改错，而是**迁移不完整** ——
# 漏搬一个状态/函数、调用点漏改、把不该搬的（menu.gd 的 _shot_menu_after 是另一个功能）
# 顺手扫进来、或者把注入写反（模块去 get_node / 反向持有场景）。这些都不会让 parse 报错，
# 只会在 A/B 里表现为"行为没变但结构不对"，或者更糟——下次拆分时踩坑。
# 所以把"迁完后的结构事实"写成可执行断言，动手前跑红、迁完跑绿。
#
# 用法：pwsh -File godot-logs\split-screenshot-structcheck.ps1
# 退出码：0 = 全绿；1 = 有断言失败（红）。
param(
    [string]$Root = ""
)
$ErrorActionPreference = "Continue"
if ($Root -eq "") { $Root = Split-Path -Parent $PSScriptRoot }   # godot-logs 的父目录 = git 根
$Proj = Join-Path $Root "godot-racer"
$Main = Join-Path $Proj "scenes\main.gd"
$Shot = Join-Path $Proj "scripts\screenshot_mode.gd"
$ShotUid = Join-Path $Proj "scripts\screenshot_mode.gd.uid"
$Menu = Join-Path $Proj "scripts\menu.gd"

$results = New-Object System.Collections.Generic.List[string]
function Add-R([string]$name, [bool]$ok, [string]$detail) {
    $tag = if ($ok) { "PASS" } else { "FAIL" }
    $results.Add(("[{0}] {1} -- {2}" -f $tag, $name, $detail))
}

# 去掉整行注释后再匹配，避免把文件头决策记录里点名的 `_shot_mode` / `get_tree()` 等
# 当成真实代码引用（先例：split-opponent-structcheck.ps1 同款去噪）。
function Strip-Comments([string]$t) {
    $lines = @($t -split "`r?`n")
    $kept = @($lines | Where-Object { $_ -notmatch '^\s*#' })
    return ($kept -join "`n")
}

$mainRaw = if (Test-Path $Main) { Get-Content $Main -Raw } else { "" }
$shotRaw = if (Test-Path $Shot) { Get-Content $Shot -Raw } else { "" }
$menuRaw = if (Test-Path $Menu) { Get-Content $Menu -Raw } else { "" }
$mainCode = Strip-Comments $mainRaw
$shotCode = Strip-Comments $shotRaw

$mainLines = 0
$mainFuncs = 0
if (Test-Path $Main) {
    $ml = Get-Content $Main
    $mainLines = $ml.Count
    $mainFuncs = ([regex]::Matches($mainRaw, '(?m)^func\s+')).Count
}

# ---------------------------------------------------------------- ① 新模块存在且形态正确
$exists = Test-Path $Shot
Add-R "screenshot_mode.gd 存在" $exists $(if ($exists) { "scripts/screenshot_mode.gd" } else { "文件不存在（尚未创建）" })

$extendsOk = $shotRaw -match '(?m)^extends\s+RefCounted\s*$'
$classNameHits = ([regex]::Matches($shotRaw, '(?m)^class_name\s+')).Count
Add-R "模块 extends RefCounted 且无 class_name（§2.4 铁律）" ($extendsOk -and $classNameHits -eq 0) (
    "extends RefCounted={0} class_name 定义数={1}（期望 True/0）" -f $extendsOk, $classNameHits)

# ---------------------------------------------------------------- ② main.gd 零残留
# 这四个 token 迁完后在 main.gd 里一次都不该出现（连注释都不留——调用点与段落头都搬走了）。
# ⚠ `_screenshot_mode` 不含子串 `_shot_mode`（shot 前一个是 n），不会误命中。
$residTotal = 0
$residDetail = ""
foreach ($n in @("_shot_mode", "_parse_shot_args", "_shot_wrongway_warp", "save_png")) {
    $c = ([regex]::Matches($mainRaw, [regex]::Escape($n))).Count
    if ($c -gt 0) { $residDetail += (" {0}={1}" -f $n, $c) }
    $residTotal += $c
}
Add-R "main.gd 无 _shot_mode/_parse_shot_args/_shot_wrongway_warp/save_png 残留" ($residTotal -eq 0) (
    "残留总数 = {0}{1}" -f $residTotal, $residDetail)

# ---------------------------------------------------------------- ③ main.gd 侧接线恰各一处
$constHits = ([regex]::Matches($mainRaw, '(?m)^const\s+ScreenshotMode\s+:=\s*preload\("res://scripts/screenshot_mode\.gd"\)')).Count
$setupHits = ([regex]::Matches($mainCode, '_screenshot_mode\.setup\(')).Count
$parseHits = ([regex]::Matches($mainCode, '_screenshot_mode\.parse_args\(\)')).Count
$tickHits = ([regex]::Matches($mainCode, '_screenshot_mode\.tick\(')).Count
$wireOk = ($constHits -eq 1 -and $setupHits -eq 1 -and $parseHits -eq 1 -and $tickHits -eq 1)
Add-R "main.gd 接线恰各一处（const/setup/parse_args/tick）" $wireOk (
    "const={0}/1 setup={1}/1 parse_args={2}/1 tick={3}/1" -f $constHits, $setupHits, $parseHits, $tickHits)

# ③b main.gd 新增的 3 个场景能力回调（setup 的第 6~8 个参数就是它们）
$cbOk = $true
$cbDetail = ""
foreach ($n in @("_shot_capture_image", "_shot_quit_app", "_shot_physics_frame")) {
    $def = ([regex]::Matches($mainRaw, ('(?m)^func\s+' + $n + '\s*\('))).Count
    $inj = ([regex]::Matches($mainCode, ('Callable\(self,\s*"' + $n + '"\)'))).Count
    if ($def -ne 1 -or $inj -ne 1) { $cbOk = $false }
    $cbDetail += (" {0}(定义={1},注入={2})" -f $n, $def, $inj)
}
Add-R "main.gd 三个场景能力回调各定义 1 处且各注入 1 处" $cbOk ("期望全为 1/1：" + $cbDetail)

# ---------------------------------------------------------------- ④ 模块 API 与 10 个状态齐全
$apiOk = $true
$apiDetail = ""
foreach ($sig in @("func parse_args", "func wrongway_warp", "func tick", "var mode", "save_png")) {
    $c = ([regex]::Matches($shotRaw, [regex]::Escape($sig))).Count
    if ($c -lt 1) { $apiOk = $false }
    $apiDetail += (" {0}={1}" -f $sig, $c)
}
$states = @("_shot_mode", "_shot_frames", "_shot_hold", "_shot_steer", "_shot_view",
    "_shot_out", "_shot_frame", "_shot_drive", "_shot_wrongway", "_shot_wrongway_flipped")
foreach ($n in $states) {
    $c = ([regex]::Matches($shotRaw, ('(?m)^var\s+' + $n + '\s*:='))).Count
    if ($c -ne 1) { $apiOk = $false }
    $apiDetail += (" {0}定义={1}" -f $n, $c)
}
Add-R "模块含 parse_args/wrongway_warp/tick/mode/save_png 与全部 10 个 _shot_* 状态" $apiOk ("实测：" + $apiDetail)

# ④b tick() 不接收 delta（原主体本来就不用 _delta）
$tickSigOk = $shotRaw -match '(?m)^func\s+tick\(\)\s*->\s*void'
Add-R "tick() 签名为无参（原主体不用 _delta）" $tickSigOk $(if ($tickSigOk) { "func tick() -> void" } else { "签名不符或缺失" })

# ④c setup 签名八参（car/track/autopilot/engine_audio/camera + 3 个 Callable）
$setupSigOk = $shotRaw -match '(?s)func\s+setup\(car:\s*VehicleBody3D,\s*track:\s*Node3D,\s*autopilot,\s*engine_audio,\s*camera:\s*Node3D,\s*capture_image:\s*Callable,\s*quit_app:\s*Callable,\s*physics_frame:\s*Callable\)\s*->\s*void'
Add-R "setup() 八参签名（3 节点 + 2 实例 + 3 Callable）" $setupSigOk $(if ($setupSigOk) { "OK" } else { "签名不符或缺失" })

# ---------------------------------------------------------------- ⑤ 帧一致性铁律：模块内 await 恰 2 处
# 两处都在 wrongway_warp（等赛道建好 + 等半秒物理稳定），迁移前就在 main 里，一个都没多。
# 本模块不像 opponent_spawner 要求 0 await——那条专指物理基线采样路径；这里把「2」钉死，
# 禁止第三人加 await 改变协程深度（split-opponent 那 1 帧之差 = 25856 行日志发散的教训）。
$awaitInShot = ([regex]::Matches($shotCode, '(?<![\.\w])await\s+')).Count
Add-R "screenshot_mode.gd 内 await 数 == 2（wrongway_warp 的两拍，保协程深度不变）" ($awaitInShot -eq 2) (
    "模块内 await={0}（期望 2）" -f $awaitInShot)

# ---------------------------------------------------------------- ⑥ 模块边界：不接触场景树
# 注入优先：car/track/camera/autopilot/engine_audio 全部由 setup 给，
# 取图/退出/等帧走 Callable；模块里不该再有 get_node / get_tree / get_viewport。
$getNodeHits = ([regex]::Matches($shotCode, '(?<![\.\w])get_node(_or_null)?\(')).Count
$treeHits = ([regex]::Matches($shotCode, 'get_tree\(\)|get_viewport\(\)')).Count
$boundaryOk = ($getNodeHits -eq 0 -and $treeHits -eq 0)
Add-R "模块无 get_node/get_tree/get_viewport（场景能力全部注入）" $boundaryOk (
    "get_node={0} get_tree/viewport={1}（期望 0/0）" -f $getNodeHits, $treeHits)

# ---------------------------------------------------------------- ⑦ 没被误迁：menu 的 --shot-menu 与 shoot.ps1 原样
$menuAfter = $menuRaw -match 'func\s+_shot_menu_after\s*\('
Add-R "menu.gd 的 _shot_menu_after（--shot-menu，另一个功能）仍在" $menuAfter $(if ($menuAfter) { "在" } else { "丢" })

# 受保护路径一律不许动：启动器脚本 / 无关游戏脚本 / 验收闸门 / 工程配置。
# 用 git status 全量比对（不逐条传中文路径，避免参数编码把结论搞假）。
$protected = @("04-Godot启动器/", "scripts/menu.gd", "scripts/vehicle.gd", "scripts/ai_opponent.gd",
    "scripts/racing_line.gd", "scripts/track_layout.gd", "project.godot",
    "run-all-checks.ps1", "check-docs.ps1", "check-readme.ps1")
$statusLines = @(& git -C $Root status --porcelain -uall)
$touched = @()
foreach ($l in $statusLines) {
    foreach ($p in $protected) {
        if ($l -match [regex]::Escape($p)) { $touched += $l.Trim() }
    }
}
Add-R "受保护路径零改动（启动器/无关脚本/闸门/工程配置）" ($touched.Count -eq 0) (
    $(if ($touched.Count -eq 0) { "git status 中无受保护路径" } else { "被碰到：" + ($touched -join " ; ") }))

# ---------------------------------------------------------------- ⑧ .uid 文件在盘且格式合法
# 「入库」在提交后由 git ls-files 复核（绿跑发生在提交前，见脚本头说明）；
# 这里先钉死"文件存在 + uid:// 格式"，缺一个都说明拆分不完整。
$uidOk = $false
$uidDetail = "文件不存在（尚未创建）"
if (Test-Path $ShotUid) {
    $uidText = (Get-Content $ShotUid -Raw).Trim()
    $uidOk = $uidText -match '^uid://[a-z0-9]{8,}$'
    $uidDetail = $uidText
}
Add-R "screenshot_mode.gd.uid 存在且格式合法（uid://...）" $uidOk $uidDetail

# ---------------------------------------------------------------- ⑨ 两份 AGENTS.md 逐字节一致
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

# ---------------------------------------------------------------- ⑩ 规模指纹：行数与 func 数
# 期望值按 git diff 实测核对过（4964 行 / 89 func 基础上，6 处编辑）：
#   · L41-64 状态段（24 行）→ const+var 声明块（12 行）：-12
#   · _after_world_ready 增补 _screenshot_mode.setup(...) 接线（1 行 → 9 行）：+8
#   · _parse_shot_args() → _screenshot_mode.parse_args()：0
#   · _mount_opponent_holder 后增 3 个场景能力回调（2 行 → 21 行）：+19
#   · 删除段落头注释 + parse_shot_args + wrongway_warp（L4752-4846 共 95 行，
#     保留 func _process 一行）：-94
#   · _process 截图主体 86 行 → 2 行委派：-84
#   合计净 -163（git diff --stat：38 insertions / 201 deletions）→ 4964-163 = 4801
#   · func：-2（_parse_shot_args/_shot_wrongway_warp）+3（三个回调）= 90
# ⚠ 动手前的口算期望值曾是 4696（把 95 行误记成 195、回调块 +19 误记 +15）——
#   已按 git diff 实测更正；判据仍是"精确值"，不是放宽。
$wantLines = 4801
$wantFuncs = 90
Add-R "main.gd 规模 = 4801 行 / 90 func（迁移后准确值）" ($mainLines -eq $wantLines -and $mainFuncs -eq $wantFuncs) (
    "实测 行={0}/func={1}（期望 {2}/{3}；迁移前 4964/89）" -f $mainLines, $mainFuncs, $wantLines, $wantFuncs)

# ---------------------------------------------------------------- 输出
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$head = "================ SPLIT-SCREENSHOT-001 结构校验（{0}）================" -f $stamp
$fail = @($results | Where-Object { $_.StartsWith("[FAIL]") })
$summary = "汇总：{0} 项断言，{1} 项失败" -f $results.Count, $fail.Count
$out = @($head) + $results + @("", $summary)
$logFile = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "split-screenshot-structcheck.log"
if ($MyInvocation.MyCommand.Path) {
    $out | Out-File -FilePath $logFile -Encoding utf8
}
$out | ForEach-Object { Write-Host $_ }
if ($fail.Count -gt 0) { exit 1 }
exit 0
