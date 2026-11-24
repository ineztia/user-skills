#requires -Version 5.1
<#
.SYNOPSIS
    User Skills 一键部署脚本（PowerShell 版）
    将本仓库下所有 z-xxx 技能目录镜像部署到各 AI 工具的 skills 目录。

    注：本脚本与 git 无关（不涉及 git pull/push），仅做本地目录镜像。

.DESCRIPTION
    相比旧版 deploy-skills.bat（robocopy /MIR），本版改进：
      1. 差异分析（dry-run）：先算出 新增/修改/删除/多余 清单，确认后才执行；
      2. 内容级检测：默认对时间戳有差异的文件做 SHA256 比对，避免误报/漏报；
      3. 文件级删除也要单独确认（不再静默清理）；
      4. 同步后哈希复检，确认每个文件真的同步成功；
      5. 跳过符号链接/junction 并警告（防复制/删除到链接指向的目录）；
      6. 校验每个 skill 的 SKILL.md 存在性及 name 与目录名一致性；
      7. 文件级错误明细 + 落盘日志（logs\deploy-时间戳.log）；
      8. 部署清单（.deployed-skills.json）：区分「本脚本部署的旧技能」与「外部安装的技能」。

    安全设计（防误删）：
      a. 删除目录前先断开树内所有 junction/符号链接（只删链接本身），
         避免递归删除跟随链接清掉外部目录内容；
      b. 所有删除/拷贝路径在执行前做"必须位于目标 skills 目录内"断言；
      c. 目标路径校验前先做完整路径规范化（防 .. 绕过嵌套校验）；
      d. 相对路径计算越界即抛错，杜绝路径逃逸；
      e. 删除操作独立于拷贝操作，需单独确认（-Force 除外）；
      f. 只清理部署清单内的 z-* 项：清单外的 z-* 目录/文件一律视为外部安装、保留不动；
         无清单时不执行任何清理（首次运行保护）。清单文件本身不参与镜像。

.PARAMETER DryRun
    只做差异分析并预览，不执行任何修改。

.PARAMETER Force
    跳过所有交互确认（包括删除确认，谨慎使用）。

.PARAMETER Only
    只同步指定工具，例如: -Only Qoder,WorkBuddy（不指定则同步全部）。

.PARAMETER Quick
    快速模式：时间戳/大小有差异即视为修改，不做哈希比对。

.PARAMETER NoPause
    结束后不暂停等待按键（供自动化调用）。

.EXAMPLE
    .\deploy-skills.ps1 -DryRun            # 先看差异
    .\deploy-skills.ps1                    # 正常交互部署
    .\deploy-skills.ps1 -Only Qoder -Force # 只部署到 Qoder 且跳过确认
    .\deploy-skills.ps1 -Only WorkBuddy    # 只部署到 WorkBuddy
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Force,
    [string[]]$Only,
    [switch]$Quick,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

# ========== [需要时修改这里] 目标路径配置 ==========
$Targets = [ordered]@{
    'Qoder'     = Join-Path $env:USERPROFILE '.qoder\skills'
    'CodeBuddy' = Join-Path $env:USERPROFILE '.codebuddy\skills'
    'OpenCode'  = Join-Path $env:USERPROFILE '.config\opencode\skills'
    'Trae'      = Join-Path $env:USERPROFILE '.trae-cn\skills'
    'Pi'        = Join-Path $env:USERPROFILE '.pi\agent\skills'
    'WorkBuddy' = Join-Path $env:USERPROFILE '.workbuddy\skills'
}
# ===================================================

# 排除规则（对应旧版 robocopy 的 /XD .git .qoder /XF *.bak）
$ExcludeDirNames = @('.git', '.qoder')
$ExcludeFileExt  = '.bak'
# 工具自有运行时文件：只存在于目标侧（如 WorkBuddy 的 _user_meta.json），
# 镜像时既不复制、也不当作"多余文件"删除。
$ExcludeFileNames = @('_user_meta.json')

# 部署清单：记录"被本脚本接管"的技能名，存于各目标 skills 目录根下，仅由本脚本维护。
# 作用：只有清单内、且源中已不存在的 z-* 项才会被当作多余清理；
#       清单外的 z-* 项（其他途径安装的技能）一律保留不动；无清单则完全不做清理。
$ManifestFileName = '.deployed-skills.json'
$ManifestVersion  = 1

