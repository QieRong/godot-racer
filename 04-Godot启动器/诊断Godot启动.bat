@echo off
rem ============================================================
rem  Godot startup diagnostic (ASCII-only on purpose).
rem  Tries several startup configurations and reports which works.
rem
rem  NOTE: this script used to point at "%~dp0godot-racer", which
rem  does not exist -- the project lives NEXT TO the launcher
rem  folder, so it must be "%~dp0..\godot-racer". It was broken.
rem ============================================================
setlocal enabledelayedexpansion
set "GODOT=E:\godot\Godot_v4.4.1-stable_win64.exe"
set "PROJ=%~dp0..\godot-racer"
set "LOGDIR=%~dp0..\godot-logs"

if not exist "%GODOT%" (
    echo [ERROR] Godot not found: %GODOT%
    pause & exit /b 1
)
if not exist "%PROJ%\project.godot" (
    echo [ERROR] Project not found: %PROJ%
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

echo [Step 0] check user:// writability ...
if exist "%APPDATA%\Godot" (
    echo test > "%APPDATA%\Godot\_writetest.tmp" 2>nul
    if exist "%APPDATA%\Godot\_writetest.tmp" (
        echo    WRITABLE
        del "%APPDATA%\Godot\_writetest.tmp" >nul 2>&1
    ) else (
        echo    NOT WRITABLE  ^<== likely crash cause
    )
) else (
    echo    %%APPDATA%%\Godot does not exist yet
)
echo.

echo [Step 1] default renderer, redirected log ...
start "" /wait "%GODOT%" --path "%PROJ%" --log-file "%LOGDIR%\diag1.log" --quit-after 180
if exist "%LOGDIR%\diag1.log" (
    echo    log produced. IF it contains no CrashHandlerException, this config works.
    findstr /c:"CrashHandlerException" "%LOGDIR%\diag1.log" >nul 2>&1
    if !ERRORLEVEL! equ 0 (
        echo    ...but it DID crash at startup. Trying next config.
    ) else (
        echo    this config works. Use launcher.bat to play.
        pause & exit /b 0
    )
) else (
    echo    no log -> crash was too early. Trying next config.
)
echo.

echo [Step 2] OpenGL compatibility renderer ...
start "" /wait "%GODOT%" --path "%PROJ%" --rendering-driver opengl3 --log-file "%LOGDIR%\diag2.log" --quit-after 180
if exist "%LOGDIR%\diag2.log" (
    findstr /c:"CrashHandlerException" "%LOGDIR%\diag2.log" >nul 2>&1
    if !ERRORLEVEL! neq 0 (
        echo    compatibility renderer works. If play still crashes, add --rendering-driver opengl3 to the launch args.
        pause & exit /b 0
    )
)
echo    still failing. Trying next config.
echo.

echo [Step 3] headless ^(verifies the project itself loads^) ...
start "" /wait "%GODOT%" --headless --path "%PROJ%" --log-file "%LOGDIR%\diag3.log" --quit-after 120
if exist "%LOGDIR%\diag3.log" (
    echo    headless works -> project files are fine; problem is graphics/user-dir related.
)
echo.
echo ============================================================
echo  Diagnostic finished. Logs are in:
echo    %LOGDIR%
echo ============================================================
pause