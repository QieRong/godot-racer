@echo off
rem ============================================================
rem  Godot Racer - canonical launcher entry (ASCII name + content).
rem
rem  Why a separate ASCII-named entry: any .bat that mentions a
rem  Chinese filename must itself be non-ASCII, and non-ASCII .bat
rem  content is exactly what cmd.exe mangles. So the canonical
rem  entry has an ASCII name; ???.bat is a thin Chinese-named
rem  twin that just calls this one.
rem
rem  The Chinese UI lives in launcher-menu.ps1 (ASCII filename too,
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