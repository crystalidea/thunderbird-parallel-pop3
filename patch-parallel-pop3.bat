@echo off
setlocal

rem Patch a Thunderbird installation for parallel POP3 account checking.
rem
rem Paths are baked in below. Override them by passing arguments:
rem   patch-parallel-pop3.bat "D:\Thunderbird" "G:\Profile"

set "INSTALL=D:\Tools\Net\Thunderbird"
set "PROFILE=G:\Profiles\thunderbird"
if not "%~1"=="" set "INSTALL=%~1"
if not "%~2"=="" set "PROFILE=%~2"

cd /d "%~dp0"

echo.
echo  ==========================================================
echo   parallel-pop3  -  PATCH Thunderbird
echo  ==========================================================
echo.
echo   Installation : %INSTALL%
echo   Profile      : %PROFILE%
echo.
echo   About to:
echo     1. back up omni.ja next to the original
echo     2. replace 4 JavaScript modules inside omni.ja
echo     3. delete the profile's startupCache
echo.
echo   Nothing is written unless all 4 modules match the exact
echo   bytes this patch was built from. Thunderbird must be closed.
echo.
echo   To undo later:
echo     perl patch-parallel-pop3.pl --install "%INSTALL%" --profile "%PROFILE%" --restore
echo.

set "ANSWER="
set /p "ANSWER=  Type YES to proceed (anything else aborts): "
if /i not "%ANSWER%"=="YES" (
    echo.
    echo   Aborted. Nothing was changed.
    goto :end
)
echo.

where perl >nul 2>&1
if errorlevel 1 (
    echo   perl was not found on PATH. Install Strawberry Perl from
    echo   https://strawberryperl.com/ and run this again.
    goto :end
)

perl "%~dp0patch-parallel-pop3.pl" --install "%INSTALL%" --profile "%PROFILE%"

:end
echo.
pause
endlocal
