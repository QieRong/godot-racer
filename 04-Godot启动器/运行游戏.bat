@echo off
rem ============================================================
rem  Run the game directly (bypasses the menu). ASCII-only on purpose.
rem
rem  Two gates, both added after real incidents:
rem   1) lint-gdscript.ps1 runs BEFORE the engine starts. A stray
rem      ASCII quote inside a Chinese string makes a whole script
rem      fail to parse; the symptom is "track never builds, car
rem      falls forever, minimap black, every level broken".
rem   2) This Godot build occasionally segfaults during startup
rem      (unrelated to the project). Detect and retry rather than
rem      leave the user thinking "nothing happened".
rem
rem  --log-file must stay: Godot crashes at startup when it cannot
rem  write user:// -- redirecting the log avoids that.
rem ============================================================
set "ROOT=%~dp0.."
set "PROJ=%ROOT%\godot-racer"
set "GODOT=E:\godot\Godot_v4.4.1-stable_win64.exe"
set "LOGDIR=%ROOT%\godot-logs"
set "LOG=%LOGDIR%\game.log"
set "LINT=%~dp0lint-gdscript.ps1"
rem Prefer PowerShell 7 (native UTF-8); fall back to Windows PowerShell 5.1.
set "PS=powershell"
where pwsh >nul 2>&1 && set "PS=pwsh"
setlocal enabledelayedexpansion

if not exist "%PROJ%\project.godot" (
    echo [ERROR] Project not found: %PROJ%
    pause
    exit /b 1
)
if not exist "%GODOT%" (
    echo [ERROR] Godot not found: %GODOT%
    pause
    exit /b 1
)
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >nul 2>&1

if exist "%LINT%" (
    echo [launcher] running GDScript pre-check ...
    %PS% -NoProfile -ExecutionPolicy Bypass -File "%LINT%"
    if !ERRORLEVEL! neq 0 (
        echo.
        echo ============================================================
        echo  BLOCKED: a script has a syntax error that breaks parsing.
        echo  Starting now would show "no track, car falling forever".
        echo  Fix the problems listed above, then run this again.
        echo ============================================================
        pause
        exit /b 1
    )
)

if exist "%~dp0parse-check.ps1" (
    %PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0parse-check.ps1"
    if !ERRORLEVEL! neq 0 (
        echo.
        echo ============================================================
        echo  BLOCKED: a script fails to parse. Starting now would show
        echo  "no track, car falling forever".
        echo ============================================================
        pause
        exit /b 1
    )
)
set /a TRIES=0
:run
set /a TRIES+=1
start "" /wait "%GODOT%" --path "%PROJ%" --log-file "%LOG%" -- %*

if not exist "%LOG%" (
    if !TRIES! lss 4 ( timeout /t 1 >nul & goto run )
    echo [launcher] no log after !TRIES! tries -- run the startup diagnostic
    pause
    exit /b 2
)
findstr /c:"CrashHandlerException" "%LOG%" >nul 2>&1
if !ERRORLEVEL! equ 0 (
    if !TRIES! lss 4 (
        echo [launcher] known startup segfault, retrying ^(!TRIES!^) ...
        timeout /t 1 >nul
        goto run
    )
    echo [launcher] repeated startup segfaults -- run the startup diagnostic
    pause
    exit /b 2
)

findstr /c:"Parse Error" /c:"Failed to load script" /c:"Compilation failed" "%LOG%" >nul 2>&1
if !ERRORLEVEL! equ 0 (
    echo.
    echo ============================================================
    echo  WARNING: script parse/compile errors found in the log.
    echo  The game did NOT behave normally. Details:
    echo ============================================================
    findstr /c:"Parse Error" /c:"Failed to load script" /c:"Compilation failed" "%LOG%"
    echo.
    echo  Full log: %LOG%
    pause
)
exit /b 0