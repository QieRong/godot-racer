@echo off
rem 用 Godot 编辑器打开赛车项目（相对路径，改名不失效）
chcp 65001 >nul
cd /d "%~dp0..\godot-racer"
if not exist "project.godot" (
    echo [错误] 找不到 Godot 项目：%CD%
    pause
    exit /b 1
)
start "" "E:\godot\Godot_v4.4.1-stable_win64.exe" -e --path . --log-file "%~dp0..\godot-logs\editor.log"
exit /b 0
