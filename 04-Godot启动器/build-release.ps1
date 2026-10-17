<#
.SYNOPSIS
    从**一个确定的 git 提交**构建 Windows 首版交付 ZIP（Godot 4.x 无头导出）。

.DESCRIPTION
    为什么要有这个脚本，而不是手敲一行 godot --export-release：
      1) 手敲的产物**无法追溯** —— ZIP 里没有任何字段能说明"这是哪个提交、用哪个
         引擎、哪天的模板"导出的。出问题时只能靠回忆。
      2) 原地导出会把**工作区当时的状态**焊进产物：未提交的改动、以及 gitignore 掉
         的本机开发插件（本仓 godot-racer/addons/ 就是被忽略的 MCP 开发插件），
         全都会被打进 PCK。产物既不可复现，又多背了几 MB 与一堆无关代码。
      3) 交付清单（许可文件、玩家说明）容易漏，漏了要等玩家发现。

    因此本脚本的默认路径是 **提交快照导出**：用 `git worktree add --detach` 把目标
    提交拉到一个临时目录，在**那棵树里**导入+导出。产物 100% 等于该提交，工作区里
    的未提交改动一律不参与。原地导出必须显式 `-InPlace`（并要求 `-AllowDirty`），
    产物名会带 `-dirty` 后缀、manifest 里记 dirty 状态，避免混进正式交付。

    任一步失败都返回非零退出码，不做"带病继续"。
      exit 2  前置检查失败（引擎/模板/工作区/预设/必需文件）
      exit 3  git 快照失败
      exit 4  Godot 导入或导出失败
      exit 5  打包（清单文件/目录）失败
      exit 6  ZIP 或 SHA256 失败

.PARAMETER GodotPath
    Godot 4.x 可执行文件。缺省按 环境变量 GODOT_BIN → PATH → 各盘符下 godot 目录
    推导。脚本里**不写死本机绝对路径**。

.PARAMETER Preset
    导出预设名，必须与 export_presets.cfg 里的 name 完全一致（默认 "Windows Desktop"）。

.PARAMETER OutputRoot
    产物根目录，默认 <仓库根>/dist（已在 .gitignore 中）。

.PARAMETER AllowDirty
    允许工作区有**已跟踪文件的未提交改动**。快照模式下它只影响"是否放行"：
    产物仍然来自 HEAD，未提交改动不会进包（脚本会明确提示这一点）。

.PARAMETER InPlace
    就在当前工作区导出（不建快照）。必须与 -AllowDirty 一起用，且产物名带 -dirty。
    只在调试导出链路时用；正式交付不要用。

.PARAMETER Force
    允许覆盖同名产物目录/ZIP（默认拒绝覆盖，防止把上一版好成品冲掉）。

.PARAMETER DryRun
    只跑前置检查并打印将执行的步骤，不导入、不导出、不打包。

.PARAMETER TemplateDir
    导出模板根目录。缺省 $env:APPDATA\Godot\export_templates。

.EXAMPLE
    # 正式交付（推荐）：先提交，再跑
    pwsh -File .\build-release.ps1

.EXAMPLE
    # 模板还没装好时，先看还差什么
    pwsh -File .\build-release.ps1 -DryRun

.EXAMPLE
    # 指定引擎与预设
    pwsh -File .\build-release.ps1 -GodotPath "D:\tools\godot\godot.exe" -Preset "Windows Desktop"
#>
[CmdletBinding()]
param(
    [string]$GodotPath = "",
    [string]$Preset = "Windows Desktop",
    [string]$OutputRoot = "",
    [switch]$AllowDirty,
    [switch]$InPlace,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$NoBuildInfo,
    [string]$TemplateDir = "",
    [int]$GodotTimeoutSec = 900,
    [int]$GodotRetries = 3
)

$ErrorActionPreference = 'Stop'

# 本机控制台代码页是 2312，不强制 UTF-8 的话中文提示会乱码，
# 而乱码输出很容易被当成"脚本报错了"。先把输出编码钉死。
try {
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
} catch { }

# ────────────────────────────── 小工具

function Fail {
    param([int]$Code, [string]$Message)
    Write-Host ""
    Write-Host "!! 失败(exit $Code)：$Message" -ForegroundColor Red
    exit $Code
}

function Say {
    param([string]$Message, [string]$Color = "Gray")
    Write-Host $Message -ForegroundColor $Color
}

function Step {
    param([int]$Index, [int]$Total, [string]$Title)
    Write-Host ""
    Write-Host ("[{0}/{1}] {2}" -f $Index, $Total, $Title) -ForegroundColor Cyan
}

