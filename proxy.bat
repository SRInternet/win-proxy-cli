@echo off
set "_PROXY_SHELL=cmd"
set "_PROXY_OUT=%TEMP%\proxy_act_%RANDOM%_%RANDOM%.cmd"
if exist "%_PROXY_OUT%" del /f /q "%_PROXY_OUT%" >nul 2>nul

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0proxy_core.ps1" %*
set "_PROXY_ERR=%ERRORLEVEL%"

if exist "%_PROXY_OUT%" (
    call "%_PROXY_OUT%"
    del /f /q "%_PROXY_OUT%" >nul 2>nul
)

set "_PROXY_SHELL="
set "_PROXY_OUT="
(set "_PROXY_ERR=" & exit /b %_PROXY_ERR%)