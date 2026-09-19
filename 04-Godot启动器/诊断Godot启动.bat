@echo off
rem ============================================================
rem  Godot 启动诊断：依次尝试 4 种启动配置，找出能跑的那一种
rem  纯 ASCII，避免中文编码问题
rem ============================================================
setlocal enabledelayedexpansion
cd /d "%~dp0"

set "GODOT=E:\godot\Godot_v4.4.1-stable_win64.exe"
set "PROJ=%~dp0godot-racer"
set "LOGDIR=%~dp0godot-logs"

if not exist "%GODOT%" (
    echo [ERROR] Godot not found: %GODOT%
    pause & exit /b 1
)
if not exist "%LOGDIR%" mkdir "%LOGDIR%"

echo ============================================================
echo  Godot startup diagnostic
echo  Godot : %GODOT%
echo  Proj  : %PROJ%
echo  Logs  : %LOGDIR%
echo ============================================================
echo.

echo [Step 0] Check user:// writability ...
echo    user:// maps to: %APPDATA%\Godot\app_userdata\Godot Racer
if exist "%APPDATA%\Godot" (
    echo    %%APPDATA%%\Godot exists
    echo test > "%APPDATA%\Godot\_writetest.tmp" 2>nul
    if exist "%APPDATA%\Godot\_writetest.tmp" (
        echo    WRITABLE
        del "%APPDATA%\Godot\_writetest.tmp" >nul 2>&1
    ) else (
        echo    NOT WRITABLE  ^<== this is likely the crash cause
    )
) else (
    echo    %%APPDATA%%\Godot does not exist yet
)
echo.

echo [Step 1] Redirect log to writable folder ...
start "" /wait "%GODOT%" --path "%PROJ%" --log-file "%LOGDIR%\try1.log" --quit-after 180
echo    exit code: !ERRORLEVEL!
if exist "%LOGDIR%\try1.log" (
    echo    ---- log head ----
    for /f "usebackq delims=" %%L in (`powershell -NoProfile -Command "Get-Content -LiteralPath '%LOGDIR%\try1.log' -TotalCount 12"`) do echo      %%L
    echo    ------------------
    echo    If you see the engine banner and NO crash, this config works.
    echo    Use run_game_logged.bat to play.
    pause & exit /b 0
)
echo    no log produced -> crash was too early, trying next config
echo.

echo [Step 2] Compatibility renderer ^(OpenGL, safer on old laptops^) ...
start "" /wait "%GODOT%" --path "%PROJ%" --rendering-driver opengl3 --log-file "%LOGDIR%\try2.log" --quit-after 180
if exist "%LOGDIR%\try2.log" (
    echo    ---- log head ----
    for /f "usebackq delims=" %%L in (`powershell -NoProfile -Command "Get-Content -LiteralPath '%LOGDIR%\try2.log' -TotalCount 12"`) do echo      %%L
    echo    ------------------
    echo    Compatibility renderer works. Use run_game_gl.bat to play.
    pause & exit /b 0
)
echo    still nothing. trying next config
echo.

echo [Step 3] Headless ^(no window; verifies project itself is OK^) ...
start "" /wait "%GODOT%" --headless --path "%PROJ%" --log-file "%LOGDIR%\try3.log" --quit-after 120
if exist "%LOGDIR%\try3.log" (
    echo    ---- log head ----
    for /f "usebackq delims=" %%L in (`powershell -NoProfile -Command "Get-Content -LiteralPath '%LOGDIR%\try3.log' -TotalCount 12"`) do echo      %%L
    echo    ------------------
    echo    Headless works -> project files are fine, problem is graphics/user-dir related.
)
echo.
echo ============================================================
echo  Diagnostic finished. Please send these log files back:
echo    %LOGDIR%
echo ============================================================
pause
