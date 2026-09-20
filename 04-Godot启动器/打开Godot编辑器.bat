@echo off
rem Open the project in the Godot editor (ASCII-only on purpose).
set "PROJ=%~dp0..\godot-racer"
set "GODOT=E:\godot\Godot_v4.4.1-stable_win64.exe"
set "LOGDIR=%~dp0..\godot-logs"
if not exist "%PROJ%\project.godot" (
    echo [ERROR] Project not found: %PROJ%
    pause
    exit /b 1
)
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1
start "" "%GODOT%" -e --path "%PROJ%" --log-file "%LOGDIR%\editor.log"
exit /b 0