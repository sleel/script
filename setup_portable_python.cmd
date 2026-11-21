@echo off
setlocal
set "PY_SELF=%~f0"
set "PY_SELF_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$m='#==='+'PS_BEGIN==='; $c=[IO.File]::ReadAllText($env:PY_SELF,[Text.UTF8Encoding]::new($false)); & ([scriptblock]::Create($c.Substring($c.IndexOf($m)+$m.Length))) %*"
set "EC=%ERRORLEVEL%"
if "%~1"=="" if not "%EC%"=="0" pause
exit /b %EC%

#===PS_BEGIN===
param(
    [ValidateSet("Menu", "Base", "Antigravity", "Reset", "Status")]
    [string]$Action = "Menu",

    [ValidateSet("None", "Tsinghua", "Aliyun", "USTC")]
    [string]$Mirror = "None",

    [switch]$WithVirtualenv,

    [switch]$Force
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# ======================== 环境校验 ========================
$PyDir = if ($env:PY_SELF_DIR) { $env:PY_SELF_DIR } else { $PSScriptRoot }
if ($PyDir.Length -gt 3) { $PyDir = $PyDir.TrimEnd('\') }

$PyExe      = Join-Path $PyDir "python.exe"
$ScriptsDir = Join-Path $PyDir "Scripts"
$LibDir     = Join-Path $PyDir "Lib"
$PipIniFile = Join-Path $PyDir "pip.ini"
$GetPipUrl  = "https://bootstrap.pypa.io/get-pip.py"

$MirrorMap = @{
    "Tsinghua" = @{ Name = "清华大学 TUNA"; Url = "https://pypi.tuna.tsinghua.edu.cn/simple"; Host = "pypi.tuna.tsinghua.edu.cn" }
    "Aliyun"   = @{ Name = "阿里云";        Url = "https://mirrors.aliyun.com/pypi/simple/";  Host = "mirrors.aliyun.com" }
    "USTC"     = @{ Name = "中科大 USTC";   Url = "https://pypi.mirrors.ustc.edu.cn/simple/"; Host = "pypi.mirrors.ustc.edu.cn" }
}

if (-not (Test-Path -LiteralPath $PyExe -PathType Leaf)) {
    Write-Host "[错误] 当前目录未找到 python.exe：$PyDir" -ForegroundColor Red
    Write-Host "请将本脚本直接放在绿色版 Python 解压目录下运行。" -ForegroundColor Yellow
    exit 1
}

$PthFile = Get-ChildItem -LiteralPath $PyDir -Filter "python*._pth" -File | Select-Object -First 1
if (-not $PthFile) {
    Write-Host "[错误] 未找到 python*._pth 文件，当前目录可能不是官方 Embeddable 绿色版。" -ForegroundColor Red
    exit 1
}
$PthBak = "$($PthFile.FullName).bak"

# ======================== 底层辅助函数 ========================
function Clear-ScreenSafe {
    try { Clear-Host } catch {}
}

function Normalize-PathEntry {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    $v = $Value.Trim().Trim('"')
    if ($v.Length -gt 3) { $v = $v.TrimEnd('\') }
    return $v
}

function Invoke-NativeQuiet {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    $oldPref = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = & $FilePath @Arguments 2>&1
        return [PSCustomObject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($output | Out-String).Trim()
        }
    } finally {
        $ErrorActionPreference = $oldPref
    }
}

function Send-EnvironmentChange {
    if (-not ("Win32.NativeMethods" -as [type])) {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
        [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
            uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
"@
    }
    $result = [UIntPtr]::Zero
    [Win32.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result) | Out-Null
}

function Update-UserPath {
    param(
        [string[]]$TargetPaths,
        [ValidateSet("Add", "Remove")][string]$Mode
    )
    $regKey = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey("Environment")
    try {
        $rawPath = [string]$regKey.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $kind = try { $regKey.GetValueKind("Path") } catch { [Microsoft.Win32.RegistryValueKind]::ExpandString }

        $entries = New-Object System.Collections.Generic.List[string]
        foreach ($item in ($rawPath -split ';')) {
            if (-not [string]::IsNullOrWhiteSpace($item)) {
                $entries.Add($item.Trim())
            }
        }

        $changed = $false
        if ($Mode -eq "Add") {
            foreach ($tp in $TargetPaths) {
                $norm = Normalize-PathEntry $tp
                if (-not ($entries | Where-Object { (Normalize-PathEntry $_) -ieq $norm })) {
                    $entries.Add($tp)
                    $changed = $true
                }
            }
        } else {
            $normTargets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($tp in $TargetPaths) {
                [void]$normTargets.Add((Normalize-PathEntry $tp))
            }
            $kept = New-Object System.Collections.Generic.List[string]
            foreach ($e in $entries) {
                if ($normTargets.Contains((Normalize-PathEntry $e))) {
                    $changed = $true
                } else {
                    $kept.Add($e)
                }
            }
            $entries = $kept
        }

        if ($changed) {
            $regKey.SetValue("Path", ($entries -join ';'), $kind)
            Send-EnvironmentChange
        }
        return $changed
    } finally {
        $regKey.Close()
    }
}

function Get-UserPathStatus {
    $regKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $false)
    if (-not $regKey) {
        return [PSCustomObject]@{ HasPyDir = $false; HasScripts = $false }
    }
    try {
        $rawPath = [string]$regKey.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @($rawPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Normalize-PathEntry $_ })
        $normPy  = Normalize-PathEntry $PyDir
        $normScr = Normalize-PathEntry $ScriptsDir
        return [PSCustomObject]@{
            HasPyDir   = [bool]($entries | Where-Object { $_ -ieq $normPy })
            HasScripts = [bool]($entries | Where-Object { $_ -ieq $normScr })
        }
    } finally {
        $regKey.Close()
    }
}

function Get-ShadowingPythons {
    $machineRaw = ""
    $userRaw    = ""
    $mKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Control\Session Manager\Environment", $false)
    if ($mKey) {
        try { $machineRaw = [string]$mKey.GetValue("Path", "") } finally { $mKey.Close() }
    }
    $uKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $false)
    if ($uKey) {
        try { $userRaw = [string]$uKey.GetValue("Path", "") } finally { $uKey.Close() }
    }

    $allEntries = @($machineRaw -split ';') + @($userRaw -split ';')
    $normSelf   = Normalize-PathEntry $PyDir
    $seen       = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($raw in $allEntries) {
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $expanded = Normalize-PathEntry ([Environment]::ExpandEnvironmentVariables($raw))
        if ([string]::IsNullOrWhiteSpace($expanded)) { continue }
        if ($expanded -ieq $normSelf) { break }
        try {
            $cand = Join-Path $expanded "python.exe"
            if ((Test-Path -LiteralPath $cand -PathType Leaf) -and $seen.Add($cand)) {
                $cand
            }
        } catch {}
    }
}

function Test-PthUnlocked {
    $lines = [System.IO.File]::ReadAllLines($PthFile.FullName)
    return [bool]($lines | Where-Object { $_ -match '^\s*import\s+site\s*$' })
}

function Get-LockingProcesses {
    param([string]$TargetDir)
    $normDir = $TargetDir.TrimEnd('\') + '\'
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        $exePath = $null
        try { $exePath = $p.Path } catch {}
        if ($exePath -and $exePath.StartsWith($normDir, [System.StringComparison]::OrdinalIgnoreCase)) {
            [PSCustomObject]@{ Name = $p.ProcessName; Id = $p.Id; Path = $exePath }
        }
    }
}

function Get-AntigravitySettingsFiles {
    $candidates = @(
        (Join-Path $env:APPDATA "Antigravity"),
        (Join-Path $env:APPDATA "Antigravity IDE")
    )
    foreach ($base in $candidates) {
        if (Test-Path -LiteralPath $base) {
            Join-Path (Join-Path $base "User") "settings.json"
        }
    }
}

function Read-JsonSafe {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) {
        return [PSCustomObject]@{ Data = [PSCustomObject]@{}; HadComments = $false }
    }
    $raw = [System.IO.File]::ReadAllText($FilePath, $Utf8NoBom)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [PSCustomObject]@{ Data = [PSCustomObject]@{}; HadComments = $false }
    }

    $hadComments = $false
    $parsed = $null
    try {
        $parsed = $raw | ConvertFrom-Json
    } catch {
        # 仅在双引号字符串外部剥离 // 和 /* */ 注释，防止破坏 URL 中的 //
        $noComments = [regex]::Replace(
            $raw,
            '("(?:\\.|[^"\\])*")|//[^\r\n]*|/\*[\s\S]*?\*/',
            { param($m) if ($m.Groups[1].Success) { $m.Groups[1].Value } else { "" } }
        )
        # 剥离 JSONC 允许的尾随逗号
        $cleaned = [regex]::Replace(
            $noComments,
            '("(?:\\.|[^"\\])*")|,(?=\s*[}\]])',
            { param($m) if ($m.Groups[1].Success) { $m.Groups[1].Value } else { "" } }
        )
        $parsed = $cleaned | ConvertFrom-Json
        $hadComments = ($noComments -ne $raw)
    }

    if ($null -eq $parsed) {
        $parsed = [PSCustomObject]@{}
    } elseif (-not ($parsed -is [PSCustomObject])) {
        throw "配置文件根节点不是 JSON 对象"
    }

    return [PSCustomObject]@{
        Data        = $parsed
        HadComments = $hadComments
    }
}

