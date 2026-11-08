@echo off
title DSH 插件离线安装
echo.
echo ==================================================
echo   DSH 插件离线安装工具
echo   使用前请先在托盘完全退出 DSH
echo ==================================================
echo.
set /p PKG=请输入插件包名（例如 dsh-computer-use-win）:
if "%PKG%"=="" goto end
echo.
set /p VER=指定版本（直接回车表示装最新版）:
echo.
if "%VER%"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-install-plugin.ps1" "%PKG%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-install-plugin.ps1" "%PKG%" "%VER%"
)
echo.
:end
pause