# ---------- 全局状态 ----------
$Script:LogFile  = $null
$Script:FailList = [System.Collections.Generic.List[string]]::new()
$Script:Warnings = [System.Collections.Generic.List[string]]::new()
$Script:WarnSet  = [System.Collections.Generic.HashSet[string]]::new()

$Src = $PSScriptRoot
if (-not $Src) { $Src = Split-Path $MyInvocation.MyCommand.Path }
$Src = [System.IO.Path]::GetFullPath($Src).TrimEnd('\')

# ============================================================
#  工具函数
# ============================================================
function Write-Log {
    param(
        [string]$Message = '',
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [switch]$NoNewline
    )
    if ($NoNewline) { Write-Host -NoNewline $Message -ForegroundColor $Color }
    else            { Write-Host $Message -ForegroundColor $Color }
    # 日志写入失败不应导致脚本崩溃（日志是辅助功能）
    if ($Script:LogFile) {
        try {
            $text = if ($NoNewline) { $Message } else { $Message + [Environment]::NewLine }
            [System.IO.File]::AppendAllText($Script:LogFile, $text)
        } catch {}
    }
}

function Add-Warning {
    param([string]$Message)
    if ($Script:WarnSet.Add($Message)) { $Script:Warnings.Add($Message) }
}

# 相对路径计算：越界即抛错（防路径逃逸，安全兜底）
function Get-RelativePath {
    param([string]$Path, [string]$Base)
    $p = $Path.TrimEnd('\')
    $b = $Base.TrimEnd('\')
    if ($p.StartsWith($b + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $p.Substring($b.Length + 1)
    }
    throw "路径不在基目录内（安全拦截）: Path='$Path' Base='$Base'"
}

# 运行时断言：$Path 必须位于 $Base 内部（防误删/误写到目录外）
function Test-PathUnder {
    param([string]$Path, [string]$Base)
    try {
        $p = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        $b = [System.IO.Path]::GetFullPath($Base).TrimEnd('\')
    } catch { return $false }
    return $p.StartsWith($b + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Confirm-YesNo {
    param([string]$Prompt)
    if ($Force) { return $true }
    while ($true) {
        $answer = Read-Host "$Prompt [y/N]"
        if ($answer -match '^[yY]$') { return $true }
        if ($answer -match '^[nN]$' -or $answer -eq '') { return $false }
        Write-Log "  请输入 y 或 n" -Color Yellow
    }
}

function Exit-Abort {
    param([string]$Message, [int]$Code = 1)
    Write-Log $Message -Color Red
    if (-not $NoPause) { Read-Host "按回车键退出..." }
    exit $Code
}

# 递归枚举目录树（跳过排除目录 / 排除扩展名 / 符号链接），返回 @{ Files; Dirs }
function Get-TreeEntries {
    param([string]$Root)
    $files = [System.Collections.Generic.List[object]]::new()
    $dirs  = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($ExcludeDirNames -contains $sub.Name) { continue }
            if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Add-Warning "跳过符号链接/junction（不跟随、不删除）: $($sub.FullName)"
                continue
            }
            $dirs.Add((Get-RelativePath $sub.FullName $Root))
            $stack.Push($sub.FullName)
        }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)) {
            if ($f.Extension -ieq $ExcludeFileExt) { continue }
            if ($ExcludeFileNames -contains $f.Name) { continue }
            if ($f.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Add-Warning "跳过符号链接文件（不跟随）: $($f.FullName)"
                continue
            }
            $files.Add([PSCustomObject]@{
                FullName         = $f.FullName
                Rel              = Get-RelativePath $f.FullName $Root
                Length           = $f.Length
                LastWriteTimeUtc = $f.LastWriteTimeUtc
            })
        }
    }
    return @{ Files = $files; Dirs = $dirs }
}

# 统计目录内文件数（不跟随链接，用于删除前展示规模）
function Get-TreeFileCount {
    param([string]$Root)
    $n = 0
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $stack.Push($sub.FullName)
        }
        $n += @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue).Count
    }
    return $n
}

