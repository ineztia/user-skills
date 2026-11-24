@echo off
REM ============================================================
REM  User Skills Deploy - launcher
REM  Actual logic lives in deploy-skills.ps1; this file only
REM  invokes it with execution policy bypassed.
REM
REM  Target skills dirs (Qoder / CodeBuddy / OpenCode / Trae / Pi / WorkBuddy)
REM  are configured in the $Targets table at the top of deploy-skills.ps1.
REM
REM  Optional args (passed through to the ps1):
REM    -DryRun    Preview differences only, do not modify anything
REM    -Force     Skip all interactive confirmations
REM    -Only X    Deploy only to the given tools, e.g. -Only Qoder,WorkBuddy
REM    -Quick     Fast mode: size+mtime comparison, no hashing
REM    -NoPause   Do not wait for a key press at the end
REM ============================================================
setlocal
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy-skills.ps1" %*
if errorlevel 1 (
    echo.
    echo Deploy script exited with errors, see output above.
    pause
)
endlocal
