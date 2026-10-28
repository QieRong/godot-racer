param(
    [ValidateSet(60,120)][int]$RenderFps = 60,
    [int]$Seed = -1,
    [ValidateRange(-1,8)][int]$Combination = -1
)
$ErrorActionPreference = 'Stop'
$Project = Join-Path (Split-Path -Parent $PSScriptRoot) 'godot-racer'
$Godot = 'E:/godot/Godot_v4.4.1-stable_win64.exe'
if (-not (Test-Path -LiteralPath $Godot)) { throw '找不到本机Godot 4.4.1，请修改启动器中的Godot路径。' }
$Arguments = @('--path', ('"{0}"' -f $Project), '--rendering-method', 'gl_compatibility', '--', '--race-variants', "--render-fps=$RenderFps")
if ($Seed -ge 0) { $Arguments += "--race-seed=$Seed" }
if ($Combination -ge 0) { $Arguments += "--race-combination=$Combination" }
Write-Host '进入菜单后选择第二关。随机范围：3种坡度 × 3种障碍；默认一台AI。'
Write-Host '同局重试保留组合；返回菜单再开局会重新抽取（指定Seed/Combination时可复现）。'
Write-Host '请等后台矩阵结束后再启动试玩，以免两个游戏实例影响时序。'
$Game = Start-Process -FilePath $Godot -ArgumentList $Arguments -WorkingDirectory $Project -WindowStyle Normal -PassThru
Write-Host ("游戏进程：{0}" -f $Game.Id)
