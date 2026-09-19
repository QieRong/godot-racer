@echo off
rem ============================================================
rem  运行 Godot 赛车游戏
rem
rem  为什么要用 .bat 而不是 .lnk：
rem    .lnk 快捷方式里存的是**绝对路径**，文件夹一改名/移动就失效。
rem    本文件用 %~dp0（自身所在目录）定位，整条命令里没有任何写死的路径，
rem    所以整个 data-analysis 文件夹随便改名、剪切、换盘都不会坏。
rem
rem  --log-file 不能删：Godot 无法写 user:// 目录时会在启动期空指针崩溃
rem  （报错 "0x...60 内存不能为 read"），把日志重定向到可写位置即可绕开。
rem ============================================================
chcp 65001 >nul
cd /d "%~dp0..\godot-racer"
if not exist "project.godot" (
    echo [错误] 找不到 Godot 项目：%CD%
    echo        期望在 04-Godot启动器 的同级目录下有个 godot-racer 文件夹
    pause
    exit /b 1
)
if not exist "E:\godot\Godot_v4.4.1-stable_win64.exe" (
    echo [错误] 找不到 Godot：E:\godot\Godot_v4.4.1-stable_win64.exe
    echo        可用 04-Godot启动器 里的 install_godot.ps1 重新安装
    pause
    exit /b 1
)
start "" "E:\godot\Godot_v4.4.1-stable_win64.exe" --path . --log-file "%~dp0..\godot-logs\game.log"
exit /b 0
