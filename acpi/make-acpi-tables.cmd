@echo off
rem Double-click to build DSDT-TB21LD-SCOPE.aml and APIC-TB21LD-BSP0.aml from this PC's firmware into .\out
rem Options are passed through, e.g.:  make-acpi-tables.cmd -EfiPath E:\EFI-CLEAN-07Y\EFI
setlocal
rem started from PowerShell 7, Windows PowerShell would inherit its module path and miss its own modules
set PSModulePath=
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0make-acpi-tables.ps1" %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (echo Finished. Results are in the out folder, see report.txt.) else (echo Stopped with an error, see above.)
pause
exit /b %RC%
