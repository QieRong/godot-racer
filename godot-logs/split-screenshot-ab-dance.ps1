# SPLIT-SCREENSHOT-001 行为等价 A/B（stash 舞步，背靠背）。
#
# 对照组 = HEAD 代码（stash 后），改动后 = pop 后；**必须背靠背**（同代码跨进程
# 间隔 5 分钟实测差异 25854 行，harness 有跨进程方差 —— 不背靠背就别做 A/B，
# 见 AGENTS.md §4.3）。
#
# ⚠ 为什么用**定向 pathspec** 而不是任务字面上的 `git stash -u`：
#   先例 split-opponent-ab-dance.ps1 同款理由，且本任务多一条：
#   ① 整仓 stash -u 会把 godot-logs 下的证据文件（structcheck 红绿日志、
#      本脚本、summary）一起卷走，pop 前它们不在盘上；
#   ② shoot.ps1 每一跑都覆盖 godot-logs\shot-0.log —— 若它被 stash 卷走，
#      窗口内新建的同名文件会让 `git stash pop` 因 "untracked already exists" 失败，
#      拆分成果全部困在 stash 里。
#   定向 pathspec 只收 main.gd + screenshot_mode.gd(+.uid)，ctrl 环境仍是
#   **纯 HEAD 代码**（stash 后模块不在盘上、main.gd 回到 4964 行），证据文件全程在盘。
#
# 用法：
#   pwsh -File godot-logs\split-screenshot-ab-dance.ps1 -Group plain      # 含同代码两跑模式确认
#   pwsh -File godot-logs\split-screenshot-ab-dance.ps1 -Group drive
#   pwsh -File godot-logs\split-screenshot-ab-dance.ps1 -Group wrongway
param(
    [ValidateSet("plain", "drive", "wrongway")]
    [string]$Group = "plain"
)
$ErrorActionPreference = "Continue"
$Logs = $PSScriptRoot                       # godot-logs
$Root = Split-Path -Parent $PSScriptRoot    # git 根
$Summary = Join-Path $Logs "split-screenshot-ab-summary.log"
$Shoot = Join-Path $Root "04-Godot启动器\shoot.ps1"
$Main = Join-Path $Root "godot-racer\scenes\main.gd"
$Module = Join-Path $Root "godot-racer\scripts\screenshot_mode.gd"
$ModuleUid = "$Module.uid"
$ShotLog = Join-Path $Logs "shot-0.log"     # shoot.ps1 每跑覆盖它 → 跑完立刻拷
$Bak = Join-Path $Logs "_ab-backup"

function Log([string]$m) { $m | Out-File -FilePath $Summary -Encoding utf8 -Append }

# 跑一次 shoot.ps1 并立刻把 shot-0.log 拷成带名字的证据；记录 exit / 日志行数 / PNG 指纹
function Invoke-Shot([string]$tag, [string[]]$extra) {
    $png = Join-Path $Logs "split-screenshot-$tag.png"
    $logCopy = Join-Path $Logs "split-screenshot-ab-$tag.log"
    $runLog = Join-Path $Logs "split-screenshot-ab-$tag.run.log"
    Log ("--- [{0}] {1}  开始 {2}" -f $Group, $tag, (Get-Date -Format "HH:mm:ss"))
    & pwsh -NoProfile -File $Shoot -Level 0 -Frames 150 -Hold 0 -Out $png @extra 2>&1 |
        Out-File $runLog -Encoding utf8
    $code = $LASTEXITCODE
    if (Test-Path $ShotLog) { Copy-Item $ShotLog $logCopy -Force }
    $pngInfo = "PNG 缺失"
    if (Test-Path $png) {
        $h = (Get-FileHash $png -Algorithm SHA256).Hash
        $pngInfo = ("PNG {0} bytes  sha256={1}..." -f (Get-Item $png).Length, $h.Substring(0, 16))
    }
    $logLines = if (Test-Path $logCopy) { @(Get-Content $logCopy).Count } else { -1 }
    Log ("--- [{0}] {1}  结束 {2}   exit={3}   日志行数={4}   {5}" -f
        $Group, $tag, (Get-Date -Format "HH:mm:ss"), $code, $logLines, $pngInfo)
    # 把 [截图] 行也摘进 summary，结构比对时不用翻大日志
    if (Test-Path $logCopy) {
        $shots = @(Get-Content $logCopy | Where-Object { $_ -match '\[截图\]' })
        Log ("    [截图] 行 x{0}" -f $shots.Count)
    }
}

Log "================ SPLIT-SCREENSHOT-001 A/B（{0}）================" -f $Group
Log ("START {0}   HEAD={1}   工作区文件数={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
    (git rev-parse --short HEAD), @(git status --porcelain -uall).Count)

# 0) 先备份本次涉及的文件：万一 pop 出问题，还能手工还原，不至于丢迁移成果
New-Item -ItemType Directory -Force -Path $Bak | Out-Null
Copy-Item $Main "$Bak\main.gd.after" -Force
Copy-Item $Module "$Bak\screenshot_mode.gd" -Force
Copy-Item $ModuleUid "$Bak\screenshot_mode.gd.uid" -Force
Log "已备份 main.gd / screenshot_mode.gd(+.uid) 到 _ab-backup"

$stashTargets = @("godot-racer/scenes/main.gd",
    "godot-racer/scripts/screenshot_mode.gd",
    "godot-racer/scripts/screenshot_mode.gd.uid")

# 1) 对照组：把本次拆分收起来，回到 HEAD 代码
$s1 = git stash push -u -m "SPLIT-SCREENSHOT-AB-CTRL" -- $stashTargets 2>&1
Log ("stash push: {0}" -f ($s1 -join " | "))
Log ("  → 模块是否还在（应 False）: {0}" -f (Test-Path $Module))
Log ("  → main.gd 行数（应回到 4964）: {0}" -f @(Get-Content $Main).Count)

if ($Group -eq "plain") {
    # 同代码两跑：确认当前负载下的方差形态（AGENTS §4.3「先确认模式」）
    Invoke-Shot "base1" @()
    Invoke-Shot "base2" @()
    Invoke-Shot "ctrl" @()
} elseif ($Group -eq "drive") {
    Invoke-Shot "ctrl-drive" @("-Drive")
} else {
    Invoke-Shot "ctrl-ww" @("-WrongWay", "-WrongWayMode", "1")
}

# 2) 改动组：恢复本次拆分
$s2 = git stash pop 2>&1
Log ("stash pop: {0}" -f ($s2 -join " | "))
Log ("  → 模块是否回来了（应 True）: {0}" -f (Test-Path $Module))
Log ("  → main.gd 行数（应 4801）: {0}" -f @(Get-Content $Main).Count)
$hNow = (Get-FileHash $Main).Hash
$hBak = (Get-FileHash "$Bak\main.gd.after").Hash
Log ("  → main.gd 与备份逐字节一致（pop 无损）: {0}" -f ($hNow -eq $hBak))

if ($Group -eq "plain") {
    Invoke-Shot "after" @()
} elseif ($Group -eq "drive") {
    Invoke-Shot "after-drive" @("-Drive")
} else {
    Invoke-Shot "after-ww" @("-WrongWay", "-WrongWayMode", "1")
}

Log ("END {0}   HEAD={1}   工作区文件数={2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),
    (git rev-parse --short HEAD), @(git status --porcelain -uall).Count)
