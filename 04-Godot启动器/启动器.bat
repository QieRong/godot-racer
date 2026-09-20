@echo off
rem Chinese-named twin of launcher.bat (content is ASCII-only:
rem a .bat that contains Chinese gets mangled by cmd.exe).
call "%~dp0launcher.bat" %*
exit /b %ERRORLEVEL%