# ======================== 模块 1：通用绿色 Python 基础配置 ========================
function Invoke-BaseInstall {
    param(
        [string]$SelectedMirror = "None",
        [bool]$InstallVirtualenv = $false
    )

    Write-Host "=== [1] 绿色版 Python 基础配置：$PyDir ===`n" -ForegroundColor Cyan

    # 1. 解锁 ._pth
    Write-Host "[1/5] 检查并解锁 $($PthFile.Name) ..."
    if (-not (Test-Path -LiteralPath $PthBak)) {
        Copy-Item -LiteralPath $PthFile.FullName -Destination $PthBak
    }
    $lines = [System.IO.File]::ReadAllLines($PthFile.FullName)
    $pthModified = $false
    $hasImportSite = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*#\s*import\s+site\s*$') {
            $lines[$i] = "import site"
            $pthModified = $true
            $hasImportSite = $true
        } elseif ($lines[$i] -match '^\s*import\s+site\s*$') {
            $hasImportSite = $true
        }
    }
    if (-not $hasImportSite) {
        $lines += "import site"
        $pthModified = $true
    }
    if ($pthModified) {
        [System.IO.File]::WriteAllLines($PthFile.FullName, [string[]]$lines, $Utf8NoBom)
        Write-Host "  -> 已启用 import site（原文件已备份为 $($PthFile.Name).bak）" -ForegroundColor Green
    } else {
        Write-Host "  -> 已处于解锁状态，跳过。" -ForegroundColor DarkGray
    }

    # 2. 写入或清理绿色版 pip 镜像配置
    Write-Host "[2/5] 配置 pip 镜像源 ..."
    if ($SelectedMirror -ne "None" -and $MirrorMap.ContainsKey($SelectedMirror)) {
        $m = $MirrorMap[$SelectedMirror]
        $iniContent = "[global]`r`nindex-url = $($m.Url)`r`ntrusted-host = $($m.Host)`r`n"
        [System.IO.File]::WriteAllText($PipIniFile, $iniContent, $Utf8NoBom)
        Write-Host "  -> 已写入绿色配置 pip.ini（$($m.Name)）：$PipIniFile" -ForegroundColor Green
    } else {
        if (Test-Path -LiteralPath $PipIniFile) {
            Remove-Item -LiteralPath $PipIniFile -Force
            Write-Host "  -> 已移除旧的 pip.ini，切回默认官方源。" -ForegroundColor Green
        } else {
            Write-Host "  -> 使用默认官方源，跳过写入 pip.ini。" -ForegroundColor DarkGray
        }
    }

    # 3. 补装 pip
    Write-Host "[3/5] 检查并安装 pip ..."
    $pipCheck = Invoke-NativeQuiet -FilePath $PyExe -Arguments @("-m", "pip", "--version")
    if ($pipCheck.ExitCode -eq 0) {
        Write-Host "  -> pip 已就绪：$($pipCheck.Output)" -ForegroundColor DarkGray
    } else {
        $getPipPath = Join-Path $PyDir "get-pip.py"
        try {
            Write-Host "  -> 正在下载 get-pip.py（超时 30 秒）..."
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $GetPipUrl -OutFile $getPipPath -UseBasicParsing -TimeoutSec 30

            $pipArgs = @($getPipPath, "--no-warn-script-location")
            if ($SelectedMirror -ne "None" -and $MirrorMap.ContainsKey($SelectedMirror)) {
                $m = $MirrorMap[$SelectedMirror]
                $pipArgs += @("-i", $m.Url, "--trusted-host", $m.Host)
            }

            Write-Host "  -> 正在安装 pip（请稍候）..."
            $oldPref = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & $PyExe @pipArgs
                $installCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldPref
            }
            if ($installCode -ne 0) {
                throw "pip 安装失败（退出码 $installCode），请检查网络连接或代理设置。"
            }
            Write-Host "  -> pip 安装完成。" -ForegroundColor Green
        } finally {
            Remove-Item -LiteralPath $getPipPath -Force -ErrorAction SilentlyContinue
        }
    }

    # 4. 可选：安装 virtualenv 补齐虚拟环境能力
    Write-Host "[4/5] 检查 virtualenv 虚拟环境支持 ..."
    if ($InstallVirtualenv) {
        $veCheck = Invoke-NativeQuiet -FilePath $PyExe -Arguments @("-m", "virtualenv", "--version")
        if ($veCheck.ExitCode -eq 0) {
            Write-Host "  -> virtualenv 已就绪：$($veCheck.Output)" -ForegroundColor DarkGray
        } else {
            Write-Host "  -> 正在安装 virtualenv ..."
            $oldPref = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & $PyExe -m pip install --no-warn-script-location virtualenv
                $veCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldPref
            }
            if ($veCode -ne 0) {
                throw "virtualenv 安装失败（退出码 $veCode）。"
            }
            Write-Host "  -> virtualenv 安装完成（后续可用 virtualenv .venv 创建项目虚拟环境）。" -ForegroundColor Green
        }
    } else {
        Write-Host "  -> 未勾选安装 virtualenv，跳过。" -ForegroundColor DarkGray
    }

    # 5. 写入用户环境变量 Path
    Write-Host "[5/5] 配置用户环境变量 Path ..."
    $pathAdded = Update-UserPath -TargetPaths @($PyDir, $ScriptsDir) -Mode Add
    if ($pathAdded) {
        Write-Host "  -> 已添加 Python 与 Scripts 目录到用户 Path（请重启终端生效）。" -ForegroundColor Green
    } else {
        Write-Host "  -> 环境变量已存在，跳过。" -ForegroundColor DarkGray
    }

    Write-Host "`n[完成] 绿色版 Python 基础环境已就绪！请重启终端后运行 python --version 与 pip --version 验证。" -ForegroundColor Cyan
}

