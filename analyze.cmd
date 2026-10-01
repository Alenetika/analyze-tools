@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

rem FIX: setup.ps1 принимает только -Force, не пробрасываем ему %*
rem      иначе -Path/-Profile и т.п. вызовут ошибку параметра.
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%setup.ps1"
if errorlevel 1 (
    echo Setup failed.
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%analyze.ps1" %*
endlocal