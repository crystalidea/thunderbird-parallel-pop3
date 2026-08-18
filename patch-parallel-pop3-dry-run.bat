@echo off
setlocal

rem Verify a Thunderbird installation without changing anything.
rem
rem Paths are baked in below. Override them by passing arguments:
rem   patch-parallel-pop3-dry-run.bat "D:\Thunderbird" "G:\Profile"

set "INSTALL=D:\Tools\Net\Thunderbird"
set "PROFILE=G:\Profiles\thunderbird"
if not "%~1"=="" set "INSTALL=%~1"
if not "%~2"=="" set "PROFILE=%~2"

cd /d "%~dp0"

echo.
echo  ==========================================================
echo   parallel-pop3  -  DRY RUN, nothing will be written
echo  ==========================================================
echo.
echo   Installation : %INSTALL%
echo   Profile      : %PROFILE%
echo.

where perl >nul 2>&1
if errorlevel 1 (
    echo   perl was not found on PATH. Install Strawberry Perl from
    echo   https://strawberryperl.com/ and run this again.
    goto :end
)

perl "%~dp0patch-parallel-pop3.pl" --install "%INSTALL%" --profile "%PROFILE%" --dry-run

:end
echo.
pause
endlocal