# ======================== 模块 2：Antigravity 专项集成 ========================
function Invoke-AntigravityBind {
    Write-Host "=== [2] 配置 Antigravity 解释器支持 ===`n" -ForegroundColor Cyan

    if (-not (Test-PthUnlocked)) {
        Write-Host "[提示] 检测到 $($PthFile.Name) 尚未解锁第三方库，建议先执行选项 1 完成基础配置。" -ForegroundColor Yellow
    }

    $settingsFiles = @(Get-AntigravitySettingsFiles)
    if ($settingsFiles.Count -eq 0) {
        Write-Host "[提示] 未检测到 %APPDATA%\Antigravity 配置目录。" -ForegroundColor Yellow
        Write-Host "请先启动一次 Antigravity，再重新执行本选项即可自动写入。" -ForegroundColor Yellow
        return
    }

    foreach ($sf in $settingsFiles) {
        $parentDir = Split-Path $sf -Parent
        if (-not (Test-Path -LiteralPath $parentDir)) {
            New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
        }
        $bakFile = "$sf.py_setup.bak"
        if ((Test-Path -LiteralPath $sf) -and (-not (Test-Path -LiteralPath $bakFile))) {
            Copy-Item -LiteralPath $sf -Destination $bakFile -Force
        }
        try {
            $parsed = Read-JsonSafe -FilePath $sf
            $obj = $parsed.Data
            $obj | Add-Member -NotePropertyName "python.defaultInterpreterPath" -NotePropertyValue $PyExe -Force
            $jsonText = $obj | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($sf, $jsonText, $Utf8NoBom)
            Write-Host "  -> 已绑定解释器：$sf" -ForegroundColor Green
            if ($parsed.HadComments) {
                Write-Host "     [注意] 原文件含 JSON 注释，写回标准 JSON 时已移除注释；原始文件保留在 $bakFile" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  -> [警告] 解析 $sf 失败（$($_.Exception.Message)），已跳过以免破坏原配置。" -ForegroundColor Yellow
        }
    }

    Write-Host "`n[完成] Antigravity 解释器已指向：$PyExe（重启 IDE 后生效）。" -ForegroundColor Cyan
}

# ======================== 模块 3：一键撤销并恢复原始状态 ========================
function Invoke-ResetAll {
    Write-Host "=== [3] 撤销所有设置并恢复原始状态 ===`n" -ForegroundColor Yellow

    # 前置守卫 1：检测活动进程占用
    $lockers = @(Get-LockingProcesses -TargetDir $PyDir)
    if ($lockers.Count -gt 0) {
        Write-Host "[中止] 检测到当前 Python 目录正被以下进程占用，无法安全清理：" -ForegroundColor Red
        foreach ($lk in $lockers) {
            Write-Host "  - $($lk.Name) (PID: $($lk.Id)) -> $($lk.Path)" -ForegroundColor Yellow
        }
        Write-Host "请先关闭 Antigravity 或上述进程后再重试。" -ForegroundColor Yellow
        return
    }

    # 前置守卫 2：检测终端当前目录是否位于待删除子目录内
    $cwd = Normalize-PathEntry ((Get-Location).ProviderPath)
    foreach ($sub in @($LibDir, $ScriptsDir)) {
        $normSub = Normalize-PathEntry $sub
        if ($cwd -ieq $normSub -or $cwd.StartsWith("$normSub\", [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "[中止] 当前终端所在目录位于待清理路径内：$cwd" -ForegroundColor Red
            Write-Host "请先切换到其他目录（例如 cd `"$PyDir`"）后再执行撤销。" -ForegroundColor Yellow
            return
        }
    }

    if (-not $Force) {
        Write-Host "即将执行：移除 Antigravity 绑定、清理用户 Path、还原 ._pth，并删除 pip.ini / Lib / Scripts。" -ForegroundColor Yellow
        $confirm = Read-Host "确认恢复到刚解压时的纯净状态吗？[y/N]"
        if ($confirm -notin @("y", "Y", "yes", "YES")) {
            Write-Host "已取消操作。" -ForegroundColor DarkGray
            return
        }
    }

    # 1. 移除 Antigravity 绑定（若存在）
    Write-Host "[1/4] 检查并清理 Antigravity 配置 ..."
    $settingsFiles = @(Get-AntigravitySettingsFiles)
    $ideCleaned = $false
    foreach ($sf in $settingsFiles) {
        if (-not (Test-Path -LiteralPath $sf)) { continue }
        try {
            $parsed = Read-JsonSafe -FilePath $sf
            $obj = $parsed.Data
            $prop = $obj.PSObject.Properties["python.defaultInterpreterPath"]
            if ($prop -and ($prop.Value -ieq $PyExe)) {
                $obj.PSObject.Properties.Remove("python.defaultInterpreterPath")
                $jsonText = if (($obj.PSObject.Properties | Measure-Object).Count -eq 0) { "{}" } else { $obj | ConvertTo-Json -Depth 20 }
                [System.IO.File]::WriteAllText($sf, $jsonText, $Utf8NoBom)
                Write-Host "  -> 已移除解释器指向：$sf" -ForegroundColor Green
                $ideCleaned = $true
            }
            $bakFile = "$sf.py_setup.bak"
            if (Test-Path -LiteralPath $bakFile) {
                Remove-Item -LiteralPath $bakFile -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Host "  -> [警告] 跳过无法解析的配置文件：$sf" -ForegroundColor Yellow
        }
    }
    if (-not $ideCleaned) {
        Write-Host "  -> 无需清理 Antigravity 配置，跳过。" -ForegroundColor DarkGray
    }

    # 2. 移除用户 Path
    Write-Host "[2/4] 清理用户环境变量 Path ..."
    $pathRemoved = Update-UserPath -TargetPaths @($PyDir, $ScriptsDir) -Mode Remove
    if ($pathRemoved) {
        Write-Host "  -> 已从用户 Path 移除当前 Python 路径（请重启终端生效）。" -ForegroundColor Green
    } else {
        Write-Host "  -> 用户 Path 中无相关条目，跳过。" -ForegroundColor DarkGray
    }

    # 3. 还原 ._pth
    Write-Host "[3/4] 还原 $($PthFile.Name) ..."
    if (Test-Path -LiteralPath $PthBak) {
        Move-Item -LiteralPath $PthBak -Destination $PthFile.FullName -Force
        Write-Host "  -> 已通过备份还原 $($PthFile.Name)。" -ForegroundColor Green
    } else {
        $lines = [System.IO.File]::ReadAllLines($PthFile.FullName)
        $reverted = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*import\s+site\s*$') {
                $lines[$i] = "#import site"
                $reverted = $true
            }
        }
        if ($reverted) {
            [System.IO.File]::WriteAllLines($PthFile.FullName, [string[]]$lines, $Utf8NoBom)
            Write-Host "  -> 已重新注释 import site。" -ForegroundColor Green
        } else {
            Write-Host "  -> 已处于原始注释状态，跳过。" -ForegroundColor DarkGray
        }
    }

    # 4. 清理 Lib、Scripts、pip.ini 及残留临时文件
    Write-Host "[4/4] 清理目录内新增的包与配置文件 ..."
    $cleanupTargets = @(
        $LibDir,
        $ScriptsDir,
        $PipIniFile,
        (Join-Path $PyDir "get-pip.py"),
        (Join-Path $PyDir "__pycache__")
    )
    $removedAny = $false
    foreach ($target in $cleanupTargets) {
        if (Test-Path -LiteralPath $target) {
            try {
                Remove-Item -LiteralPath $target -Recurse -Force
                Write-Host "  -> 已删除：$target" -ForegroundColor Green
                $removedAny = $true
            } catch {
                throw "删除 $target 失败（可能仍有编辑器或后台进程占用文件，请关闭 Antigravity 后重试）：$($_.Exception.Message)"
            }
        }
    }
    if (-not $removedAny) {
        Write-Host "  -> 目录已是纯净状态，无需删除。" -ForegroundColor DarkGray
    }

    Write-Host "`n[完成] 所有设置已彻底撤销，目录与系统均已恢复原始状态（请重启终端以刷新环境变量）！" -ForegroundColor Cyan
}

# ======================== 模块 4：全面检查当前状态 ========================
function Invoke-StatusCheck {
    Write-Host "=== [4] 当前环境状态检查：$PyDir ===`n" -ForegroundColor Cyan

    # 1. Python 解释器
    $pyVer = Invoke-NativeQuiet -FilePath $PyExe -Arguments @("--version")
    Write-Host "[Python 解释器] " -NoNewline
    if ($pyVer.ExitCode -eq 0) {
        Write-Host "$($pyVer.Output) ($PyExe)" -ForegroundColor Green
    } else {
        Write-Host "执行异常：$($pyVer.Output)" -ForegroundColor Red
    }

    # 2. ._pth 状态
    $pthUnlocked = Test-PthUnlocked
    Write-Host "[._pth 解锁]    " -NoNewline
    $bakNote = if (Test-Path -LiteralPath $PthBak) { "，存在 .bak 原始备份" } else { "" }
    if ($pthUnlocked) {
        Write-Host "已解锁（$($PthFile.Name) 已启用 import site$bakNote）" -ForegroundColor Green
    } else {
        Write-Host "未解锁（$($PthFile.Name) 中 import site 仍被注释$bakNote）" -ForegroundColor Yellow
    }

    # 3. pip 状态
    Write-Host "[pip 包管理器]  " -NoNewline
    $pipCheck = Invoke-NativeQuiet -FilePath $PyExe -Arguments @("-m", "pip", "--version")
    if ($pipCheck.ExitCode -eq 0) {
        Write-Host "已安装（$($pipCheck.Output)）" -ForegroundColor Green
    } elseif (-not $pthUnlocked -and (Test-Path -LiteralPath (Join-Path $LibDir "site-packages\pip"))) {
        Write-Host "目录内存在 pip，但因 ._pth 未解锁而无法加载" -ForegroundColor Yellow
    } else {
        Write-Host "未安装" -ForegroundColor DarkGray
    }

    # 4. 绿色版 pip.ini 镜像源（含用户级覆盖预警）
    Write-Host "[pip 镜像源]    " -NoNewline
    if (Test-Path -LiteralPath $PipIniFile) {
        $iniLines = [System.IO.File]::ReadAllLines($PipIniFile, $Utf8NoBom)
        $urlLine  = $iniLines | Where-Object { $_ -match '^\s*index-url\s*=\s*(.+)$' } | Select-Object -First 1
        if ($urlLine -and $urlLine -match '^\s*index-url\s*=\s*(.+)$') {
            Write-Host "已配置（$($Matches[1].Trim())）" -ForegroundColor Green
        } else {
            Write-Host "存在 $PipIniFile，但未解析到 index-url" -ForegroundColor Yellow
        }
        $userPipInis = @(
            (Join-Path $env:APPDATA "pip\pip.ini"),
            (Join-Path $env:USERPROFILE "pip\pip.ini")
        ) | Where-Object { Test-Path -LiteralPath $_ }
        foreach ($upi in $userPipInis) {
            Write-Host "  -> [提示] 检测到用户级配置 $upi（优先级高于绿色版 pip.ini）" -ForegroundColor Yellow
        }
    } else {
        Write-Host "默认官方源（目录内无 pip.ini）" -ForegroundColor DarkGray
    }

    # 5. virtualenv 状态
    Write-Host "[virtualenv]    " -NoNewline
    $veCheck = Invoke-NativeQuiet -FilePath $PyExe -Arguments @("-m", "virtualenv", "--version")
    if ($veCheck.ExitCode -eq 0) {
        Write-Host "已安装（$($veCheck.Output)）" -ForegroundColor Green
    } else {
        Write-Host "未安装" -ForegroundColor DarkGray
    }

    # 6. 用户环境变量 Path（直读注册表，含优先级冲突排查）
    Write-Host "[用户 Path]     " -NoNewline
    $pathStatus = Get-UserPathStatus
    if ($pathStatus.HasPyDir -and $pathStatus.HasScripts) {
        Write-Host "完整（根目录 + Scripts 均已写入注册表）" -ForegroundColor Green
    } elseif ($pathStatus.HasPyDir -or $pathStatus.HasScripts) {
        $missing = if (-not $pathStatus.HasPyDir) { "缺少根目录" } else { "缺少 Scripts 目录" }
        Write-Host "不完整（$missing，建议重新运行选项 1 补齐）" -ForegroundColor Yellow
    } else {
        Write-Host "未写入" -ForegroundColor DarkGray
    }

    if ($pathStatus.HasPyDir) {
        $shadows = @(Get-ShadowingPythons)
        if ($shadows.Count -gt 0) {
            Write-Host "  -> [提示] Path 中更靠前位置存在其他 python.exe，终端直接输入 python 可能优先命中：" -ForegroundColor Yellow
            foreach ($sh in $shadows) {
                $aliasHint = if ($sh -match 'Microsoft\\WindowsApps\\python\.exe$') { "（Windows 应用执行别名，可在系统设置中关闭）" } else { "" }
                Write-Host "     - $sh$aliasHint" -ForegroundColor Yellow
            }
        }
    }

    # 7. Antigravity 绑定状态
    Write-Host "[Antigravity]   " -NoNewline
    $settingsFiles = @(Get-AntigravitySettingsFiles)
    if ($settingsFiles.Count -eq 0) {
        Write-Host "未检测到 %APPDATA%\Antigravity 配置目录" -ForegroundColor DarkGray
    } else {
        Write-Host ""
        foreach ($sf in $settingsFiles) {
            if (-not (Test-Path -LiteralPath $sf)) {
                Write-Host "  - [未配置] $sf（文件尚未创建）" -ForegroundColor DarkGray
                continue
            }
            try {
                $parsed = Read-JsonSafe -FilePath $sf
                $prop   = $parsed.Data.PSObject.Properties["python.defaultInterpreterPath"]
                if (-not $prop -or [string]::IsNullOrWhiteSpace([string]$prop.Value)) {
                    Write-Host "  - [未绑定] $sf（未设置 defaultInterpreterPath）" -ForegroundColor DarkGray
                } elseif ($prop.Value -ieq $PyExe) {
                    Write-Host "  - [已绑定] $sf -> 当前 Python" -ForegroundColor Green
                } else {
                    Write-Host "  - [其他路径] $sf -> $($prop.Value)" -ForegroundColor Yellow
                }
            } catch {
                Write-Host "  - [解析失败] $sf（$($_.Exception.Message)）" -ForegroundColor Yellow
            }
        }
    }

    # 8. 进程占用检测（仅在存在占用时提醒）
    $lockers = @(Get-LockingProcesses -TargetDir $PyDir)
    if ($lockers.Count -gt 0) {
        Write-Host "[占用进程]      检测到活动进程（执行选项 3 撤销前需先关闭）：" -ForegroundColor Yellow
        foreach ($lk in $lockers) {
            Write-Host "  - $($lk.Name) (PID: $($lk.Id)) -> $($lk.Path)" -ForegroundColor Yellow
        }
    }
}

# ======================== 入口路由 ========================
switch ($Action) {
    "Base" {
        Invoke-BaseInstall -SelectedMirror $Mirror -InstallVirtualenv $WithVirtualenv.IsPresent
    }
    "Antigravity" {
        Invoke-AntigravityBind
    }
    "Reset" {
        Invoke-ResetAll
    }
    "Status" {
        Invoke-StatusCheck
    }
    "Menu" {
        Clear-ScreenSafe
        while ($true) {
            Write-Host "==========================================" -ForegroundColor DarkGray
            Write-Host " 绿色版 Python 管理脚本" -ForegroundColor Cyan
            Write-Host " 当前目录：$PyDir" -ForegroundColor Gray
            Write-Host "==========================================" -ForegroundColor DarkGray
            Write-Host "1) 基础安装（解锁 ._pth + 可选国内镜像 + 装 pip + 可选 virtualenv + 配 Path）"
            Write-Host "2) 反重力支持（将 Antigravity 默认解释器绑定到此 Python）"
            Write-Host "3) 撤销所有设置（清理 Path / IDE 配置 / 还原 ._pth 与纯净目录）"
            Write-Host "4) 检查当前状态（体检 ._pth / pip / 镜像 / virtualenv / Path / 反重力）"
            Write-Host "0) 退出"

            $rawChoice = Read-Host "`n请选择 [0-4]"
            if ($null -eq $rawChoice) { break }
            $choice = $rawChoice.Trim()

            if ($choice -in @("0", "q", "Q")) {
                Write-Host "已退出。"
                break
            }
            if ($choice -notin @("1", "2", "3", "4")) {
                Write-Host "[提示] 无效选项，请输入 0-4。" -ForegroundColor Yellow
                Start-Sleep -Milliseconds 900
                Clear-ScreenSafe
                continue
            }

            Clear-ScreenSafe
            try {
                switch ($choice) {
                    "1" {
                        Write-Host "=== [1] 绿色版 Python 基础配置选项 ===" -ForegroundColor Cyan
                        Write-Host "`n请选择 pip 镜像源（写入当前目录 pip.ini，保持纯绿色）："
                        Write-Host "  0) 官方源 PyPI（不配置国内镜像，默认）"
                        Write-Host "  1) 清华大学 TUNA"
                        Write-Host "  2) 阿里云"
                        Write-Host "  3) 中科大 USTC"
                        $mChoice = Read-Host "请选择 [0-3，回车默认 0]"
                        if ($mChoice) { $mChoice = $mChoice.Trim() }
                        $chosenMirror = switch ($mChoice) {
                            "1" { "Tsinghua" }
                            "2" { "Aliyun" }
                            "3" { "USTC" }
                            default { "None" }
                        }

                        $vChoice = Read-Host "是否安装 virtualenv 以补齐绿色版缺失的虚拟环境功能？[Y/n，默认 Y]"
                        if ($vChoice) { $vChoice = $vChoice.Trim() }
                        $chosenVenv = ($vChoice -notin @("n", "N", "no", "NO"))

                        Clear-ScreenSafe
                        Invoke-BaseInstall -SelectedMirror $chosenMirror -InstallVirtualenv $chosenVenv
                    }
                    "2" { Invoke-AntigravityBind }
                    "3" { Invoke-ResetAll }
                    "4" { Invoke-StatusCheck }
                }
            } catch {
                Write-Host "`n[错误] 执行失败：$($_.Exception.Message)" -ForegroundColor Red
            }

            Read-Host "`n按回车键返回主菜单" | Out-Null
            Clear-ScreenSafe
        }
    }
}