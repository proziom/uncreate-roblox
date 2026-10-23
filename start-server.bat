@echo off
rem Uncreate server: edit the three lines below, then double-click this file.
rem PROJECT is the project name and the folder it is stored in (no spaces).
set PROJECT=MyGame
set KEY=test
set PORT=7878
title Uncreate - %PROJECT%
if not exist "%~dp0bin\uncreate-server.exe" goto :missing
echo Uncreate server for "%PROJECT%". Keep this window open while you work.
echo.
"%~dp0bin\uncreate-server.exe" --port %PORT% --key %KEY% --data "%~dp0%PROJECT%"
pause
exit /b

:missing
echo bin\uncreate-server.exe is missing: this folder is the source code.
echo Download the ready-to-run archive from the Releases page of the repository.
pause
exit /b 1