# 删除文件后逐级清理空父目录（不会删到 $StopAt 本身）
function Remove-EmptyParents {
    param([string]$File, [string]$StopAt)
    $stop = $StopAt.TrimEnd('\')
    $d = Split-Path $File -Parent
    while ($d -and $d.TrimEnd('\') -ne $stop) {
        if (-not (Test-Path -LiteralPath $d)) { break }
        $children = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)
        if ($children.Count -ne 0) { break }
        try { Remove-Item -LiteralPath $d -Force -ErrorAction Stop } catch { break }
        $d = Split-Path $d -Parent
    }
}

# 安全删除目录：先断开树内所有 junction/符号链接（只删链接本身），再递归删除。
# 防止 Remove-Item -Recurse 在某些 PowerShell 版本/补丁级别下跟随链接、清掉链接目标内容。
function Remove-DirectorySafe {
    param([string]$Path)
    # 1) 收集树内所有 reparse 目录（不进入链接内部）
    $links = [System.Collections.Generic.List[string]]::new()
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($sub in @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                $links.Add($sub.FullName)
            } else {
                $stack.Push($sub.FullName)
            }
        }
    }
    # 2) 先断开所有链接（[System.IO.Directory]::Delete 只删链接本身，不触碰目标内容）。
    #    若断开失败则中止整个目录的删除——绝不在链接仍存活时递归删除。
    foreach ($link in $links) {
        try {
            [System.IO.Directory]::Delete($link)
            Write-Log "    已断开链接: $link" -Color DarkYellow
        } catch {
            throw "无法断开链接，已中止删除该目录: $link ($($_.Exception.Message))"
        }
    }
    # 3) 树内已无链接，正常递归删除
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

