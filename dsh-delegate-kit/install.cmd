@echo off
rem dsh-delegate-kit double-click installer: menu and prompts are handled by install.ps1 -Interactive
setlocal
cd /d "%~dp0"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Interactive
echo.
pause
endlocal