# 找 git 仓库根：从脚本目录往上找 .git，避免假设目录层级
function Get-GitRoot {
    param([string]$Start)
    $d = Get-Item -LiteralPath $Start
    while ($null -ne $d) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName '.git')) { return $d.FullName }
        $d = $d.Parent
    }
    return ""
}

# 跑一条 git 命令，返回 @{ Code; Out; Err }；不抛异常，交给调用方判退出码
function Invoke-Git {
    param([string]$Repo, [string[]]$GitArgs)
    $out = & git -C $Repo @GitArgs 2>&1
    return @{ Code = $LASTEXITCODE; Out = @($out) }
}

# 用 UTF-8 写文本文件；$WithBom 决定是否写 BOM（Windows 记事本对中文更友好）
function Write-TextFileUtf8 {
    param([string]$Path, [string]$Text, [bool]$WithBom)
    $enc = [System.Text.UTF8Encoding]::new($WithBom)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# 跑一步 Godot：进程未超时、退出码为 0，且预期产物（若指定）存在。
function Invoke-GodotStep {
    param(
        [string]$StepName,
        [string[]]$Arguments,
        [string]$WorkDir,
        [string]$ExpectPath = "",
        [int]$MaxTries = 3,
        [int]$TimeoutSec = 900
    )
    $lastTail = ""
    for ($try = 1; $try -le $MaxTries; $try++) {
        if ($ExpectPath) { Remove-Item -LiteralPath $ExpectPath -Force -ErrorAction SilentlyContinue }
        $so = [System.IO.Path]::GetTempFileName()
        $se = [System.IO.Path]::GetTempFileName()
        $p = $null
        $timedOut = $false
        try {
            $p = Start-Process -FilePath $script:GodotExe -ArgumentList $Arguments `
                -WorkingDirectory $WorkDir -NoNewWindow -PassThru `
                -RedirectStandardOutput $so -RedirectStandardError $se
            if (-not $p.WaitForExit($TimeoutSec * 1000)) {
                $timedOut = $true
                try { $p.Kill() } catch { }
            } else {
                $p.WaitForExit()   # 重定向了流时必须再等一次，否则输出没刷完
            }
        } finally {
            if ($null -ne $p) { $p.Refresh() }
        }
        $exitCode = -1
        try { if ($null -ne $p) { $exitCode = $p.ExitCode } } catch { }
        $text = ""
        foreach ($f in @($so, $se)) {
            if (Test-Path -LiteralPath $f) { $text += (Get-Content -LiteralPath $f -Raw -ErrorAction SilentlyContinue) }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
        $lastTail = (($text -split "`r?`n") | Where-Object { $_ -ne "" } | Select-Object -Last 25) -join "`n"

        $okFlag = -not $timedOut -and $exitCode -eq 0 -and
            (-not $ExpectPath -or (Test-Path -LiteralPath $ExpectPath))
        $why = if ($timedOut) { "超时(${TimeoutSec}s)" } else { "exit=$exitCode" }
        if ($okFlag) {
            Say ("    {0} 成功（{1}{2}）" -f $StepName, $why, $(if ($ExpectPath) { "，产物已生成" } else { "" })) "DarkGray"
            return $true
        }
        Say ("    {0} 第 {1}/{2} 次未成功（{3}），重试" -f $StepName, $try, $MaxTries, $why) "Yellow"
        if (-not $timedOut) {
            # 有明确错误输出时不要无脑重试：先给一眼现场
            if ($lastTail) { Say ($lastTail -split "`n" | Select-Object -First 8 | ForEach-Object { "      | $_" }) "DarkGray" }
        }
    }
    Say "    $StepName 最终失败，Godot 输出尾部：" "Red"
    Say ($lastTail -split "`n" | ForEach-Object { "      | $_" }) "Red"
    return $false
}

# ────────────────────────────── 常量与自定位

$script:GodotExe = ""
$RepoRoot = Split-Path -Parent $PSScriptRoot          # 本脚本在 04-Godot启动器/ 下
if (-not (Get-ChildItem -LiteralPath $RepoRoot -Filter 'godot-racer' -Directory -ErrorAction SilentlyContinue)) {
    $alt = Get-GitRoot -Start $RepoRoot
    if ($alt -and (Test-Path -LiteralPath (Join-Path $alt 'godot-racer'))) { $RepoRoot = $alt }
}
$ProjDir = Join-Path $RepoRoot 'godot-racer'
$AssetsDir = Join-Path $RepoRoot 'dist-assets'
if (-not $OutputRoot) { $OutputRoot = Join-Path $RepoRoot 'dist' }

$ReadmePlayer = Join-Path $AssetsDir 'README-玩家版.txt'
$LicenseFiles = @('LICENSE', 'THIRD_PARTY_NOTICES.md', 'THIRD-PARTY-LICENSES.md')

$StepsTotal = 7
$issues = New-Object System.Collections.Generic.List[string]

Write-Host "== Godot Racer · Windows 发布打包 ==" -ForegroundColor White
Say "   仓库根 : $RepoRoot"
Say "   工程   : $ProjDir"
Say "   产物根 : $OutputRoot"
Say "   预设   : $Preset"
Say ("   模式   : {0}" -f $(if ($InPlace) { "原地导出（调试用，产物带 -dirty）" } else { "提交快照导出（可追溯）" }))

# ────────────────────────────── [1/7] 前置检查

Step 1 $StepsTotal "前置检查"

# (a) Godot 引擎
if (-not $GodotPath) { $GodotPath = $env:GODOT_BIN }
if (-not $GodotPath) {
    $cmd = Get-Command godot.exe, godot, godot4.exe, godot4 -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($cmd) { $GodotPath = $cmd.Source }
}
if (-not $GodotPath) {
    # 按"每个盘符下的 godot 目录"推导（install_godot.ps1 装的就是这个位置），
    # 不写死某个具体盘符，换机器也不用改脚本。
    $drives = (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object { $_.Root })
    foreach ($d in $drives) {
        $hit = Get-ChildItem -Path (Join-Path $d 'godot') -Filter 'Godot_v*_win64.exe' -File `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { $GodotPath = $hit.FullName; break }
    }
}
if (-not $GodotPath -or -not (Test-Path -LiteralPath $GodotPath -PathType Leaf)) {
    $issues.Add("找不到 Godot 引擎：用 -GodotPath 指定，或设环境变量 GODOT_BIN")
} else {
    $script:GodotExe = (Resolve-Path -LiteralPath $GodotPath).Path
    $GodotVersion = (& $script:GodotExe --version 2>$null | Select-Object -First 1)
    if (-not $GodotVersion) { $issues.Add("Godot 引擎无法执行：$script:GodotExe") }
    else {
        Say "   引擎   : $script:GodotExe"
        Say "   版本   : $GodotVersion"
    }
}

# (b) 导出模板：目录名 = <主版本>.<次版本>.<修订>.<状态>，例如 4.4.1.stable
$TemplateVersion = ""
if ($GodotVersion) {
    $vp = $GodotVersion -split '\.'
    if ($vp.Count -ge 4) { $TemplateVersion = ($vp[0..3] -join '.') }
    else { $TemplateVersion = $GodotVersion }
}
if (-not $TemplateDir) { $TemplateDir = Join-Path $env:APPDATA 'Godot\export_templates' }
$TemplatePath = if ($TemplateVersion) { Join-Path $TemplateDir $TemplateVersion } else { "" }
$TemplateExe = ""
if ($TemplatePath -and (Test-Path -LiteralPath $TemplatePath)) {
    # 不能只 glob 'windows_release*.exe'：模板目录里同时有 x86_64 / arm64 和
    # 带 _console 的变体，实测按字母序第一次命中的是 windows_release_arm64_console.exe，
    # 和预设的 x86_64 对不上。所以要"先要精确的，再退回近似"，并排除 _console。
    $TemplateExe = Get-ChildItem -LiteralPath $TemplatePath -Filter 'windows_release_x86_64.exe' -File `
        -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object { $_.FullName }
    if (-not $TemplateExe) {
        $TemplateExe = Get-ChildItem -LiteralPath $TemplatePath -Filter 'windows_release*.exe' -File `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '*_console.exe' } |
            Select-Object -First 1 | ForEach-Object { $_.FullName }
    }
}
if (-not $TemplatePath -or -not (Test-Path -LiteralPath $TemplatePath)) {
    $issues.Add("导出模板目录不存在：$TemplatePath" +
        "（用编辑器菜单 Editor → Manage Export Templates 或 `$TemplateDir` 参数指定）")
} elseif (-not $TemplateExe) {
    $issues.Add("模板目录里没有 windows_release*.exe：$TemplatePath（模板没装全）")
} else {
    Say "   模板   : $TemplateExe"
}

# (c) git 仓库 + 工作区干净度
$gitRoot = Get-GitRoot -Start $RepoRoot
if (-not $gitRoot) { $issues.Add("$RepoRoot 不是 git 仓库（找不到 .git）") }
$HeadFull = ""; $HeadShort = ""; $TrackedDirty = @(); $Untracked = @()
if ($gitRoot) {
    $r = Invoke-Git -Repo $RepoRoot -GitArgs @('rev-parse', 'HEAD')
    if ($r.Code -ne 0) { $issues.Add("git rev-parse HEAD 失败：$($r.Out -join ' ')") }
    else { $HeadFull = ($r.Out | Select-Object -First 1).ToString().Trim() }

    $r = Invoke-Git -Repo $RepoRoot -GitArgs @('rev-parse', '--short', 'HEAD')
    if ($r.Code -eq 0) { $HeadShort = ($r.Out | Select-Object -First 1).ToString().Trim() }

    # 已跟踪文件的改动（这才是"工作区脏"）：用 diff-index，避免把未跟踪杂物算进来
    $r = Invoke-Git -Repo $RepoRoot -GitArgs @('diff-index', '--name-only', 'HEAD', '--')
    if ($r.Code -eq 0) { $TrackedDirty = @($r.Out | Where-Object { "$_".Trim() -ne "" }) }

    $r = Invoke-Git -Repo $RepoRoot -GitArgs @('ls-files', '--others', '--exclude-standard')
    if ($r.Code -eq 0) { $Untracked = @($r.Out | Where-Object { "$_".Trim() -ne "" }) }

    Say "   提交   : $HeadFull ($HeadShort)"
    if ($TrackedDirty.Count -gt 0) {
        if ($AllowDirty) {
            Say "   工作区 : 有 $($TrackedDirty.Count) 个已跟踪文件被改动（-AllowDirty 已放行）" "Yellow"
            if (-not $InPlace) {
                Say "           注意：本次是快照导出，产物来自 $HeadShort，这些改动**不会**进包" "Yellow"
            }
        } else {
            $issues.Add("工作区有 $($TrackedDirty.Count) 个已跟踪文件未提交改动（先提交，或用 -AllowDirty 明确放行）：`n      " +
                (($TrackedDirty | Select-Object -First 10) -join "`n      "))
        }
    }
    if ($Untracked.Count -gt 0) {
        Say "   未跟踪 : $($Untracked.Count) 个文件（快照导出不含它们）" "DarkGray"
    }
    if ($InPlace -and -not $AllowDirty) {
        $issues.Add("-InPlace 原地导出让产物依赖未提交状态，必须同时给 -AllowDirty 明确表态")
    }
}

# (d) 预设与两个关键文件
# 预设先按**工作区**的 export_presets.cfg 校验（快照此刻还没建）；
# 快照模式下另外用 git cat-file 确认该文件已进提交，缺了就明确报错。
$PresetFile = Join-Path $ProjDir 'export_presets.cfg'
$PresetNames = @()
if (Test-Path -LiteralPath $PresetFile) {
    $PresetNames = @([regex]::Matches((Get-Content -LiteralPath $PresetFile -Raw), '(?m)^\s*name\s*=\s*"([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value })
}
if ($PresetNames.Count -eq 0) {
    $issues.Add("读不到导出预设（$PresetFile 不存在或没有 name= 条目）")
} elseif ($PresetNames -notcontains $Preset) {
    $issues.Add("预设名 `"$Preset`" 不在 export_presets.cfg 里。现有预设：$($PresetNames -join ' / ')")
} else {
    Say "   预设   : $Preset ✔"
}

foreach ($f in @('icon.svg', 'icon.ico')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ProjDir $f))) {
        if ($f -eq 'icon.ico') {
            $issues.Add("缺 $f（export_presets.cfg 指定 application/icon=res://icon.ico）。" +
                "先跑：python 04-Godot启动器\make-icon-ico.py")
        } else {
            $issues.Add("缺 $f")
        }
    }
}

# (e) 随包文件
if (-not (Test-Path -LiteralPath $ReadmePlayer)) {
    $issues.Add("缺玩家说明：$ReadmePlayer")
} else {
    # 玩家说明必须是 UTF-8 **with BOM**：中文 Windows 的记事本对无 BOM 的 UTF-8
    # 会按本地代码页解码，整篇中文变乱码 —— 这是必须挡在打包前的事。
    $head = [System.IO.File]::ReadAllBytes($ReadmePlayer)
    if ($head.Length -lt 3 -or $head[0] -ne 0xEF -or $head[1] -ne 0xBB -or $head[2] -ne 0xBF) {
        $issues.Add("$ReadmePlayer 不是 UTF-8 with BOM（中文记事本会乱码）。转换命令：" +
            "`$t=[IO.File]::ReadAllText(`$p,[Text.UTF8Encoding]::new(`$false)); [IO.File]::WriteAllText(`$p,`$t,[Text.UTF8Encoding]::new(`$true))")
    } else {
        Say "   玩家说明: README-玩家版.txt（UTF-8 BOM ✔）"
    }
}
foreach ($f in $LicenseFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $f))) {
        $issues.Add("缺随包许可文件：$f")
    }
}

# 快照模式下额外确认"提交里就有这些文件" —— 否则导出必然失败或产物不完整
if (-not $InPlace -and $gitRoot -and $HeadFull) {
    foreach ($rel in @('godot-racer/export_presets.cfg', 'godot-racer/icon.ico',
        'dist-assets/README-玩家版.txt', 'LICENSE', 'THIRD_PARTY_NOTICES.md',
        'THIRD-PARTY-LICENSES.md')) {
        $r = Invoke-Git -Repo $RepoRoot -GitArgs @('cat-file', '-e', "${HeadFull}:$rel")
        if ($r.Code -ne 0) {
            $issues.Add("提交 $HeadShort 里没有 $rel —— 快照导出必然拿不到它。先提交它（这正是快照模式要挡的情况）")
        }
    }
}

if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "前置检查未通过（$($issues.Count) 项）：" -ForegroundColor Yellow
    $i = 0
    foreach ($msg in $issues) { $i++; Write-Host ("  ✘ $i. $msg") }
    if ($DryRun) { exit 2 }
    Fail 2 "前置检查未通过，已终止（未产生任何产物）"
}
Say "   前置检查全部通过 ✔" "Green"

if ($DryRun) {
    Write-Host ""
    Say "== DryRun：以下是模板装好、提交补齐后会执行的步骤 ==" "Cyan"
    Say "  2) 取提交号        : $HeadShort"
    if ($InPlace) {
        Say "  3) 导出目录        : 原地 $ProjDir（产物名带 -dirty）"
    } else {
        Say "  3) 快照工作树      : git worktree add --detach <dist>/.snapshot-$HeadShort $HeadShort"
    }
    Say "  4) 生成导入缓存    : godot --headless --path <工程> --import"
    Say "  5) 无头导出        : godot --headless --path <工程> --export-release `"$Preset`" <Godot-Racer.exe>"
    Say "  6) 组装 + 打 ZIP   : $OutputRoot\Godot-Racer-<提交号>\ + .zip + .zip.sha256"
    Say "  7) 校验            : zip/pck/exe 的 SHA256 写入 manifest"
    exit 0
}

# ────────────────────────────── [2/7] 提交号与产物命名

Step 2 $StepsTotal "确定提交号与产物命名"
if (-not $HeadShort) { Fail 2 "拿不到提交号，无法命名产物" }
$Suffix = if ($InPlace) { '-dirty' } else { '' }
$ArtifactTag = "$HeadShort$Suffix"
$PkgName = "Godot-Racer-$ArtifactTag"
$PkgDir = Join-Path $OutputRoot $PkgName
$ZipPath = Join-Path $OutputRoot "$PkgName.zip"
$ShaPath = Join-Path $OutputRoot "$PkgName.zip.sha256"
$ManifestPath = Join-Path $OutputRoot "$PkgName.manifest.txt"
$StagingDir = Join-Path $OutputRoot ".staging-$ArtifactTag"
$SnapshotDir = Join-Path $OutputRoot ".snapshot-$HeadShort"

# 下面的清理有递归删除；必须先解析成绝对路径并保证仅落在本次产物根内。
$OutputFull = [System.IO.Path]::GetFullPath($OutputRoot).TrimEnd('\', '/')
if ($OutputFull -eq [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/') -or
    $OutputFull -eq [System.IO.Path]::GetFullPath($ProjDir).TrimEnd('\', '/')) {
    Fail 2 "产物根不能是仓库根或 Godot 工程根：$OutputFull"
}
$OutputPrefix = $OutputFull + [System.IO.Path]::DirectorySeparatorChar
foreach ($candidate in @($PkgDir, $ZipPath, $ShaPath, $ManifestPath, $StagingDir, $SnapshotDir)) {
    $full = [System.IO.Path]::GetFullPath($candidate)
    if (-not $full.StartsWith($OutputPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Fail 2 "拒绝操作产物根之外的路径：$full"
    }
}

Say "   产物目录 : $PkgDir"
Say "   ZIP      : $ZipPath"

if (-not $Force) {
    foreach ($p in @($PkgDir, $ZipPath, $ShaPath, $ManifestPath)) {
        if (Test-Path -LiteralPath $p) {
            Fail 2 "已存在同名产物：$p`n    防止覆盖上一版好成品：换个提交，或确认后加 -Force"
        }
    }
}

if (-not (Test-Path -LiteralPath $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
}

# ────────────────────────────── [3/7] 准备导出源树

Step 3 $StepsTotal "准备导出源树（提交快照 / 原地）"
$BuildProjDir = $ProjDir
$WorktreeAdded = $false

if ($InPlace) {
    Say "   原地导出：用当前工作区 $ProjDir" "Yellow"
    Say "   注意：本机被 gitignore 的开发插件（godot-racer/addons/）会被打进 PCK" "Yellow"
} else {
    if (Test-Path -LiteralPath $SnapshotDir) {
        Say "   发现上次残留的快照，先清理：$SnapshotDir" "Yellow"
        & git -C $RepoRoot worktree remove --force $SnapshotDir 2>&1 | Out-Null
        if (Test-Path -LiteralPath $SnapshotDir) { Remove-Item -LiteralPath $SnapshotDir -Recurse -Force }
    }
    $r = Invoke-Git -Repo $RepoRoot -GitArgs @('worktree', 'add', '--detach', $SnapshotDir, $HeadFull)
    if ($r.Code -ne 0) {
        Fail 3 "git worktree add 失败：$($r.Out -join ' ')"
    }
    $WorktreeAdded = $true
    $BuildProjDir = Join-Path $SnapshotDir 'godot-racer'
    if (-not (Test-Path -LiteralPath $BuildProjDir)) { Fail 3 "快照里没有 godot-racer 目录：$BuildProjDir" }
    Say "   快照就绪：$SnapshotDir （detach @ $HeadShort）" "Green"
    Say "   产物内容 = 该提交，工作区未提交改动一律不参与" "DarkGray"
}

try {
    # ────────────────────── [4/7] 生成导入缓存
    Step 4 $StepsTotal "生成导入缓存（--import）"
    Say "   为什么先导入：快照是干净检出，没有 .godot/ 导入缓存；" "DarkGray"
    Say "   直接导出会缺资源。CI 的标准做法就是先 --import 再 --export-release。" "DarkGray"
    $ok = Invoke-GodotStep -StepName "import" `
        -Arguments @('--headless', '--path', $BuildProjDir, '--import') `
        -WorkDir $BuildProjDir -MaxTries $GodotRetries -TimeoutSec $GodotTimeoutSec
    if (-not $ok) { Fail 4 "Godot 导入失败（--import）" }

    # ────────────────────── [5/7] 无头导出
    Step 5 $StepsTotal "无头导出（--export-release）"
    if (Test-Path -LiteralPath $StagingDir) { Remove-Item -LiteralPath $StagingDir -Recurse -Force }
    New-Item -ItemType Directory -Path $StagingDir -Force | Out-Null
    $ExeOut = Join-Path $StagingDir 'Godot-Racer.exe'
    $PckOut = Join-Path $StagingDir 'Godot-Racer.pck'

    # 预设名要自己带引号：Start-Process 的 -ArgumentList 是"按空格拼成命令行"，
    # 不会给带空格的实参加引号。空壳工程实测：'Windows Desktop' 被拆成
    # --export-release Windows Desktop <path>，Godot 报
    #   ERROR: Invalid export preset name: Windows.
    # 看起来像 export_presets.cfg 坏了，其实是引号丢了。
    $PresetArg = '"{0}"' -f $Preset

    $ok = Invoke-GodotStep -StepName "export" `
        -Arguments @('--headless', '--path', $BuildProjDir, '--export-release', $PresetArg, $ExeOut) `
        -WorkDir $BuildProjDir -ExpectPath $ExeOut -MaxTries $GodotRetries -TimeoutSec $GodotTimeoutSec
    if (-not $ok) { Fail 4 "Godot 导出失败（--export-release `"$Preset`"）" }

    $exeItem = Get-Item -LiteralPath $ExeOut
    if ($exeItem.Length -lt 1MB) { Fail 4 "导出的 EXE 只有 $($exeItem.Length) 字节，不像是真心导出成功了" }

    # 打包形态取决于预设的 embed_pck：
    #   false → EXE + 独立 PCK（两个文件必须同目录，玩家少拷一个就起不来）
    #   true  → 只有 EXE（资源内嵌，玩家侧零出错面，但 EXE 更大、更新要整体替换）
    $PresetText = Get-Content -LiteralPath (Join-Path $BuildProjDir 'export_presets.cfg') -Raw
    $embed = ([regex]::Match($PresetText, 'embed_pck\s*=\s*(true|false)').Groups[1].Value -eq 'true')
    $hasPck = Test-Path -LiteralPath $PckOut
    if ($embed) {
        Say "   打包形态：内嵌 PCK（只有 EXE，玩家拷错文件的风险为零）" "DarkGray"
        if ($hasPck) { Say "   注意：预设是内嵌 PCK，却又产出了独立的 pck，请核对预设" "Yellow" }
    } else {
        if (-not $hasPck) { Fail 4 "预设 embed_pck=false，但没生成 $PckOut（导出版缺资源包，玩家侧必然起不来）" }
        Say "   打包形态：独立 PCK（EXE 与 .pck 必须同目录，README 已写明）" "DarkGray"
        Say ("   EXE {0:N1} MB / PCK {1:N1} MB" -f ($exeItem.Length / 1MB), ((Get-Item -LiteralPath $PckOut).Length / 1MB)) "DarkGray"
    }

    # ────────────────────── [6/7] 组装交付目录
    Step 6 $StepsTotal "组装交付目录"

    # 必要 DLL：Godot 的 Windows release 模板通常不需要额外 DLL，
    # 但真出现时（自定义模板/GDExtension）不能漏，所以按实际情况收。
    $dlls = @(Get-ChildItem -LiteralPath $StagingDir -Filter '*.dll' -File -ErrorAction SilentlyContinue)
    if ($dlls.Count -eq 0) { Say "   未发现随附 DLL（release 模板静态链接常规运行库时属正常）" "DarkGray" }
    else { Say ("   随附 DLL {0} 个：{1}" -f $dlls.Count, (($dlls | ForEach-Object { $_.Name }) -join ', ')) }

    $PackageSource = if ($InPlace) { $RepoRoot } else { $SnapshotDir }
    foreach ($f in $LicenseFiles) {
        Copy-Item -LiteralPath (Join-Path $PackageSource $f) -Destination (Join-Path $StagingDir $f) -Force
    }
    Copy-Item -LiteralPath (Join-Path $PackageSource 'dist-assets\README-玩家版.txt') `
        -Destination (Join-Path $StagingDir 'README-玩家版.txt') -Force

    $ProductVersion = ""
    $pv = [regex]::Match((Get-Content -LiteralPath (Join-Path $BuildProjDir 'export_presets.cfg') -Raw),
        'product_version\s*=\s*"([^"]+)"')
    if ($pv.Success) { $ProductVersion = $pv.Groups[1].Value }

    if (-not $NoBuildInfo) {
        $info = @(
            "Godot Racer · 构建信息 / Build info",
            "版本 Version     : $ProductVersion",
            "提交 Commit      : $HeadFull ($HeadShort$Suffix)",
            "构建时间 Built   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')",
            "引擎 Engine      : $GodotVersion",
            "预设 Preset      : $Preset",
            "打包形态 Packaging: $(if ($embed) { '内嵌 PCK：只有一个 EXE，资源已封在 EXE 里' } else { '独立 PCK：EXE 与 Godot-Racer.pck 必须放在同一目录' })",
            "来源 Source      : $(if ($InPlace) { '工作区原地导出（含未提交状态，非正式交付）' } else { '提交快照（与上面的 Commit 完全一致）' })",
            "",
            "校验：本目录外同级的 $PkgName.zip.sha256 是完整包的 SHA256。"
        ) -join "`r`n"
        Write-TextFileUtf8 -Path (Join-Path $StagingDir 'BUILD-INFO.txt') -Text $info -WithBom $true
    }

    # 暂存目录 → 正式产物目录（同一卷内的移动是原子的）
    Move-Item -LiteralPath $StagingDir -Destination $PkgDir -Force
    Say "   交付目录：$PkgDir" "Green"
    Get-ChildItem -LiteralPath $PkgDir -File | Sort-Object Name |
        ForEach-Object { Say ("     - {0,-26} {1,12:N0} B" -f $_.Name, $_.Length) "DarkGray" }

    # ────────────────────── [7/7] ZIP + SHA256 + manifest
    Step 7 $StepsTotal "打 ZIP、算 SHA256、写 manifest"
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    # 用 -Path（而不是 -LiteralPath）：Compress-Archive 的 -LiteralPath 在
    # Windows PowerShell 5.1 上不保证存在，-Path 各版本都在。
    # 注意：Compress-Archive 有 2 GB 上限，包体积远超时要换 7-Zip / tar。
    Compress-Archive -Path $PkgDir -DestinationPath $ZipPath -CompressionLevel Optimal
    if (-not (Test-Path -LiteralPath $ZipPath)) { Fail 6 "Compress-Archive 没有产出 $ZipPath" }

    $zipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
    # 写成 sha256sum 能直接校验的格式：<hash>  <文件名>
    Write-TextFileUtf8 -Path $ShaPath -Text ("{0}  {1}`n" -f $zipHash.ToLower(), (Split-Path -Leaf $ZipPath)) -WithBom $false

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Godot Racer Windows 交付清单（本文件在包外，玩家包里不含）")
    $lines.Add("提交        : $HeadFull")
    $lines.Add("短提交      : $HeadShort$Suffix")
    $lines.Add("分支        : $((Invoke-Git -Repo $RepoRoot -GitArgs @('rev-parse','--abbrev-ref','HEAD')).Out -join ' ')")
    $lines.Add("产品版本    : $ProductVersion")
    $lines.Add("引擎        : $GodotVersion")
    $lines.Add("预设        : $Preset")
    $lines.Add("导出模板    : $TemplateExe")
    $lines.Add("构建时间    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')")
    $lines.Add("导出方式    : $(if ($InPlace) { '原地（工作区状态，非正式交付）' } else { 'git worktree 快照（--detach $HeadShort）' })")
    $lines.Add("工作区脏    : $($TrackedDirty.Count -gt 0)（已跟踪文件改动 $($TrackedDirty.Count) 个）")
    if ($Untracked.Count -gt 0) { $lines.Add("未跟踪文件  : $($Untracked.Count) 个（快照导出不影响产物）") }
    $lines.Add("")
    $lines.Add("## 产物文件（SHA256）")
    $lines.Add("")
    Get-ChildItem -LiteralPath $PkgDir -File | Sort-Object Name | ForEach-Object {
        $h = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        $lines.Add(("{0,-26} {1,12} B  {2}" -f $_.Name, $_.Length, $h.ToLower()))
    }
    $lines.Add("")
    $lines.Add("## 压缩包")
    $lines.Add("")
    $lines.Add(("{0,-26} {1,12} B  {2}" -f (Split-Path -Leaf $ZipPath), (Get-Item -LiteralPath $ZipPath).Length, $zipHash.ToLower()))
    $lines.Add("")
    $lines.Add("## 复现命令")
    $lines.Add("")
    $lines.Add("  git worktree add --detach <dir> $HeadFull")
    $lines.Add("  `"$script:GodotExe`" --headless --path <dir>/godot-racer --import")
    $lines.Add("  `"$script:GodotExe`" --headless --path <dir>/godot-racer --export-release `"$Preset`" <out>/Godot-Racer.exe")
    Write-TextFileUtf8 -Path $ManifestPath -Text ($lines -join "`r`n") -WithBom $false

    Say ""
    Say "== 完成 ==" "Green"
    Say "  交付目录 : $PkgDir"
    Say "  ZIP      : $ZipPath"
    Say "  SHA256   : $zipHash"
    Say "  校验文件 : $ShaPath"
    Say "  清单     : $ManifestPath"
    Say ""
    Say "  玩家侧校验（把 zip 放在同一目录）：" "DarkGray"
    Say "    certutil -hashfile `"$PkgName.zip`" SHA256" "DarkGray"
    Say "  发布前提醒：本脚本**只负责产出产物**，不做 go/no-go 判定；" "Yellow"
    Say "  上线前仍需人工确认 QA 门控与许可清单。" "Yellow"
    exit 0
} catch {
    Write-Host ""
    Write-Host "!! 未捕获错误：$($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $StagingDir) { Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 5
} finally {
    # 快照必须清掉，否则 dist/ 里会留一棵完整的工程树（几百 MB）
    if ($WorktreeAdded) {
        & git -C $RepoRoot worktree remove --force $SnapshotDir 2>&1 | Out-Null
        if (Test-Path -LiteralPath $SnapshotDir) {
            Remove-Item -LiteralPath $SnapshotDir -Recurse -Force -ErrorAction SilentlyContinue
        }
        & git -C $RepoRoot worktree prune 2>&1 | Out-Null
    }
    if (Test-Path -LiteralPath $StagingDir) { Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue }
}
