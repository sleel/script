@echo off
set "AG_SELF=%~f0"
set "AG_ARG1=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$l=[IO.File]::ReadAllLines($env:AG_SELF,[Text.Encoding]::UTF8);$i=-1;for($k=0;$k -lt $l.Length;$k++){if($l[$k].Trim() -eq '::===PS_START==='){$i=$k;break}};if($i -lt 0){Write-Error 'Marker not found';exit 1};& ([ScriptBlock]::Create(($l[($i+1)..($l.Length-1)] -join [Environment]::NewLine))) $env:AG_ARG1"
exit /b %errorlevel%
::===PS_START===
param([string]$CliAction = '')

# ============================================================
#   Google Antigravity 非系统盘全生命周期管理工具 v1.0 (Final)
#   数据根目录：自动锁定为本脚本所在目录（免写死盘符）
#   命令行用法: Antigravity_Manager.bat [init|backup|restore|status|unbind|unbind-only]
# ============================================================

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding  = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding           = $utf8NoBom

$ScriptVersion = 'v1.0'
$ScriptPath    = [IO.Path]::GetFullPath($env:AG_SELF)
$ScriptDir     = Split-Path -Parent $ScriptPath
$ScriptName    = Split-Path -Leaf $ScriptPath

# 盘符根目录（如 D:\）保留末尾反斜杠，普通子目录去除末尾反斜杠
$BaseDst = if ($ScriptDir -match '^[A-Za-z]:\\?$') {
    $ScriptDir.Substring(0, 2) + '\'
} else {
    $ScriptDir.TrimEnd('\')
}

$script:Interactive = [string]::IsNullOrWhiteSpace($CliAction)
$script:ErrCount    = 0
$script:WarnCount   = 0

# -------------------- 底层工具函数 --------------------

function Normalize-DirPath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path.Trim()
    if ($p -match '^Volume\{') { return $p.TrimEnd('\') }
    if ($p -match '^[A-Za-z]:\\?$') { return $p.Substring(0, 2) + '\' }
    if ([IO.Path]::IsPathRooted($p)) {
        $full = [IO.Path]::GetFullPath($p)
        if ($full -match '^[A-Za-z]:\\?$') { return $full.Substring(0, 2) + '\' }
        return $full.TrimEnd('\')
    }
    return $p.TrimEnd('\')
}

function Format-RobocopyPath([string]$Path) {
    # 防止盘符根目录 D:\ 去斜杠变成相对路径 D:，同时避免末尾 \" 破坏 C 运行时引号解析
    if ($Path -match '^[A-Za-z]:\\?$') { return ($Path.Substring(0, 2) + '\.') }
    return $Path.TrimEnd('\')
}

function Get-ReparseInfo([string]$Path) {
    $exists    = $false
    $isReparse = $false
    $isDir     = $false

    # Win32 GetAttributes 不穿透联接，可 100% 识别目标已删除的死链
    try {
        $attrs     = [IO.File]::GetAttributes($Path)
        $exists    = $true
        $isReparse = (($attrs -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        $isDir     = (($attrs -band [IO.FileAttributes]::Directory) -ne 0)
    } catch {
        return [PSCustomObject]@{
            Exists       = $false
            IsReparse    = $false
            Target       = $null
            TargetExists = $false
            IsDir        = $false
        }
    }

    $target = $null
    if ($isReparse) {
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            if ($item.Target) {
                $raw     = if ($item.Target -is [array]) { $item.Target[0] } else { [string]$item.Target }
                $cleaned = $raw.Replace('\\?\', '').Replace('\??\', '').Trim()
                if (-not [string]::IsNullOrWhiteSpace($cleaned)) {
                    if ((-not ($cleaned -match '^Volume\{')) -and (-not [IO.Path]::IsPathRooted($cleaned))) {
                        $cleaned = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $Path) $cleaned))
                    }
                    $target = Normalize-DirPath $cleaned
                }
            }
        } catch {}

        # 兜底：若部分 PS 5.1 环境未返回 .Target，通过 env var + cmd dir /AL 解析
        if (-not $target) {
            try {
                $parent = Split-Path -Parent $Path
                $leaf   = Split-Path -Leaf $Path
                $env:AG_DIR_P = $parent
                try {
                    $out = & cmd.exe /c 'chcp 65001>nul & dir /AL "%AG_DIR_P%"' 2>$null
                } finally {
                    Remove-Item Env:AG_DIR_P -ErrorAction SilentlyContinue
                }
                foreach ($ln in $out) {
                    if ($ln -match '<(?:JUNCTION|SYMLINKD)>\s+(.+?)\s+\[(.+?)\]\s*$') {
                        if ($Matches[1].Trim().Equals($leaf, [StringComparison]::OrdinalIgnoreCase)) {
                            $cleaned = $Matches[2].Trim().Replace('\\?\', '').Replace('\??\', '')
                            if ((-not ($cleaned -match '^Volume\{')) -and (-not [IO.Path]::IsPathRooted($cleaned))) {
                                $cleaned = [IO.Path]::GetFullPath((Join-Path $parent $cleaned))
                            }
                            $target = Normalize-DirPath $cleaned
                            break
                        }
                    }
                }
            } catch {}
        }
    }

    $targetExists = $false
    if ($target) {
        try {
            [void][IO.File]::GetAttributes($target)
            $targetExists = $true
        } catch {
            $targetExists = $false
        }
    }

    return [PSCustomObject]@{
        Exists       = $exists
        IsReparse    = $isReparse
        Target       = $target
        TargetExists = $targetExists
        IsDir        = $isDir
    }
}

function Test-JunctionMatches([string]$LinkPath, [string]$ExpectedTarget) {
    $info = Get-ReparseInfo $LinkPath
    if (-not $info.Exists -or -not $info.IsReparse -or -not $info.Target) { return $false }
    $a = Normalize-DirPath $info.Target
    $b = Normalize-DirPath $ExpectedTarget
    return $a.Equals($b, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathOverlap([string]$PathA, [string]$PathB) {
    $a = (Normalize-DirPath $PathA).TrimEnd('\') + '\'
    $b = (Normalize-DirPath $PathB).TrimEnd('\') + '\'
    return ($a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or
            $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase))
}

function Test-DirNonEmpty([string]$DirPath) {
    if (-not (Test-Path -LiteralPath $DirPath)) { return $false }
    try {
        foreach ($e in [IO.Directory]::EnumerateFileSystemEntries($DirPath)) {
            return $true
        }
    } catch {}
    return $false
}

function Get-DirSizeBytes([string]$DirPath) {
    # 使用显式栈遍历并跳过 ReparsePoint，防循环引用与栈溢出
    [long]$total = 0
    if (-not (Test-Path -LiteralPath $DirPath)) { return $total }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($DirPath)
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($cur)) {
                try { $total += (New-Object IO.FileInfo($f)).Length } catch {}
            }
            foreach ($d in [IO.Directory]::EnumerateDirectories($cur)) {
                try {
                    $attr = [IO.File]::GetAttributes($d)
                    if (($attr -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
                        $stack.Push($d)
                    }
                } catch {}
            }
        } catch {}
    }
    return $total
}

function New-JunctionSafe([string]$LinkPath, [string]$TargetPath) {
    # 通过环境变量调用 mklink /J，免疫 PowerShell [ ] 通配符及 & ^ ( ) 特殊字符
    $env:AG_MK_LINK = $LinkPath
    $env:AG_MK_TGT  = $TargetPath
    try {
        $out = & cmd.exe /c 'chcp 65001>nul & mklink /J "%AG_MK_LINK%" "%AG_MK_TGT%"' 2>&1
        $rc  = $LASTEXITCODE
    } finally {
        Remove-Item Env:AG_MK_LINK, Env:AG_MK_TGT -ErrorAction SilentlyContinue
    }
    return [PSCustomObject]@{
        Ok     = ($rc -eq 0)
        Output = (($out | ForEach-Object { "$_" }) -join ' ').Trim()
    }
}

function Remove-JunctionOnly([string]$LinkPath) {
    $info = Get-ReparseInfo $LinkPath
    if (-not $info.Exists)    { return $true }
    if (-not $info.IsReparse) { return $false }  # 严禁误删实体目录

    try {
        # RemoveDirectoryW 仅摘除联接点本身，不触碰目标文件，且可安全清理死链
        [IO.Directory]::Delete($LinkPath, $false)
    } catch {
        $env:AG_RMLINK = $LinkPath
        try {
            & cmd.exe /c 'rmdir "%AG_RMLINK%"' 2>$null
        } finally {
            Remove-Item Env:AG_RMLINK -ErrorAction SilentlyContinue
        }
    }
    return (-not (Get-ReparseInfo $LinkPath).Exists)
}

function Remove-DirSafe([string]$DirPath) {
    # 通过环境变量调用 cmd rmdir /S /Q，避免 PS 5.1 Remove-Item 穿透嵌套联接及特殊字符问题
    if (Test-Path -LiteralPath $DirPath) {
        $env:AG_RMDIR = $DirPath
        try {
            & cmd.exe /c 'rmdir /S /Q "%AG_RMDIR%"' 2>$null
        } finally {
            Remove-Item Env:AG_RMDIR -ErrorAction SilentlyContinue
        }
    }
    return (-not (Test-Path -LiteralPath $DirPath))
}

function Invoke-Robocopy([string]$Src, [string]$Dst) {
    $s = Format-RobocopyPath $Src
    $d = Format-RobocopyPath $Dst
    if (-not (Test-Path -LiteralPath $Dst)) {
        New-Item -ItemType Directory -Path $Dst -Force | Out-Null
    }
    $out = & robocopy.exe $s $d /E /COPY:DAT /XJ /R:2 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1
    $rc  = $LASTEXITCODE
    return [PSCustomObject]@{
        Ok       = ($rc -lt 8)
        ExitCode = $rc
        Output   = @($out | ForEach-Object { "$_" } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
}

function Write-RobocopyFailure($RcResult) {
    Write-Host "  -> [ERR] robocopy 复制失败（退出码: $($RcResult.ExitCode)），已完整保留源目录。" -ForegroundColor Red
    if ($RcResult.Output.Count -gt 0) {
        $tail = $RcResult.Output | Select-Object -Last 5
        foreach ($ln in $tail) { Write-Host "     | $ln" -ForegroundColor DarkRed }
    }
}

function Test-StorageValid([switch]$CheckWritable) {
    if ($BaseDst.StartsWith('\\')) {
        Write-Host "[ERR] 当前目录为网络共享路径 ($BaseDst)。" -ForegroundColor Red
        Write-Host "      NTFS 目录联接不支持指向网络共享路径，请将脚本放入本地非系统盘目录（如 D:\Antigravity）。" -ForegroundColor Yellow
        return $false
    }

    if ($BaseDst -match '^([A-Za-z]:)') {
        $drvRoot = $Matches[1] + '\'
        try {
            $di = New-Object IO.DriveInfo($drvRoot)
            if ($di.DriveType -eq [IO.DriveType]::Network) {
                Write-Host "[ERR] 当前盘符 ($drvRoot) 为映射网络驱动器，NTFS 目录联接不支持指向网络盘！" -ForegroundColor Red
                return $false
            }
            if ($di.DriveType -eq [IO.DriveType]::CDRom) {
                Write-Host "[ERR] 当前盘符 ($drvRoot) 为只读光驱，无法作为数据目录。" -ForegroundColor Red
                return $false
            }
            if (-not $di.IsReady) {
                Write-Host "[ERR] 当前存储卷 ($drvRoot) 未就绪。" -ForegroundColor Red
                return $false
            }
            if ($CheckWritable) {
                if ($di.DriveFormat -ine 'NTFS') {
                    Write-Host "[WARN] 当前分区 ($drvRoot) 文件系统为 $($di.DriveFormat)（非 NTFS），SQLite 锁及自动更新可能不稳定。" -ForegroundColor Yellow
                    if (-not $script:Interactive) {
                        Write-Host "[ERR] 非交互模式已中止，建议使用本地 NTFS 分区。" -ForegroundColor Red
                        return $false
                    }
                    $ans = Read-Host "仍要在 $($di.DriveFormat) 分区继续吗？[Y/N，默认 N]"
                    if ($ans -notmatch '^[Yy]$') { return $false }
                }
                if ($di.DriveType -eq [IO.DriveType]::Removable) {
                    Write-Host "[WARN] 当前分区 ($drvRoot) 为可移动存储，拔出后 C 盘将产生失效死链。" -ForegroundColor Yellow
                    if (-not $script:Interactive) {
                        Write-Host "[ERR] 非交互模式已中止，建议使用本地固定磁盘。" -ForegroundColor Red
                        return $false
                    }
                    $ans = Read-Host "仍要在可移动存储上继续吗？[Y/N，默认 N]"
                    if ($ans -notmatch '^[Yy]$') { return $false }
                }
            }
        } catch {}
    }
    return $true
}

function Resolve-ProgName {
    $metaPath = Join-Path $BaseDst '.meta.ini'
    if (Test-Path -LiteralPath $metaPath) {
        foreach ($line in [IO.File]::ReadAllLines($metaPath, $utf8NoBom)) {
            if ($line -match '^\s*PROG_NAME\s*=\s*(.+?)\s*$') {
                return $Matches[1]
            }
        }
    }
    $ideInfo = Get-ReparseInfo (Join-Path $env:LOCALAPPDATA 'Programs\Antigravity IDE')
    if ($ideInfo.Exists) {
        return 'Antigravity IDE'
    }
    return 'Antigravity'
}

function Get-AltProgName([string]$ProgName) {
    if ($ProgName -ieq 'Antigravity IDE') { return 'Antigravity' }
    return 'Antigravity IDE'
}

function Get-CoreItems([string]$ProgName) {
    return @(
        [PSCustomObject]@{ Key = 'Program';        Label = '程序本体';         Parent = (Join-Path $env:LOCALAPPDATA 'Programs'); Name = $ProgName;      SubDir = 'Program';        InitPolicy = 'REQUIRED';  RestorePolicy = 'REQUIRED' }
        [PSCustomObject]@{ Key = 'AppData';        Label = '应用数据与缓存';   Parent = $env:APPDATA;                              Name = 'Antigravity';  SubDir = 'AppData';        InitPolicy = 'PRECREATE'; RestorePolicy = 'PRECREATE' }
        [PSCustomObject]@{ Key = 'DotAntigravity'; Label = 'Antigravity 配置'; Parent = $env:USERPROFILE;                          Name = '.antigravity'; SubDir = 'DotAntigravity'; InitPolicy = 'PRECREATE'; RestorePolicy = 'PRECREATE' }
        [PSCustomObject]@{ Key = 'DotGemini';      Label = 'Gemini 规则配置';  Parent = $env:USERPROFILE;                          Name = '.gemini';      SubDir = 'DotGemini';      InitPolicy = 'PRECREATE'; RestorePolicy = 'PRECREATE' }
    )
}

function Test-AntigravityRunning([string]$ProgName, [string[]]$ExtraDirs = @()) {
    # 覆盖主程序目录以及配置/扩展目录，拦截残留的语言服务、MCP、Node 辅助子进程
    $watchPrefixes = @()
    foreach ($it in (Get-CoreItems $ProgName)) {
        $cPath = Join-Path $it.Parent $it.Name
        $dPath = Join-Path $BaseDst $it.SubDir
        $watchPrefixes += ((Normalize-DirPath $cPath).TrimEnd('\') + '\')
        $watchPrefixes += ((Normalize-DirPath $dPath).TrimEnd('\') + '\')
        $info = Get-ReparseInfo $cPath
        if ($info.IsReparse -and $info.TargetExists) {
            $watchPrefixes += ((Normalize-DirPath $info.Target).TrimEnd('\') + '\')
        }
    }
    foreach ($d in $ExtraDirs) {
        if (-not [string]::IsNullOrWhiteSpace($d)) {
            $watchPrefixes += ((Normalize-DirPath $d).TrimEnd('\') + '\')
        }
    }
    $watchPrefixes = @($watchPrefixes | Select-Object -Unique)

    $hits = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($p.ProcessName -ieq 'Antigravity') {
            $hits += "$($p.ProcessName) (PID $($p.Id))"
            continue
        }
        try {
            $exe = $p.Path
            if ($exe) {
                foreach ($pre in $watchPrefixes) {
                    if ($exe.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) {
                        $hits += "$($p.ProcessName) (PID $($p.Id)) -> $exe"
                        break
                    }
                }
            }
        } catch {}
    }

    if ($hits.Count -gt 0) {
        Write-Host "[ERR] 检测到 Antigravity 或其扩展子进程仍在运行：" -ForegroundColor Red
        foreach ($h in $hits) { Write-Host "      - $h" -ForegroundColor Red }
        Write-Host "      请先完全退出程序（包含系统托盘图标）后再重试。" -ForegroundColor Yellow
        return $true
    }
    return $false
}

function Write-Meta([string]$ProgName) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $metaPath = Join-Path $BaseDst '.meta.ini'
    [IO.File]::WriteAllLines($metaPath, @(
        "PROG_NAME=$ProgName"
        "LAST_UPDATED=$stamp"
        "SCRIPT_VERSION=$ScriptVersion"
    ), $utf8NoBom)
    return $stamp
}

function Confirm-BaseLocationSafe([string]$ProgName) {
    foreach ($it in (Get-CoreItems $ProgName)) {
        $s = Join-Path $it.Parent $it.Name
        if (Test-PathOverlap $BaseDst $s) {
            Write-Host "[ERR] 当前脚本目录 ($BaseDst) 与 C 盘源目录 ($s) 重叠！" -ForegroundColor Red
            Write-Host "      请将本脚本移动到独立的非系统盘文件夹（如 D:\Antigravity）后再运行。" -ForegroundColor Yellow
            return $false
        }
    }

    $sysDrive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
    if ($BaseDst.StartsWith("$sysDrive\", [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "[WARN] 检测到脚本当前位于系统盘目录: $BaseDst" -ForegroundColor Yellow
        Write-Host "       映射到系统盘无法释放 C 盘空间，且重装系统会被格式化。" -ForegroundColor Yellow
        if (-not $script:Interactive) {
            Write-Host "[ERR] 非交互模式已自动中止，请先将脚本移至非系统盘目录。" -ForegroundColor Red
            return $false
        }
        $ans = Read-Host "仍要强制映射到当前系统盘目录吗？[Y/N，默认 N]"
        if ($ans -notmatch '^[Yy]$') {
            Write-Host "[INFO] 已取消操作。请先在非系统盘新建文件夹，放入本脚本后再运行。" -ForegroundColor Cyan
            return $false
        }
    }

    if ($BaseDst -match '^[A-Za-z]:\\$') {
        Write-Host "[WARN] 检测到脚本正位于盘符根目录 ($BaseDst)，直接映射会在根目录散落多个文件夹。" -ForegroundColor Yellow
        if (-not $script:Interactive) {
            Write-Host "[ERR] 非交互模式已中止，建议先新建子目录（如 ${BaseDst}Antigravity）再放入脚本。" -ForegroundColor Red
            return $false
        }
        $ans = Read-Host "建议先建子文件夹再放脚本。是否仍要直接映射到 $BaseDst ？[Y/N，默认 N]"
        if ($ans -notmatch '^[Yy]$') {
            Write-Host "[INFO] 已取消操作。" -ForegroundColor Cyan
            return $false
        }
    }
    return $true
}

function Add-UserPathSafe([string]$DirToAdd) {
    # 直接读写 HKCU\Environment 并保留 REG_EXPAND_SZ，避免 .NET SetEnvironmentVariable 破坏 %VAR%
    $binNorm = $DirToAdd.TrimEnd('\')
    $regKey  = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if (-not $regKey) { throw '无法打开 HKCU\Environment 注册表项' }

    try {
        $rawVal = $regKey.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind   = if ($null -ne $regKey.GetValue('Path')) { $regKey.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }

        $parts = @()
        if (-not [string]::IsNullOrEmpty($rawVal)) {
            $parts = @($rawVal -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }

        foreach ($p in $parts) {
            $pTrim = $p.Trim().TrimEnd('\')
            $pExp  = [Environment]::ExpandEnvironmentVariables($pTrim).TrimEnd('\')
            if ($pTrim.Equals($binNorm, [StringComparison]::OrdinalIgnoreCase) -or
                $pExp.Equals($binNorm, [StringComparison]::OrdinalIgnoreCase)) {
                return 'EXISTS'
            }
        }

        $newVal = if ($parts.Count -gt 0) { ($parts + $binNorm) -join ';' } else { $binNorm }
        if ($newVal -match '%') { $kind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
        $regKey.SetValue('Path', $newVal, $kind)
    } finally {
        $regKey.Close()
    }

    # 广播 WM_SETTINGCHANGE，让新开终端无需注销立即感知 PATH 更新
    try {
        if (-not ('AgWin32.EnvNotify' -as [type])) {
            Add-Type -Namespace 'AgWin32' -Name 'EnvNotify' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
        }
        $res = [UIntPtr]::Zero
        [void][AgWin32.EnvNotify]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment', 0x0002, 2000, [ref]$res)
    } catch {}

    return 'ADDED'
}

function Invoke-MigrateDir([string]$Label, [string]$SrcParent, [string]$SrcName, [string]$Dst, [string]$Policy) {
    $src = Join-Path $SrcParent $SrcName
    Write-Host "[检查] $Label ($src)"

    $info = Get-ReparseInfo $src

    # 0. 防呆：同名实体文件（非目录）
    if ($info.Exists -and (-not $info.IsDir) -and (-not $info.IsReparse)) {
        Write-Host "  -> [ERR] C 盘路径 $src 是一个文件而非目录，请手动核查。" -ForegroundColor Red
        $script:ErrCount++
        return
    }

    # 1. 若 C 盘已是联接
    if ($info.Exists -and $info.IsReparse) {
        if (-not $info.TargetExists) {
            Write-Host "  -> [ERR] 检测到失效死链（目标已不存在: $($info.Target)）！" -ForegroundColor Red
            Write-Host "           请先运行主菜单 [5] 解除所有映射以清理死链，再重新执行 [1]。" -ForegroundColor Yellow
            $script:ErrCount++
            return
        }
        if (Test-JunctionMatches $src $Dst) {
            Write-Host "  -> [SKIP] 已正确映射到 $Dst" -ForegroundColor DarkGray
            return
        } else {
            Write-Host "  -> [WARN] 已存在联接指向其他路径 ($($info.Target))，请先运行 [5] 解除所有映射后再执行 [1]。" -ForegroundColor Yellow
            $script:WarnCount++
            return
        }
    }

    # 2. 若 C 盘不存在源目录
    if (-not $info.Exists) {
        if ($Policy -eq 'PRECREATE') {
            if (-not (Test-Path -LiteralPath $SrcParent)) { New-Item -ItemType Directory -Path $SrcParent -Force | Out-Null }
            if (-not (Test-Path -LiteralPath $Dst))       { New-Item -ItemType Directory -Path $Dst -Force | Out-Null }
            $jr = New-JunctionSafe $src $Dst
            if ($jr.Ok) {
                Write-Host "  -> [OK] 尚未生成数据，已预建目录联接至 $Dst" -ForegroundColor Green
            } else {
                Write-Host "  -> [ERR] 预建目录联接失败: $($jr.Output)" -ForegroundColor Red
                $script:ErrCount++
            }
            return
        }
        if ($Policy -eq 'SYNC_ONLY') {
            if (Test-Path -LiteralPath $Dst) {
                Write-Host "  -> [OK] C 盘无漂移副本，目标目录已就绪。" -ForegroundColor Green
            } else {
                Write-Host "  -> [SKIP] 源与目标目录均不存在，跳过。" -ForegroundColor DarkGray
            }
            return
        }
        Write-Host "  -> [ERR] 源目录不存在: $src" -ForegroundColor Red
        $script:ErrCount++
        return
    }

    # 3. C 盘存在实体目录：先做非空目标防误覆写保护
    if (Test-DirNonEmpty $Dst) {
        Write-Host "  -> [WARN] 目标目录 $Dst 中已存在数据！" -ForegroundColor Yellow
        Write-Host "            继续用 C 盘实体目录覆盖合并，可能会覆写非系统盘里已有的配置或文件。" -ForegroundColor Yellow
        if (-not $script:Interactive) {
            Write-Host "  -> [ERR] 非交互模式禁止自动覆写非空目标目录，已安全跳过此项。" -ForegroundColor Red
            $script:ErrCount++
            return
        }
        $ans = Read-Host "     确认用 C 盘文件合并覆盖 $Dst 吗？[Y/N，默认 N]"
        if ($ans -notmatch '^[Yy]$') {
            Write-Host "  -> [SKIP] 已按选择跳过，保留两边现有数据。" -ForegroundColor Cyan
            $script:WarnCount++
            return
        }
    }

    # 4. 复制 -> 原子重命名测锁 -> 建联接（失败回滚）-> 清理旧目录
    Write-Host "  -> 正在复制文件到 $Dst ..."
    $rc = Invoke-Robocopy $src $Dst
    if (-not $rc.Ok) {
        Write-RobocopyFailure $rc
        $script:ErrCount++
        return
    }

    $bakFull = "$src.__migrating__"
    if (Test-Path -LiteralPath $bakFull) {
        Write-Host "  -> [ERR] 检测到残留临时目录 $bakFull，请先手动确认并清理后重试。" -ForegroundColor Red
        $script:ErrCount++
        return
    }

    try {
        [IO.Directory]::Move($src, $bakFull)
    } catch {
        Write-Host "  -> [ERR] 原目录存在文件占用（无法重命名），原目录完好无损。请关闭占用窗口后重试。" -ForegroundColor Red
        $script:ErrCount++
        return
    }

    $jr = New-JunctionSafe $src $Dst
    if (-not $jr.Ok) {
        try { [IO.Directory]::Move($bakFull, $src) } catch {}
        Write-Host "  -> [ERR] 创建目录联接失败，已自动回滚恢复 C 盘原目录: $($jr.Output)" -ForegroundColor Red
        $script:ErrCount++
        return
    }

    if (Remove-DirSafe $bakFull) {
        Write-Host "  -> [OK] 已无损迁移并建立联接至 $Dst" -ForegroundColor Green
    } else {
        Write-Host "  -> [WARN] 联接已生效，但临时目录未能完全删除，可稍后手动删除: $bakFull" -ForegroundColor Yellow
        $script:WarnCount++
    }
}

function Invoke-RestoreLink([string]$Label, [string]$LinkParent, [string]$LinkName, [string]$Target, [string]$Policy) {
    $linkPath = Join-Path $LinkParent $LinkName
    Write-Host "[恢复] $Label"

    if (-not (Test-Path -LiteralPath $Target)) {
        if ($Policy -eq 'PRECREATE') {
            New-Item -ItemType Directory -Path $Target -Force | Out-Null
        } else {
            Write-Host "  -> [ERR] 备份目标目录缺失: $Target" -ForegroundColor Red
            $script:ErrCount++
            return
        }
    }

    if (-not (Test-Path -LiteralPath $LinkParent)) {
        New-Item -ItemType Directory -Path $LinkParent -Force | Out-Null
    }

    $info = Get-ReparseInfo $linkPath

    if ($info.Exists -and $info.IsReparse) {
        if ($info.TargetExists -and (Test-JunctionMatches $linkPath $Target)) {
            Write-Host "  -> [SKIP] 联接已存在且指向正确。" -ForegroundColor DarkGray
            return
        } else {
            Write-Host "  -> [INFO] 检测到旧盘符或失效死链 ($($info.Target))，正在重建指向..." -ForegroundColor Cyan
            if (-not (Remove-JunctionOnly $linkPath)) {
                Write-Host "  -> [ERR] 无法移除旧联接 $linkPath" -ForegroundColor Red
                $script:ErrCount++
                return
            }
        }
    } elseif ($info.Exists) {
        Write-Host "  -> [WARN] C 盘已存在同名实体路径 ($linkPath)，为防覆盖已跳过。" -ForegroundColor Yellow
        Write-Host "            若确认无需保留，请手动删除该路径后重跑模式 3。" -ForegroundColor Yellow
        $script:WarnCount++
        return
    }

    $jr = New-JunctionSafe $linkPath $Target
    if ($jr.Ok) {
        Write-Host "  -> [OK] $linkPath <===> $Target" -ForegroundColor Green
    } else {
        Write-Host "  -> [ERR] 创建目录联接失败: $($jr.Output)" -ForegroundColor Red
        $script:ErrCount++
    }
}

function Invoke-CleanCaches([string]$AppDataDir) {
    if (-not (Test-Path -LiteralPath $AppDataDir)) { return }
    $dirs = @('Cache', 'Code Cache', 'GPUCache', 'CachedData', 'DawnGraphiteCache', 'DawnWebGPUCache', 'logs', 'Crashpad\reports')
    foreach ($rel in $dirs) {
        $full = Join-Path $AppDataDir $rel
        if (Test-Path -LiteralPath $full) {
            if (Remove-DirSafe $full) {
                Write-Host "  -> [OK] 已清理缓存: $rel" -ForegroundColor Green
            } else {
                Write-Host "  -> [WARN] 清理缓存未完全完成: $rel" -ForegroundColor Yellow
            }
        }
    }
}

# -------------------- 五大业务模式 --------------------

function Invoke-ModeInit {
    $script:ErrCount  = 0
    $script:WarnCount = 0
    Write-Host ""
    Write-Host "==================== [1] 首次安装后映射 ====================" -ForegroundColor Cyan

    if (-not (Test-StorageValid -CheckWritable)) { return 1 }

    $progName = Resolve-ProgName
    $items    = Get-CoreItems $progName

    if (Test-AntigravityRunning $progName)         { return 1 }
    if (-not (Confirm-BaseLocationSafe $progName)) { return 1 }

    # 全量预检：防止部分目录已有外部映射或死链导致“半迁移分裂状态”
    $conflicts = @()
    foreach ($it in $items) {
        $src  = Join-Path $it.Parent $it.Name
        $dst  = Join-Path $BaseDst $it.SubDir
        $info = Get-ReparseInfo $src
        if ($info.Exists -and $info.IsReparse) {
            if (-not $info.TargetExists) {
                $conflicts += "$($it.Label): 失效死链 ($src -> $($info.Target))"
            } elseif (-not (Test-JunctionMatches $src $dst)) {
                $conflicts += "$($it.Label): 已指向外部目录 ($src -> $($info.Target))"
            }
        }
    }
    if ($conflicts.Count -gt 0) {
        Write-Host "[ERR] 预检未通过，检测到以下已有外部映射或失效死链（未作任何修改）：" -ForegroundColor Red
        foreach ($c in $conflicts) { Write-Host "      - $c" -ForegroundColor Yellow }
        Write-Host "      为防止程序与配置分裂在两个位置，请先执行主菜单 [5] 解除所有映射，再执行 [1]。" -ForegroundColor Cyan
        return 1
    }

    $progSrc  = Join-Path $env:LOCALAPPDATA "Programs\$progName"
    $progInfo = Get-ReparseInfo $progSrc
    $exeSrc   = Join-Path $progSrc 'Antigravity.exe'
    if (-not ($progInfo.Exists -and $progInfo.IsReparse) -and -not (Test-Path -LiteralPath $exeSrc)) {
        Write-Host "[ERR] 未在默认位置检测到已安装的 Antigravity:" -ForegroundColor Red
        Write-Host "      $progSrc" -ForegroundColor Red
        Write-Host "      请先按默认路径完成官方安装，关闭程序后再运行模式 1。" -ForegroundColor Yellow
        return 1
    }

    foreach ($it in $items) {
        $dst = Join-Path $BaseDst $it.SubDir
        Invoke-MigrateDir $it.Label $it.Parent $it.Name $dst $it.InitPolicy
    }

    if (Test-Path -LiteralPath (Join-Path $BaseDst 'Program\Antigravity.exe')) {
        Write-Meta $progName | Out-Null
    }

    Write-Host ""
    if ($script:ErrCount -eq 0 -and $script:WarnCount -eq 0) {
        Write-Host "[OK] 模式 1 全部完成，数据已映射至当前目录: $BaseDst" -ForegroundColor Green
        return 0
    } elseif ($script:ErrCount -eq 0) {
        Write-Host "[INFO] 模式 1 执行完成，但有 $($script:WarnCount) 条跳过/提示项，请留意上方日志。" -ForegroundColor Yellow
        return 0
    } else {
        Write-Host "[WARN] 模式 1 执行结束，共有 $($script:ErrCount) 项异常，请查看上方日志。" -ForegroundColor Yellow
        return 1
    }
}

function Invoke-ModeBackup {
    $script:ErrCount  = 0
    $script:WarnCount = 0
    Write-Host ""
    Write-Host "==================== [2] 重装系统前备份 ====================" -ForegroundColor Cyan

    if (-not (Test-StorageValid)) { return 1 }

    $hasMeta = Test-Path -LiteralPath (Join-Path $BaseDst '.meta.ini')
    $hasExe  = Test-Path -LiteralPath (Join-Path $BaseDst 'Program\Antigravity.exe')
    if (-not $hasMeta -and -not $hasExe) {
        Write-Host "[ERR] 当前目录 ($BaseDst) 未检测到已映射的 Antigravity 数据。" -ForegroundColor Red
        Write-Host "      请先运行模式 [1] 完成映射，或将本脚本放回原数据根目录再执行备份。" -ForegroundColor Yellow
        return 1
    }

    $progName = Resolve-ProgName
    if (Test-AntigravityRunning $progName) { return 1 }

    Write-Host "[步骤 1/4] 检查 C 盘目录联接，防止更新导致数据漂移回 C 盘..."
    foreach ($it in (Get-CoreItems $progName)) {
        Invoke-MigrateDir $it.Label $it.Parent $it.Name (Join-Path $BaseDst $it.SubDir) 'SYNC_ONLY'
    }

    Write-Host ""
    Write-Host "[步骤 2/4] 缓存瘦身检查..."
    $cleanAns = 'N'
    if ($script:Interactive) {
        $cleanAns = Read-Host "是否清理冗余缓存以减小体积（Cache/GPUCache/logs，不影响配置和插件）? [Y/N，默认 N]"
    }
    if ($cleanAns -match '^[Yy]$') {
        Invoke-CleanCaches (Join-Path $BaseDst 'AppData')
    } else {
        Write-Host "  -> [SKIP] 保留现有缓存。" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "[步骤 3/4] 刷新元数据 (.meta.ini)..."
    $stamp = Write-Meta $progName
    Write-Host "  -> [OK] 元数据已更新 (时间戳: $stamp)。" -ForegroundColor Green

    Write-Host ""
    Write-Host "[步骤 4/4] 生成核心配置快照归档..."
    $bakRoot = Join-Path $BaseDst 'Backups'
    if (-not (Test-Path -LiteralPath $bakRoot)) { New-Item -ItemType Directory -Path $bakRoot -Force | Out-Null }
    $snapZip = Join-Path $bakRoot "config_$stamp.zip"
    $snapDir = Join-Path $bakRoot "config_$stamp"

    New-Item -ItemType Directory -Path $snapDir -Force | Out-Null
    $copiedAny = $false

    if (Test-Path -LiteralPath (Join-Path $BaseDst '.meta.ini')) {
        Copy-Item -LiteralPath (Join-Path $BaseDst '.meta.ini') -Destination $snapDir -Force
        $copiedAny = $true
    }
    $appUser = Join-Path $BaseDst 'AppData\User'
    if (Test-Path -LiteralPath $appUser) {
        $r1 = Invoke-Robocopy $appUser (Join-Path $snapDir 'AppData_User')
        if ($r1.Ok) { $copiedAny = $true }
    }
    if (Test-Path -LiteralPath (Join-Path $BaseDst 'DotAntigravity')) {
        $r2 = Invoke-Robocopy (Join-Path $BaseDst 'DotAntigravity') (Join-Path $snapDir 'DotAntigravity')
        if ($r2.Ok) { $copiedAny = $true }
    }
    if (Test-Path -LiteralPath (Join-Path $BaseDst 'DotGemini')) {
        $r3 = Invoke-Robocopy (Join-Path $BaseDst 'DotGemini') (Join-Path $snapDir 'DotGemini')
        if ($r3.Ok) { $copiedAny = $true }
    }

    if (-not $copiedAny) {
        Remove-DirSafe $snapDir | Out-Null
        Write-Host "  -> [WARN] 未发现可归档的配置子目录，跳过快照打包。" -ForegroundColor Yellow
    } else {
        $packed = $false
        # 强制使用 Windows 内置 System32\tar.exe (bsdtar)，避免被 Git/MSYS2 的 GNU tar 劫持
        $sysTar = Join-Path $env:SystemRoot 'System32\tar.exe'
        if (Test-Path -LiteralPath $sysTar) {
            & $sysTar -a -c -f $snapZip -C $snapDir . 2>$null
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $snapZip)) {
                $packed = $true
                Remove-DirSafe $snapDir | Out-Null
                Write-Host "  -> [OK] 配置快照已打包: $snapZip" -ForegroundColor Green
            }
        }
        if (-not $packed) {
            Write-Host "  -> [OK] 配置快照目录已生成: $snapDir" -ForegroundColor Green
        }
    }

    Write-Host ""
    Write-Host "==================== 重装前体检结论 ====================" -ForegroundColor Cyan
    Write-Host "  1. 主数据目录: $BaseDst （请勿格式化该分区）"
    Write-Host "  2. 恢复脚本:   $ScriptPath"
    Write-Host "  3. 重装新系统后，直接双击本脚本选择 [3] 即可按当前盘符恢复，仅需重登一次账号。"
    Write-Host "========================================================" -ForegroundColor Cyan

    if ($script:ErrCount -eq 0) { return 0 }
    Write-Host "[WARN] 备份过程存在 $($script:ErrCount) 项异常，请先处理上方日志再重装系统。" -ForegroundColor Yellow
    return 1
}

function Invoke-ModeRestore {
    $script:ErrCount  = 0
    $script:WarnCount = 0
    Write-Host ""
    Write-Host "==================== [3] 新系统后一键恢复 ====================" -ForegroundColor Cyan

    if (-not (Test-StorageValid -CheckWritable)) { return 1 }

    $progName = Resolve-ProgName
    if (Test-AntigravityRunning $progName) { return 1 }

    $bakExe = Join-Path $BaseDst 'Program\Antigravity.exe'
    if (-not (Test-Path -LiteralPath $bakExe)) {
        Write-Host "[ERR] 当前目录下未找到程序文件: $bakExe" -ForegroundColor Red
        Write-Host "      请确保本脚本位于包含 Program\Antigravity.exe 的数据根目录中再运行。" -ForegroundColor Yellow
        return 1
    }

    Write-Host "[INFO] 目标程序目录名: $progName"
    Write-Host "[INFO] 当前数据根目录: $BaseDst"
    Write-Host ""

    foreach ($it in (Get-CoreItems $progName)) {
        Invoke-RestoreLink $it.Label $it.Parent $it.Name (Join-Path $BaseDst $it.SubDir) $it.RestorePolicy
    }

    # 重建桌面与开始菜单快捷方式（指向 C 盘联接路径，确保内置更新正常）
    $progLinkDir = Join-Path $env:LOCALAPPDATA "Programs\$progName"
    $exePath     = Join-Path $progLinkDir 'Antigravity.exe'
    Write-Host ""
    Write-Host "[快捷方式] 正在创建桌面与开始菜单入口..."
    if (Test-Path -LiteralPath $exePath) {
        try {
            $ws = New-Object -ComObject WScript.Shell

            $deskLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Antigravity.lnk'
            $s1 = $ws.CreateShortcut($deskLnk)
            $s1.TargetPath       = $exePath
            $s1.WorkingDirectory = $progLinkDir
            $s1.Description      = 'Google Antigravity'
            $s1.Save()

            $smDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Antigravity'
            if (-not (Test-Path -LiteralPath $smDir)) { New-Item -ItemType Directory -Path $smDir -Force | Out-Null }
            $smLnk = Join-Path $smDir 'Antigravity.lnk'
            $s2 = $ws.CreateShortcut($smLnk)
            $s2.TargetPath       = $exePath
            $s2.WorkingDirectory = $progLinkDir
            $s2.Description      = 'Google Antigravity'
            $s2.Save()

            Write-Host "  -> [OK] 已创建桌面快捷方式与开始菜单入口。" -ForegroundColor Green
        } catch {
            Write-Host "  -> [WARN] 快捷方式创建失败: $($_.Exception.Message)" -ForegroundColor Yellow
            $script:WarnCount++
        }
    } else {
        Write-Host "  -> [WARN] 未找到联接后的 $exePath，跳过快捷方式创建。" -ForegroundColor Yellow
        $script:WarnCount++
    }

    # 幂等恢复 User PATH（保留 REG_EXPAND_SZ 类型）
    $binDir = Join-Path $progLinkDir 'bin'
    Write-Host ""
    Write-Host "[环境变量] 检查命令行工具路径..."
    if (Test-Path -LiteralPath $binDir) {
        try {
            $res = Add-UserPathSafe $binDir
            if ($res -eq 'ADDED') {
                Write-Host "  -> [OK] 已将 $binDir 写入用户 PATH（新开终端生效）。" -ForegroundColor Green
            } else {
                Write-Host "  -> [SKIP] 用户 PATH 中已包含该目录。" -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  -> [WARN] 写入用户 PATH 失败: $($_.Exception.Message)" -ForegroundColor Yellow
            $script:WarnCount++
        }
    } else {
        Write-Host "  -> [SKIP] 程序目录下无 bin 子目录，无需配置 PATH。" -ForegroundColor DarkGray
    }

    Write-Host ""
    if ($script:ErrCount -eq 0) {
        if ($script:WarnCount -eq 0) {
            Write-Host "[OK] 恢复完成，双击桌面 Antigravity 图标并重新登录一次 Google 账号即可。" -ForegroundColor Green
        } else {
            Write-Host "[INFO] 主体已恢复，但有 $($script:WarnCount) 条提示项，请留意上方日志。" -ForegroundColor Yellow
        }
        return 0
    } else {
        Write-Host "[ERR] 恢复过程有 $($script:ErrCount) 项失败，请根据上方提示排查后重跑模式 3。" -ForegroundColor Red
        return 1
    }
}

function Invoke-ModeStatus {
    Write-Host ""
    Write-Host "==================== [4] 当前映射状态自检 ====================" -ForegroundColor Cyan
    $progName = Resolve-ProgName
    Write-Host "  当前脚本目录: $BaseDst"
    Write-Host "  程序目录名:   $progName"
    Write-Host "--------------------------------------------------------------"

    $hasBroken = $false
    foreach ($it in (Get-CoreItems $progName)) {
        $src  = Join-Path $it.Parent $it.Name
        $exp  = Join-Path $BaseDst $it.SubDir
        $info = Get-ReparseInfo $src

        if ($info.Exists -and $info.IsReparse) {
            if (-not $info.TargetExists) {
                $hasBroken = $true
                Write-Host "  [JUNCTION 死链]     $($it.Label): $src" -ForegroundColor Red
                Write-Host "                      -> $($info.Target) （目标目录已不存在）" -ForegroundColor Red
            } elseif (Test-JunctionMatches $src $exp) {
                Write-Host "  [JUNCTION 正常]     $($it.Label): $src" -ForegroundColor Green
                Write-Host "                      -> $($info.Target)" -ForegroundColor DarkGray
            } else {
                Write-Host "  [JUNCTION 指向别处] $($it.Label): $src" -ForegroundColor Yellow
                Write-Host "                      当前指向 -> $($info.Target)" -ForegroundColor Yellow
                Write-Host "                      当前目录 -> $exp" -ForegroundColor DarkGray
            }
        } elseif ($info.Exists) {
            Write-Host "  [C 盘实体目录]      $($it.Label): $src" -ForegroundColor Yellow
        } else {
            Write-Host "  [尚未创建]          $($it.Label): $src" -ForegroundColor DarkGray
        }
    }

    # 额外排查另一个备选程序目录名是否残留联接或死链
    $altName = Get-AltProgName $progName
    $altPath = Join-Path $env:LOCALAPPDATA "Programs\$altName"
    $altInfo = Get-ReparseInfo $altPath
    if ($altInfo.Exists -and $altInfo.IsReparse) {
        if (-not $altInfo.TargetExists) { $hasBroken = $true }
        Write-Host "  [额外残留联接]      $altName : $altPath -> $($altInfo.Target)" -ForegroundColor Yellow
    }

    Write-Host "--------------------------------------------------------------"
    if ($hasBroken) {
        Write-Host "  [提示] 检测到失效死链，请执行主菜单 [5] 解除所有映射以清理死链。" -ForegroundColor Red
    }
    return 0
}

function Invoke-ModeUnbind([string]$SubMode = '') {
    $script:ErrCount  = 0
    $script:WarnCount = 0
    Write-Host ""
    Write-Host "==================== [5] 解除所有映射 ====================" -ForegroundColor Cyan

    $progName = Resolve-ProgName
    $items    = @(Get-CoreItems $progName)

    # 若备选程序名（Antigravity vs Antigravity IDE）也存在残留联接，一并纳入扫描解除
    $altName = Get-AltProgName $progName
    $altPath = Join-Path $env:LOCALAPPDATA "Programs\$altName"
    $altInfo = Get-ReparseInfo $altPath
    if ($altInfo.Exists -and $altInfo.IsReparse) {
        $items += [PSCustomObject]@{ Key = 'AltProgram'; Label = "额外程序联接($altName)"; Parent = (Join-Path $env:LOCALAPPDATA 'Programs'); Name = $altName; SubDir = '' }
    }

    $scan       = [ordered]@{}
    $extraWatch = @()
    $linkCount  = 0

    Write-Host "[扫描] 当前 C 盘联接状态："
    foreach ($it in $items) {
        $src  = Join-Path $it.Parent $it.Name
        $info = Get-ReparseInfo $src
        $scan[$it.Key] = $info

        if ($info.Exists -and $info.IsReparse) {
            $linkCount++
            if ($info.TargetExists) {
                Write-Host "  - $($it.Label): [有效联接] -> $($info.Target)" -ForegroundColor Green
                $extraWatch += $info.Target
            } else {
                Write-Host "  - $($it.Label): [失效死链] -> $($info.Target) （目标已删除）" -ForegroundColor Red
            }
        } elseif ($info.Exists) {
            Write-Host "  - $($it.Label): [C 盘实体目录] 无需解除" -ForegroundColor DarkGray
        } else {
            Write-Host "  - $($it.Label): [尚未创建] 无需解除" -ForegroundColor DarkGray
        }
    }

    if ($linkCount -eq 0) {
        Write-Host ""
        Write-Host "[OK] C 盘当前不存在任何目录联接，可直接执行 [1] 或 [3]。" -ForegroundColor Green
        return 0
    }

    if (Test-AntigravityRunning $progName $extraWatch) { return 1 }

    $mode = $SubMode
    if ([string]::IsNullOrWhiteSpace($mode)) {
        Write-Host ""
        Write-Host "请选择解除方式（两种方式均【不会】删除原非系统盘文件）：" -ForegroundColor White
        Write-Host "  [A] 解除联接并将数据回迁到 C 盘（推荐）" -ForegroundColor Green
        Write-Host "      有效映射的数据拷回 C 盘恢复为实体目录；目标已删的死链直接清理。解除后可用 [1] 重映射。"
        Write-Host "  [B] 仅摘除 C 盘所有联接点（不回拷数据）" -ForegroundColor Cyan
        Write-Host "      直接清空 C 盘全部正常联接与死链，适合重装软件或搬走文件夹后直接用 [3] 恢复。"
        Write-Host "  [0] 取消返回"
        Write-Host ""
        $pick = (Read-Host "请输入选择 [A/B/0，默认 A]").Trim().ToUpperInvariant()
        if ($pick -eq '0') { Write-Host "[INFO] 已取消。"; return 0 }
        if ([string]::IsNullOrWhiteSpace($pick) -or $pick -eq 'A') { $mode = 'restore-c' }
        elseif ($pick -eq 'B') { $mode = 'unlink-only' }
        else { Write-Host "[WARN] 无效选择，已取消。" -ForegroundColor Yellow; return 1 }
    }

    # 回迁模式先校验 C 盘剩余空间（留 200 MB 安全缓冲）
    if ($mode -eq 'restore-c') {
        [long]$needBytes = 0
        foreach ($it in $items) {
            $info = $scan[$it.Key]
            if ($info.Exists -and $info.IsReparse -and $info.TargetExists) {
                $needBytes += Get-DirSizeBytes $info.Target
            }
        }
        $sysDrive = if ($env:SystemDrive) { $env:SystemDrive + '\' } else { 'C:\' }
        try {
            $sysFree  = (New-Object IO.DriveInfo($sysDrive)).AvailableFreeSpace
            $margin   = 200MB
            if ($sysFree -lt ($needBytes + $margin)) {
                $needMB = [Math]::Ceiling($needBytes / 1MB)
                $freeMB = [Math]::Floor($sysFree / 1MB)
                Write-Host ""
                Write-Host "[ERR] 系统盘 ($sysDrive) 可用空间不足，中止回迁！" -ForegroundColor Red
                Write-Host "      需要回拷约 $needMB MB（另需 200 MB 余量），当前剩余 $freeMB MB。" -ForegroundColor Yellow
                Write-Host "      建议先清理缓存，或改选 [B] 仅摘除联接点。" -ForegroundColor Cyan
                return 1
            }
        } catch {}
    }

    Write-Host ""
    $keptTargets = @()

    foreach ($it in $items) {
        $src  = Join-Path $it.Parent $it.Name
        $info = $scan[$it.Key]

        if (-not ($info.Exists -and $info.IsReparse)) {
            continue
        }

        Write-Host "[解除] $($it.Label) ($src)"

        # 情况 1：失效死链（原目标目录已被删除）——直接清理，打破死循环
        if (-not $info.TargetExists) {
            if (Remove-JunctionOnly $src) {
                Write-Host "  -> [OK] 目标目录已不存在，已直接清理失效死链。" -ForegroundColor Green
            } else {
                Write-Host "  -> [ERR] 无法清理失效死链 $src，请检查目录是否被资源管理器打开。" -ForegroundColor Red
                $script:ErrCount++
            }
            continue
        }

        # 情况 2：仅摘除联接点
        if ($mode -eq 'unlink-only') {
            if (Remove-JunctionOnly $src) {
                Write-Host "  -> [OK] 已摘除 C 盘联接点，原数据完好保留于: $($info.Target)" -ForegroundColor Green
                $keptTargets += $info.Target
            } else {
                Write-Host "  -> [ERR] 无法摘除联接点 $src，请确认无文件占用。" -ForegroundColor Red
                $script:ErrCount++
            }
            continue
        }

        # 情况 3：解除并将数据安全回迁到 C 盘
        $oldTarget = $info.Target
        $tmpDir    = "$src.__unbinding__"

        if (Test-PathOverlap $oldTarget $src) {
            Write-Host "  -> [ERR] 联接目标与源路径重叠 ($oldTarget)，请改用 [B] 仅摘除联接点。" -ForegroundColor Red
            $script:ErrCount++
            continue
        }

        if (Test-Path -LiteralPath $tmpDir) {
            Write-Host "  -> [ERR] 检测到残留临时目录 $tmpDir，请先手动处理后再重试。" -ForegroundColor Red
            $script:ErrCount++
            continue
        }

        Write-Host "  -> 正在从 $oldTarget 回拷数据到 C 盘临时目录..."
        $rc = Invoke-Robocopy $oldTarget $tmpDir
        if (-not $rc.Ok) {
            Remove-DirSafe $tmpDir | Out-Null
            Write-RobocopyFailure $rc
            $script:ErrCount++
            continue
        }

        if (-not (Remove-JunctionOnly $src)) {
            Remove-DirSafe $tmpDir | Out-Null
            Write-Host "  -> [ERR] 无法摘除联接点 $src，已清理临时文件并保留原联接。" -ForegroundColor Red
            $script:ErrCount++
            continue
        }

        try {
            [IO.Directory]::Move($tmpDir, $src)
            Write-Host "  -> [OK] 已解除联接并将数据回迁至 C 盘: $src" -ForegroundColor Green
            $keptTargets += $oldTarget
        } catch {
            # 重命名失败时自动回滚重建原联接
            New-JunctionSafe $src $oldTarget | Out-Null
            Remove-DirSafe $tmpDir | Out-Null
            Write-Host "  -> [ERR] 回迁切换失败，已自动回滚恢复原联接: $($_.Exception.Message)" -ForegroundColor Red
            $script:ErrCount++
        }
    }

    Write-Host ""
    if ($keptTargets.Count -gt 0) {
        Write-Host "[原目录保留] 以下原目标目录未自动删除（作为安全备份，确认无误后可自行清理）：" -ForegroundColor Cyan
        foreach ($kt in $keptTargets) { Write-Host "  - $kt" -ForegroundColor Yellow }
        Write-Host ""
    }

    if ($script:ErrCount -eq 0) {
        if ($mode -eq 'restore-c') {
            Write-Host "[OK] 所有映射已解除并还原回 C 盘！现在可运行 [1] 重新映射到当前目录。" -ForegroundColor Green
        } else {
            Write-Host "[OK] C 盘所有联接点已摘除！现在可直接重装软件，或运行 [3] 指向当前目录。" -ForegroundColor Green
        }
        return 0
    } else {
        Write-Host "[WARN] 解除过程存在 $($script:ErrCount) 项异常，请查看上方日志。" -ForegroundColor Yellow
        return 1
    }
}

# -------------------- 全局异常兜底与入口调度 --------------------

try {
    if (-not $script:Interactive) {
        switch ($CliAction.ToLowerInvariant()) {
            'init'        { exit (Invoke-ModeInit) }
            'backup'      { exit (Invoke-ModeBackup) }
            'restore'     { exit (Invoke-ModeRestore) }
            'status'      { exit (Invoke-ModeStatus) }
            'unbind'      { exit (Invoke-ModeUnbind 'restore-c') }
            'unbind-only' { exit (Invoke-ModeUnbind 'unlink-only') }
            default {
                Write-Host "[ERR] 未知参数: $CliAction" -ForegroundColor Red
                Write-Host "用法: $ScriptName [init|backup|restore|status|unbind|unbind-only]"
                exit 1
            }
        }
    }

    while ($true) {
        Clear-Host
        Write-Host "==============================================================" -ForegroundColor Cyan
        Write-Host "  Google Antigravity 非系统盘全生命周期管理工具 $ScriptVersion" -ForegroundColor White
        Write-Host "==============================================================" -ForegroundColor Cyan
        Write-Host "  当前数据根目录: $BaseDst"
        Write-Host "--------------------------------------------------------------"
        Write-Host "  [1] 首次安装后映射   （将本体与配置迁至当前目录并建联接）"
        Write-Host "  [2] 重装系统前备份   （C 盘防漂移补漏 + 清缓存 + 配置快照）"
        Write-Host "  [3] 新系统后一键恢复 （按当前目录重建联接 + 快捷方式 + PATH）"
        Write-Host "  [4] 查看当前映射状态 （只读自检，识别正常/外部/失效死链）"
        Write-Host "  [5] 解除所有映射     （回迁 C 盘或摘除联接，自动清理死链）"
        Write-Host "  [0] 退出"
        Write-Host "==============================================================" -ForegroundColor Cyan
        Write-Host ""
        $choice = (Read-Host "请选择操作编号 [0-5]").Trim()

        switch ($choice) {
            '1' { Invoke-ModeInit    | Out-Null; Write-Host ""; Read-Host "按回车键返回主菜单" | Out-Null }
            '2' { Invoke-ModeBackup  | Out-Null; Write-Host ""; Read-Host "按回车键返回主菜单" | Out-Null }
            '3' { Invoke-ModeRestore | Out-Null; Write-Host ""; Read-Host "按回车键返回主菜单" | Out-Null }
            '4' { Invoke-ModeStatus  | Out-Null; Write-Host ""; Read-Host "按回车键返回主菜单" | Out-Null }
            '5' { Invoke-ModeUnbind  | Out-Null; Write-Host ""; Read-Host "按回车键返回主菜单" | Out-Null }
            '0' { exit 0 }
            default {
                Write-Host "[WARN] 无效输入，请输入 0 到 5 之间的数字。" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
} catch {
    Write-Host ""
    Write-Host "[FATAL] 发生未预期错误: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
        Write-Host "        行号: $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor DarkRed
    }
    if ($script:Interactive) {
        Write-Host ""
        Read-Host "按回车键退出" | Out-Null
    }
    exit 1
}