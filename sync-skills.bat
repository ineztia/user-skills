@echo off
REM ============================================================
REM  User Skills 一键同步脚本
REM  将本仓库下所有 _xxx 技能目录镜像同步到各 AI 工具的 skills 目录
REM  同步策略：robocopy /MIR（目标 = 源，多余文件/目录会被清理）
REM ============================================================
setlocal EnableDelayedExpansion
chcp 65001 >nul

REM ========== [需要时修改这里] 目标路径配置 ==========
set "TARGET_QODER=%USERPROFILE%\.qoder\skills"
set "TARGET_CODEBUDDY=%USERPROFILE%\.codebuddy\skills"
set "TARGET_OPENCODE=%USERPROFILE%\.config\opencode\skills"
set "TARGET_TRAE=%USERPROFILE%\.trae-cn\skills"
REM ===================================================

REM 源目录 = 本脚本所在目录（去掉末尾反斜杠）
set "SRC=%~dp0"
if "%SRC:~-1%"=="\" set "SRC=%SRC:~0,-1%"

echo ============================================================
echo   User Skills Sync
echo   Source: %SRC%
echo ============================================================
echo.

REM ========== 前置安全校验（任一失败 -> 整体 abort）==========
set "VALIDATE_FAILED=0"

REM 1) 源目录下至少有 1 个 _xxx 技能目录
set "SRC_COUNT=0"
for /d %%D in ("%SRC%\_*") do set /a SRC_COUNT+=1
if !SRC_COUNT! equ 0 (
    echo [ABORT] 源目录下未找到任何 _xxx 技能目录:
    echo         %SRC%
    echo         为避免误清空目标，脚本中止。
    echo.
    pause
    exit /b 1
)

REM 2) 逐个校验目标路径（非空 / 含盘符 / 非盘根 / 与源无重叠）
call :validate_target "Qoder"     "%TARGET_QODER%"
call :validate_target "CodeBuddy" "%TARGET_CODEBUDDY%"
call :validate_target "OpenCode"  "%TARGET_OPENCODE%"
call :validate_target "Trae"      "%TARGET_TRAE%"

if !VALIDATE_FAILED! neq 0 (
    echo.
    echo [ABORT] 目标路径校验未通过，脚本中止。
    echo         请检查顶部 TARGET_XXX 配置后重试。
    echo.
    pause
    exit /b 1
)

echo [OK] 前置校验通过：源目录含 !SRC_COUNT! 个 _xxx 技能目录，4 个目标路径均有效。
echo.

set "FAIL_COUNT=0"

REM ---- 安全确认：开始执行镜像同步（全局一次）----
echo 即将将 %SRC% 下的 _xxx 技能目录镜像同步到：
echo   - %TARGET_QODER%
echo   - %TARGET_CODEBUDDY%
echo   - %TARGET_OPENCODE%
echo   - %TARGET_TRAE%
echo.
choice /c YN /n /m ">> 是否开始执行镜像同步? (Y/N): "
if errorlevel 2 (
    echo 已取消，未执行任何操作。
    echo.
    pause
    exit /b 0
)
echo.

call :sync_one "Qoder"     "%TARGET_QODER%"
call :sync_one "CodeBuddy" "%TARGET_CODEBUDDY%"
call :sync_one "OpenCode"  "%TARGET_OPENCODE%"
call :sync_one "Trae"      "%TARGET_TRAE%"

echo.
echo ============================================================
if "%FAIL_COUNT%"=="0" (
    echo   全部同步完成 ^(success^)
) else (
    echo   同步完成，但有 %FAIL_COUNT% 个错误，请查看上方日志
)
echo ============================================================
pause
exit /b 0


REM ============================================================
REM :sync_one  <工具名>  <目标skills目录>
REM   1) 将源目录下每个 _xxx 文件夹镜像到  <目标>\_xxx
REM   2) 删除目标目录中在源里已不存在的 _xxx 文件夹
REM ============================================================
:sync_one
set "NAME=%~1"
set "DST=%~2"