# 目标路径合法性校验，返回错误信息字符串（$null = 通过）
function Test-TargetPath {
    param([string]$Name, [string]$Dst)
    if ([string]::IsNullOrWhiteSpace($Dst)) { return "目标路径为空" }
    # 先完整规范化（解析 .. 等），再做比较——防绕过
    try { $clean = [System.IO.Path]::GetFullPath($Dst.TrimEnd('\')).TrimEnd('\') }
    catch { return "路径格式非法: $Dst ($($_.Exception.Message))" }
    if ($clean -notmatch '^[A-Za-z]:') { return "缺少盘符（不支持 UNC/相对路径）: $Dst" }
    if ($clean.Length -eq 2) { return "不能是盘根: $Dst" }
    if ($clean -ieq $Src) { return "与源目录相同: $Dst" }
    if ($Src.StartsWith($clean + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return "是源目录的父目录，禁止: $Dst" }
    if ($clean.StartsWith($Src + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return "位于源目录内部，禁止: $Dst" }
    if (Test-Path -LiteralPath $clean) {
        $item = Get-Item -LiteralPath $clean -Force
        if (-not $item.PSIsContainer) { return "已存在但不是目录: $Dst" }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return "是符号链接/junction，拒绝镜像: $Dst" }
    }
    return $null
}

# 读取目标侧部署清单。返回 $null 表示"无清单/无法解析"（两种情况都不做历史清理）
function Read-DeployManifest {
    param([string]$Dst)
    $p = Join-Path $Dst $ManifestFileName
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    try {
        $obj = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $names = @()
        if ($obj -and ($obj.PSObject.Properties.Name -contains 'skills')) {
            $names = @($obj.skills | Where-Object { $_ -is [string] -and $_.Trim() } | ForEach-Object { $_.Trim() })
        }
        return @{ Skills = $names; Path = $p }
    } catch {
        Add-Warning "部署清单无法解析，本次按「无清单」处理（不做历史清理）: $p"
        return $null
    }
}

# 写入目标侧部署清单（失败计入错误清单——清单缺失会削弱清理保护，必须可见）
function Write-DeployManifest {
    param([string]$Dst, [string[]]$SkillNames)
    $p = Join-Path $Dst $ManifestFileName
    try {
        if (-not (Test-Path -LiteralPath $Dst)) { New-Item -ItemType Directory -Path $Dst -Force -ErrorAction Stop | Out-Null }
        $obj = [ordered]@{
            version = $ManifestVersion
            source  = $Src
            updated = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
            skills  = @($SkillNames | Where-Object { $_ } | Sort-Object -Unique)
        }
        $json = ($obj | ConvertTo-Json -Depth 4)
        [System.IO.File]::WriteAllText($p, $json, [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch {
        $Script:FailList.Add("部署清单写入失败: $p  ($($_.Exception.Message))")
        return $false
    }
}

# 执行后刷新清单：受管集合 = 源技能名 ∪ 原清单名，且仍实际存在于目标目录中。
# 删除被拒绝或删除失败的项会继续保留在清单里，下次仍会被提示清理。
function Update-DeployManifests {
    param([object[]]$Diffs, [string[]]$SrcNames)
    foreach ($d in $Diffs) {
        if (-not (Test-Path -LiteralPath $d.Dst)) { continue }
        $prev = @()
        $m = Read-DeployManifest -Dst $d.Dst
        if ($m) { $prev = @($m.Skills) }
        $keep = @()
        foreach ($n in @(@($SrcNames) + @($prev) | Sort-Object -Unique)) {
            if (Test-Path -LiteralPath (Join-Path $d.Dst $n)) { $keep += $n }
        }
        if (Write-DeployManifest -Dst $d.Dst -SkillNames $keep) {
            Write-Log ("  [{0}] 部署清单已更新：受管技能 {1} 个" -f $d.Tool, $keep.Count) -Color DarkGray
        }
    }
}

# 校验 SKILL.md 元数据，返回警告信息字符串（$null = 通过）
function Test-SkillMeta {
    param([string]$SkillDir)
    $name = Split-Path $SkillDir -Leaf
    $md = Join-Path $SkillDir 'SKILL.md'
    if (-not (Test-Path -LiteralPath $md)) { return "缺少 SKILL.md: $name" }
    $head = @(Get-Content -LiteralPath $md -TotalCount 30 -Encoding UTF8 -ErrorAction SilentlyContinue)
    $nameLine = $head | Where-Object { $_ -match '^\s*name\s*:' } | Select-Object -First 1
    if (-not $nameLine) { return "SKILL.md 未找到 name 字段: $name" }
    $declared = ($nameLine -replace '^\s*name\s*:\s*', '').Trim().Trim('"').Trim("'")
    if ($declared -ne $name) { return "name 字段($declared) 与目录名($name) 不一致" }
    return $null
}

# 对比单个 skill 的源/目标文件树（文件级 + 目录级）
function Compare-SkillTree {
    param([hashtable]$SrcTree, [string]$DstSkillDir, [switch]$Quick)
    $srcMap = @{}
    foreach ($f in $SrcTree.Files) { $srcMap[$f.Rel] = $f }
    $srcDirs = @{}
    foreach ($d in $SrcTree.Dirs) { $srcDirs[$d] = $true }

    $dstMap = @{}; $dstDirs = @{}
    if (Test-Path -LiteralPath $DstSkillDir) {
        $dstTree = Get-TreeEntries -Root $DstSkillDir
        foreach ($f in $dstTree.Files) { $dstMap[$f.Rel] = $f }
        foreach ($d in $dstTree.Dirs)  { $dstDirs[$d] = $true }
    }

    $added = @(); $modified = @(); $removed = @()
    foreach ($rel in $srcMap.Keys) {
        if (-not $dstMap.ContainsKey($rel)) { $added += $rel; continue }
        $s = $srcMap[$rel]; $d = $dstMap[$rel]
        if ($s.Length -eq $d.Length -and $s.LastWriteTimeUtc -eq $d.LastWriteTimeUtc) { continue }
        if ($Quick) { $modified += $rel; continue }
        # 时间戳/大小有差异，用哈希确认是否真的变了（防误报，也防漏报）
        try {
            $h1 = (Get-FileHash -LiteralPath $s.FullName -Algorithm SHA256).Hash
            $h2 = (Get-FileHash -LiteralPath $d.FullName -Algorithm SHA256).Hash
            if ($h1 -ne $h2) { $modified += $rel }
        } catch {
            $modified += $rel
            Add-Warning "哈希计算失败，按已修改处理: $rel ($($_.Exception.Message))"
        }
    }
    foreach ($rel in $dstMap.Keys) {
        if (-not $srcMap.ContainsKey($rel)) { $removed += $rel }
    }
    # 目录级：目标中源不存在的目录（含空目录），随镜像一并清理
    $removedDirs = @()
    foreach ($d in $dstDirs.Keys) {
        if (-not $srcDirs.ContainsKey($d)) { $removedDirs += $d }
    }
    return @{ Added = $added; Modified = $modified; Removed = $removed; RemovedDirs = $removedDirs }
}

function Show-Diff {
    param($Diff)
    Write-Log ""
    Write-Log ("[{0}] -> {1}" -f $Diff.Tool, $Diff.Dst) -Color Cyan
    if ($Diff.ManifestMissing) {
        Write-Log ("  · 尚无部署清单 {0}：本次不做历史清理（执行后自动建立）" -f $ManifestFileName) -Color DarkGray
    } else {
        Write-Log ("  · 部署清单: 受管技能 {0} 个" -f $Diff.Managed.Count) -Color DarkGray
    }
    $total = $Diff.Add.Count + $Diff.Mod.Count + $Diff.Del.Count + $Diff.DelDirs.Count + $Diff.Extra.Count
    if ($total -eq 0) {
        Write-Log "  OK 已是最新，无需同步" -Color Green
    } else {
        if ($Diff.Add.Count -gt 0) {
            Write-Log ("  + 新增 {0} 个文件:" -f $Diff.Add.Count) -Color Green
            foreach ($f in $Diff.Add) { Write-Log "      + $f" -Color DarkGreen }
        }
        if ($Diff.Mod.Count -gt 0) {
            Write-Log ("  ~ 修改 {0} 个文件:" -f $Diff.Mod.Count) -Color Yellow
            foreach ($f in $Diff.Mod) { Write-Log "      ~ $f" -Color DarkYellow }
        }
        if ($Diff.Del.Count -gt 0) {
            Write-Log ("  - 删除 {0} 个文件:" -f $Diff.Del.Count) -Color Red
            foreach ($f in $Diff.Del) { Write-Log "      - $f" -Color DarkRed }
        }
        if ($Diff.DelDirs.Count -gt 0) {
            Write-Log ("  - 删除 {0} 个目录:" -f $Diff.DelDirs.Count) -Color Red
            foreach ($f in $Diff.DelDirs) { Write-Log "      - $f\" -Color DarkRed }
        }
        if ($Diff.Extra.Count -gt 0) {
            Write-Log ("  ! 待清理技能 {0} 个（清单内、源已不存在）:" -f $Diff.Extra.Count) -Color Red
            foreach ($f in $Diff.Extra) {
                $full = Join-Path $Diff.Dst $f
                $suffix = ''
                if (Test-Path -LiteralPath $full -PathType Container) { $suffix = "  ($(Get-TreeFileCount -Root $full) 个文件)" }
                Write-Log ("      ! $f$suffix") -Color DarkRed
            }
        }
    }
    # 外来项与"无差异"无关，始终单独列出（不计入待处理的 total）
    if ($Diff.Legacy.Count -gt 0) {
        Write-Log ("  · 外来技能 {0} 个（不在部署清单内，保留不动）:" -f $Diff.Legacy.Count) -Color DarkGray
        foreach ($f in $Diff.Legacy) {
            $full = Join-Path $Diff.Dst $f
            $suffix = ''
            if (Test-Path -LiteralPath $full -PathType Container) { $suffix = "  ($(Get-TreeFileCount -Root $full) 个文件)" }
            Write-Log ("      · $f$suffix") -Color DarkGray
        }
    }
    if ($Diff.Foreign.Count -gt 0) {
        Write-Log ("  · 无关项 {0} 个（保留不动）: {1}" -f $Diff.Foreign.Count, ($Diff.Foreign -join ', ')) -Color DarkGray
    }
}

function Invoke-Copy {
    param([object[]]$RelList, [string]$Dst)
    $n = 0
    foreach ($rel in $RelList) {
        $dstFull = Join-Path $Dst $rel
        if (-not (Test-PathUnder $dstFull $Dst)) {
            $Script:FailList.Add("拒绝写入（路径越界，安全拦截）: $rel")
            continue
        }
        $srcFull = Join-Path $Src $rel
        try {
            $dstDir = Split-Path $dstFull -Parent
            if (-not (Test-Path -LiteralPath $dstDir)) {
                New-Item -ItemType Directory -Path $dstDir -Force -ErrorAction Stop | Out-Null
            }
            Copy-Item -LiteralPath $srcFull -Destination $dstFull -Force -ErrorAction Stop
            $n++
        } catch {
            $Script:FailList.Add("复制失败: $rel  ->  $dstFull  ($($_.Exception.Message))")
        }
    }
    return $n
}

function Invoke-Delete {
    param([object[]]$RelList, [string]$Dst)
    $n = 0
    foreach ($rel in $RelList) {
        $dstFull = Join-Path $Dst $rel
        if (-not (Test-PathUnder $dstFull $Dst)) {
            $Script:FailList.Add("拒绝删除（路径越界，安全拦截）: $rel")
            continue
        }
        try {
            if (Test-Path -LiteralPath $dstFull) {
                $isDir = (Get-Item -LiteralPath $dstFull -Force -ErrorAction Stop).PSIsContainer
                if ($isDir) {
                    Remove-DirectorySafe -Path $dstFull
                } else {
                    Remove-Item -LiteralPath $dstFull -Force -ErrorAction Stop
                    Remove-EmptyParents -File $dstFull -StopAt $Dst
                }
                $n++
            }
        } catch {
            $Script:FailList.Add("删除失败: $rel  ($($_.Exception.Message))")
        }
    }
    return $n
}

function Invoke-Verify {
    param([object[]]$RelList, [string]$Dst)
    $ok = 0
    foreach ($rel in $RelList) {
        $srcFull = Join-Path $Src $rel
        $dstFull = Join-Path $Dst $rel
        try {
            $h1 = (Get-FileHash -LiteralPath $srcFull -Algorithm SHA256).Hash
            $h2 = (Get-FileHash -LiteralPath $dstFull -Algorithm SHA256).Hash
            if ($h1 -eq $h2) { $ok++ } else {
                $Script:FailList.Add("校验不一致（内容不同）: $rel")
            }
        } catch {
            $Script:FailList.Add("校验失败: $rel  ($($_.Exception.Message))")
        }
    }
    return $ok
}

# ============================================================
#  主流程
# ============================================================
try {
    # ---- 0. 初始化：编码 / 日志 ----
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    $logDir = Join-Path $Src 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $Script:LogFile = Join-Path $logDir ("deploy-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    # 清理 30 天前的旧日志
    @(Get-ChildItem -LiteralPath $logDir -Filter 'deploy-*.log' -File -ErrorAction SilentlyContinue) |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Log ""
    Write-Log "============================================================" -Color Cyan
    Write-Log "  User Skills Deploy  (PowerShell)" -Color Cyan
    Write-Log "  Source: $Src" -Color Cyan
    Write-Log "  时间:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color Cyan
    Write-Log "  模式:   $(if ($DryRun) { 'DryRun（仅预览）' } elseif ($Quick) { 'Quick（快速比对）' } else { '标准（SHA256 比对）' })" -Color Cyan
    Write-Log "============================================================" -Color Cyan

    # ---- 1. 参数校验 ----
    if ($Only.Count -gt 0) {
        foreach ($name in $Only) {
            if (-not $Targets.Contains($name)) {
                Exit-Abort "[ABORT] 未知工具名: $name（可用: $($Targets.Keys -join ', ')）"
            }
        }
    }

    # ---- 2. 源校验 ----
    if (-not (Test-Path -LiteralPath $Src -PathType Container)) {
        Exit-Abort "[ABORT] 源目录不存在: $Src"
    }
    $skills = @(Get-ChildItem -LiteralPath $Src -Directory -Filter 'z-*' -Force -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($skills.Count -eq 0) {
        Exit-Abort "[ABORT] 源目录下未找到任何 z-xxx 技能目录。为避免误清空目标，脚本中止。  $Src"
    }
    Write-Log ("[OK] 源校验通过：{0} 个 z-xxx 技能目录" -f $skills.Count) -Color Green

    # SKILL.md 元数据校验（警告不中止）
    foreach ($skill in $skills) {
        $metaIssue = Test-SkillMeta -SkillDir $skill.FullName
        if ($metaIssue) { Add-Warning "技能元数据问题: $metaIssue" }
    }

    # ---- 3. 目标校验 ----
    $targetFailed = $false
    foreach ($entry in $Targets.GetEnumerator()) {
        $err = Test-TargetPath -Name $entry.Key -Dst $entry.Value
        if ($err) {
            Write-Log ("[FAIL] 目标路径校验: [{0}] {1}" -f $entry.Key, $err) -Color Red
            $targetFailed = $true
        }
    }
    if ($targetFailed) {
        Exit-Abort "[ABORT] 目标路径校验未通过，脚本中止。请检查顶部 TARGET 配置。"
    }
    Write-Log ("[OK] 目标路径校验通过：{0} 个目标均有效。" -f $Targets.Count) -Color Green

    # ---- 4. 构建源文件索引（每个 skill 枚举一次，供各目标复用）----
    $srcIndex = @{}
    foreach ($skill in $skills) {
        $tree = Get-TreeEntries -Root $skill.FullName
        if ($tree.Files.Count -eq 0) {
            Add-Warning "源技能目录为空（同步后将清空目标对应目录）: $($skill.Name)"
        }
        $srcIndex[$skill.Name] = $tree
    }
    $srcNames = @($skills | ForEach-Object { $_.Name })

    # ---- 5. 差异分析（dry-run 核心）----
    $diffs = @()
    foreach ($entry in $Targets.GetEnumerator()) {
        if ($Only.Count -gt 0 -and $Only -notcontains $entry.Key) { continue }
        $dst = $entry.Value.TrimEnd('\')
        $manifest = Read-DeployManifest -Dst $dst
        $managed  = if ($manifest) { @($manifest.Skills) } else { @() }
        $diff = [PSCustomObject]@{
            Tool            = $entry.Key
            Dst             = $dst
            Add             = @()
            Mod             = @()
            Del             = @()
            DelDirs         = @()
            Extra           = @()
            Foreign         = @()
            Legacy          = @()
            Managed         = $managed
            ManifestMissing = ($null -eq $manifest)
        }
        foreach ($skill in $skills) {
            $dstSkillDir = Join-Path $dst $skill.Name
            $res = Compare-SkillTree -SrcTree $srcIndex[$skill.Name] -DstSkillDir $dstSkillDir -Quick:$Quick
            foreach ($r in $res.Added)      { $diff.Add     += "$($skill.Name)\$r" }
            foreach ($r in $res.Modified)   { $diff.Mod     += "$($skill.Name)\$r" }
            foreach ($r in $res.Removed)    { $diff.Del     += "$($skill.Name)\$r" }
            foreach ($r in $res.RemovedDirs){ $diff.DelDirs += "$($skill.Name)\$r" }
        }
        # 目标根目录分三类：
        #   z-* 且源中存在      -> 受管，已在上面按 skill 逐文件比对；
        #   z-* 且仅清单中有记录 -> 本脚本部署过的旧技能，源已删除，待确认清理（Extra）；
        #   z-* 且清单中无记录   -> 其他途径安装的技能，保留不动（Legacy）；
        #   非 z-* 项           -> 工具自有文件/目录，保留不动（Foreign）。
        if (Test-Path -LiteralPath $dst) {
            foreach ($item in @(Get-ChildItem -LiteralPath $dst -Force -ErrorAction SilentlyContinue)) {
                if ($item.Name -eq $ManifestFileName) { continue }   # 本脚本的清单文件，不参与镜像
                if ($item.Name -like 'z-*') {
                    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                        Add-Warning "[$($entry.Key)] 目标是符号链接/junction，不跟随不删除: $($item.FullName)"
                    } elseif ($srcNames -contains $item.Name) {
                        continue
                    } elseif ($managed -contains $item.Name) {
                        $diff.Extra += $item.Name
                    } else {
                        $diff.Legacy += $item.Name
                    }
                } else {
                    $diff.Foreign += $item.Name
                }
            }
        }
        $diffs += $diff
    }

    # ---- 6. 预览 + 确认 ----
    foreach ($d in $diffs) { Show-Diff -Diff $d }

    if ($Script:Warnings.Count -gt 0) {
        Write-Log ""
        Write-Log ("警告 {0} 条:" -f $Script:Warnings.Count) -Color Yellow
        foreach ($w in $Script:Warnings) { Write-Log "  ! $w" -Color Yellow }
    }

    $tAdd = 0; $tMod = 0; $tDel = 0; $tDelDir = 0; $tExtra = 0; $tLegacy = 0
    foreach ($d in $diffs) {
        $tAdd += $d.Add.Count; $tMod += $d.Mod.Count; $tDel += $d.Del.Count
        $tDelDir += $d.DelDirs.Count; $tExtra += $d.Extra.Count; $tLegacy += $d.Legacy.Count
    }

    Write-Log ""
    Write-Log "============================================================" -Color Cyan
    Write-Log ("汇总: 新增 {0} / 修改 {1} / 删除文件 {2} / 删除目录 {3} / 待清理技能 {4} / 外来保留 {5}" -f $tAdd, $tMod, $tDel, $tDelDir, $tExtra, $tLegacy) -Color Cyan
    Write-Log "============================================================" -Color Cyan

    if ($DryRun) {
        Write-Log ""
        Write-Log "DryRun 模式：仅预览差异，未执行任何操作（也不会写入部署清单）。" -Color Green
        exit 0
    }

    if (($tAdd + $tMod + $tDel + $tDelDir + $tExtra) -eq 0) {
        Write-Log "所有目标均已是最新，无需同步。" -Color Green
        Update-DeployManifests -Diffs $diffs -SrcNames $srcNames
        if (-not $NoPause) { Read-Host "按回车键退出..." }
        exit 0
    }

    $doCopy   = $false
    $doDelete = $false
    if (($tAdd + $tMod) -gt 0) {
        $doCopy = Confirm-YesNo ">> 是否执行 新增/修改 文件的同步?"
    }
    if (($tDel + $tDelDir + $tExtra) -gt 0) {
        Write-Log "  （删除是镜像清理：仅移除部署清单内、源中已不存在的项；清单外的外来技能不动）" -Color DarkGray
        $doDelete = Confirm-YesNo ">> 是否执行上述 删除 操作?"
    }

    if (-not $doCopy -and -not $doDelete) {
        Write-Log "已取消，未执行任何操作。" -Color Yellow
        if (-not $NoPause) { Read-Host "按回车键退出..." }
        exit 0
    }

    # ---- 7. 执行 ----
    foreach ($d in $diffs) {
        Write-Log ""
        Write-Log ("[{0}] 同步中..." -f $d.Tool) -Color Cyan
        if ($doCopy) {
            $changed = @($d.Add) + @($d.Mod)
            if ($changed.Count -gt 0) {
                $n = Invoke-Copy -RelList $changed -Dst $d.Dst
                Write-Log ("  复制 {0} 个文件" -f $n) -Color Green
                $ok = Invoke-Verify -RelList $changed -Dst $d.Dst
                Write-Log ("  哈希校验 {0}/{1} 通过" -f $ok, $changed.Count) -Color $(if ($ok -eq $changed.Count) { 'Green' } else { 'Red' })
            }
        }
        if ($doDelete) {
            if ($d.Del.Count -gt 0) {
                $n = Invoke-Delete -RelList $d.Del -Dst $d.Dst
                Write-Log ("  删除 {0} 个多余文件" -f $n) -Color Green
            }
            $dirList = @($d.DelDirs) + @($d.Extra)
            if ($dirList.Count -gt 0) {
                $n = Invoke-Delete -RelList $dirList -Dst $d.Dst
                Write-Log ("  删除 {0} 个多余目录" -f $n) -Color Green
            }
        }
    }

    # ---- 8. 更新部署清单（按执行后的实际目录状态刷新）----
    Write-Log ""
    Update-DeployManifests -Diffs $diffs -SrcNames $srcNames

    # ---- 9. 汇总 ----
    Write-Log ""
    Write-Log "============================================================" -Color Cyan
    if ($Script:FailList.Count -eq 0) {
        Write-Log "  全部同步完成（success）" -Color Green
    } else {
        Write-Log ("  同步完成，但有 {0} 个错误:" -f $Script:FailList.Count) -Color Red
        foreach ($f in $Script:FailList) { Write-Log "    [ERR] $f" -Color Red }
    }
    Write-Log "============================================================" -Color Cyan
    Write-Log ("日志已保存: {0}" -f $Script:LogFile) -Color DarkGray
    Write-Log ""

    if (-not $NoPause) { Read-Host "按回车键退出..." }
    if ($Script:FailList.Count -eq 0) { exit 0 } else { exit 2 }
}
catch {
    Write-Log "[FATAL] 未预期错误: $($_.Exception.Message)" -Color Red
    Write-Log "        $($_.ScriptStackTrace)" -Color DarkGray
    if (-not $NoPause) { Read-Host "按回车键退出..." }
    exit 1
}
