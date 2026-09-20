@echo off
rem ============================================================
rem  Godot Racer - menu launcher (this IS the canonical entry).
rem
rem  Why the content is ASCII-only even though the filename is
rem  Chinese: cmd.exe reads .bat bytes in the console codepage, so
rem  a .bat that *contains* Chinese text (or a Chinese filename)
rem  gets mangled. ASCII content + "%~dp0" (which carries the
rem  Chinese folder name safely) avoids that entirely.
rem
rem  There used to be a second copy named launcher.bat that this
rem  file just called -- two menu entries for the same thing was
rem  confusing (user asked "why are there two launchers?").
rem  Now there is exactly one menu entry: this file. The other
rem  .bat files are for direct, non-menu actions:
rem    1) 启动器.bat         <- you are here: 菜单（游玩/验收/生成用例/诊断）
rem    2) 运行游戏.bat       <- 直接开跑（先跑 lint + 语法闸门，带崩溃重试）
rem    3) 打开Godot编辑器.bat
rem    4) 诊断Godot启动.bat
rem
rem  The Chinese UI lives in launcher-menu.ps1 (ASCII filename,
rem  so it can be referenced from here without encoding trouble).
rem ============================================================
set "HERE=%~dp0"
set "MENU=%HERE%launcher-menu.ps1"
rem Prefer PowerShell 7 (native UTF-8); fall back to Windows PowerShell 5.1.
set "PS=powershell"
where pwsh >nul 2>&1 && set "PS=pwsh"
if not exist "%MENU%" (
    echo [ERROR] Launcher menu not found:
    echo         %MENU%
    pause
    exit /b 1
)
%PS% -NoProfile -ExecutionPolicy Bypass -File "%MENU%" %*
exit /b %ERRORLEVEL%
