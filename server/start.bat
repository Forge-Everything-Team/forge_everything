@echo off
REM ============================================================
REM  Forge Everything - server launcher
REM
REM  Syncs the pack from the repo, then starts NeoForge.
REM  ALWAYS run this, never run.bat directly - run.bat alone will
REM  start the server with whatever mods it happened to have last.
REM
REM  EDIT THIS: point at the same java.exe your run.bat uses.
REM ============================================================
set JAVA="C:\Program Files\Java\jdk-21\bin\java.exe"

set PACK_URL=https://raw.githubusercontent.com/Rexilyent/forge-everything/main/packwiz/pack.toml

echo Syncing modpack...
%JAVA% -jar packwiz-installer-bootstrap.jar -g -s server %PACK_URL%

if errorlevel 1 (
    echo.
    echo Pack sync FAILED - not starting the server.
    echo A partial mod set fails in ways that look unrelated to the real cause,
    echo so this stops here on purpose. Fix the sync, then run again.
    echo.
    pause
    exit /b 1
)

echo.
echo Starting server...
call run.bat