echo ------------------------------------------------------------
echo  [%NAME%]  -^>  %DST%
echo ------------------------------------------------------------

if not exist "%DST%" (
    mkdir "%DST%" 2>nul
    if errorlevel 1 (
        echo   [FAIL] 无法创建目标目录，跳过
        set /a FAIL_COUNT+=1
        goto :eof
    )
)

REM 1) 镜像每个 _xxx 目录
for /d %%D in ("%SRC%\_*") do (
    robocopy "%%D" "%DST%\%%~nxD" /MIR /XD .git .qoder /XF *.bak /NFL /NDL /NJH /NJS /NP >nul
    if errorlevel 8 (
        echo   [FAIL] %%~nxD
        set /a FAIL_COUNT+=1
    ) else (
        echo   [ OK ] %%~nxD
    )
)

REM 2) 检测目标中源已不存在的 _xxx 目录
set "STALE_COUNT=0"
for /d %%D in ("%DST%\_*") do (
    if not exist "%SRC%\%%~nxD" set /a STALE_COUNT+=1
)

if !STALE_COUNT! gtr 0 (
    echo   发现 !STALE_COUNT! 个多余目录 ^(源已不存在^):
    for /d %%D in ("%DST%\_*") do (
        if not exist "%SRC%\%%~nxD" echo     - %%~nxD
    )
    REM ---- 安全确认：是否删除这些多余目录 ----
    choice /c YN /n /m "  >> 是否删除以上多余目录? (Y/N): "
    if errorlevel 2 (
        echo   [SKIP] 已保留多余目录，未删除
    ) else (
        for /d %%D in ("%DST%\_*") do (
            if not exist "%SRC%\%%~nxD" (
                echo   [DEL ] %%~nxD
                rmdir /s /q "%%D"
            )
        )
    )
)

echo.
goto :eof


REM ============================================================
REM :validate_target  <工具名>  <目标路径>
REM   校验非空 / 含盘符 / 非盘根 / 与 SRC 无重叠
REM   失败则置 VALIDATE_FAILED=1
REM ============================================================
:validate_target
set "_NAME=%~1"
set "_DST=%~2"

REM 非空
if "%_DST%"=="" (
    echo   [FAIL] [%_NAME%] 目标路径为空
    set "VALIDATE_FAILED=1"
    goto :eof
)

REM 去掉末尾反斜杠
set "_CLEAN=%_DST%"
if "%_CLEAN:~-1%"=="\" set "_CLEAN=%_CLEAN:~0,-1%"

REM 含盘符 X:
echo %_CLEAN% | findstr /r /b /c:"[A-Za-z]:" >nul
if errorlevel 1 (
    echo   [FAIL] [%_NAME%] 目标路径缺少盘符: %_DST%
    set "VALIDATE_FAILED=1"
    goto :eof
)

REM 不能是盘根（X: 或 X:\）
if "%_CLEAN:~1%"==":" (
    echo   [FAIL] [%_NAME%] 目标路径不能是盘根: %_DST%
    set "VALIDATE_FAILED=1"
    goto :eof
)

REM 不能等于源
if /i "%_CLEAN%"=="%SRC%" (
    echo   [FAIL] [%_NAME%] 目标路径不能与源目录相同: %_DST%
    set "VALIDATE_FAILED=1"
    goto :eof
)

REM 目标不能是源的父目录（SRC 以 DST\ 开头）
(echo %SRC%\)| findstr /b /i /c:"%_CLEAN%\" >nul
if not errorlevel 1 (
    echo   [FAIL] [%_NAME%] 目标路径是源目录的父目录，禁止: %_DST%
    set "VALIDATE_FAILED=1"
    goto :eof
)

REM 目标不能在源目录内（DST 以 SRC\ 开头）
(echo %_CLEAN%\)| findstr /b /i /c:"%SRC%\" >nul
if not errorlevel 1 (
    echo   [FAIL] [%_NAME%] 目标路径在源目录内部，禁止: %_DST%
    set "VALIDATE_FAILED=1"
    goto :eof
)

goto :eof
