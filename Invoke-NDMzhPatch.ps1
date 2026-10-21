<#
.SYNOPSIS
    Neat Download Manager (NDM) Windows 版简体中文汉化 / 还原脚本。

.DESCRIPTION
    NDM 的界面文字以 UTF-16LE 硬编码在 NeatDM.exe 内，没有语言资源、也没有外部语言包，
    因此本脚本采用"原地等长替换"的方式汉化：
      * 中文的 UTF-16LE 字节数 <= 原文（含空终止符）时，替换并在多余位置补 \x00；
      * 中文比原文长时，跳过该条并报告（绝不撑爆原位置）；
      * 文件总长度始终保持不变，PE 结构不受影响。
    脚本会先备份原版 exe，可随时用 -Action Restore 一键还原。

.PARAMETER Action
    Install  汉化（默认）
    Restore  从备份还原英文原版
    DryRun   只统计能替换多少条，不写文件
    Status   显示当前状态（版本、是否已汉化、备份情况）

.PARAMETER ExePath
    NeatDM.exe 的完整路径。不指定时自动探测（注册表 + 常见安装目录）。

.PARAMETER Force
    不询问，自动关闭正在运行的 NDM。

.PARAMETER NoRestart
    汉化完成后不自动启动 NDM。

.EXAMPLE
    .\Invoke-NDMzhPatch.ps1

.EXAMPLE
    .\Invoke-NDMzhPatch.ps1 -Action DryRun

.EXAMPLE
    .\Invoke-NDMzhPatch.ps1 -Action Restore
#>
[CmdletBinding()]
param(
    [ValidateSet('Install', 'Restore', 'DryRun', 'Status')]
    [string]$Action = 'Install',

    [string]$ExePath,

    [switch]$Force,

    [switch]$NoRestart
)

$ErrorActionPreference = 'Stop'

# ============ 常量 ============
$script:TargetVersion = '1.4.24'
$script:BackupRoot = Join-Path $env:LOCALAPPDATA 'NDMzhPatch\backup'
$script:OrigBackup = Join-Path $script:BackupRoot 'NeatDM.exe.orig'
$script:LastReport = Join-Path $script:BackupRoot 'last-report.txt'

# UTF-16LE（用于生成目标字节）与 Latin1（1字节=1字符，用于高速字符串查找）
$script:Enc16 = [System.Text.Encoding]::Unicode
$script:Latin1 = [System.Text.Encoding]::GetEncoding(28591)

# ============ 输出辅助 ============
function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 62) -ForegroundColor DarkCyan
}
function Write-Ok([string]$Text)   { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "  [警告] $Text" -ForegroundColor Yellow }
function Write-Err2([string]$Text) { Write-Host "  [错误] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "  $Text" -ForegroundColor Gray }

# ============ 基础检查 ============
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-IsAdmin)) {
        Write-Err2 '需要管理员权限（要写入 Program Files 下的文件）。'
        Write-Info '请右键 PowerShell / Windows 终端 → "以管理员身份运行"，然后重新执行本脚本。'
        exit 1
    }
}

# ============ 定位 exe ============
function Find-NDMExe {
    param([string]$Hint)

    if ($Hint) {
        if (Test-Path -LiteralPath $Hint) { return (Resolve-Path -LiteralPath $Hint).Path }
        Write-Warn2 "指定的路径不存在: $Hint"
    }

    $cands = New-Object System.Collections.Generic.List[string]

    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $uninstallKeys) {
        try {
            Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like '*Neat Download Manager*' } |
                ForEach-Object {
                    if ($_.InstallLocation) {
                        $cands.Add((Join-Path $_.InstallLocation 'NeatDM.exe'))
                    }
                }
        } catch { }
    }

    if ($env:ProgramFiles)        { $cands.Add((Join-Path $env:ProgramFiles 'Neat Download Manager\NeatDM.exe')) }
    if (${env:ProgramFiles(x86)}) { $cands.Add((Join-Path ${env:ProgramFiles(x86)} 'Neat Download Manager\NeatDM.exe')) }
    $cands.Add((Join-Path $env:LOCALAPPDATA 'Programs\Neat Download Manager\NeatDM.exe'))

    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

# ============ 进程控制 ============
function Get-NDMProcess {
    return @(Get-Process -Name 'NeatDM', 'NeatDMEngine' -ErrorAction SilentlyContinue)
}

function Stop-NDMProcess {
    param([switch]$NoPrompt)

    $procs = @(Get-NDMProcess)
    if ($procs.Count -eq 0) { return $true }

    if (-not $NoPrompt -and -not $Force) {
        Write-Warn2 "检测到 NDM 正在运行（PID: $($procs.Id -join ', ')）。"
        $ans = Read-Host '  需要关闭它才能修改文件。是否继续？(Y/n)'
        if ($ans -and $ans -notmatch '^[Yy]') {
            Write-Info '已取消。'
            return $false
        }
    }

    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Write-Info "已关闭进程 $($p.Name) (PID=$($p.Id))" }
        catch { Write-Warn2 "无法关闭 PID=$($p.Id): $($_.Exception.Message)" }
    }
    Start-Sleep -Milliseconds 1500

    if (@(Get-NDMProcess).Count -gt 0) {
        Write-Err2 '仍有 NDM 进程在运行，请手动退出后重试（注意托盘图标也要退出）。'
        return $false
    }
    return $true
}

function Start-NDMProcess {
    param([string]$Path)
    try {
        Start-Process -FilePath $Path | Out-Null
        Write-Info '已启动 Neat Download Manager。'
    } catch {
        Write-Warn2 "自动启动失败，请手动打开：$Path"
    }
}

# ============ 备份 ============
function Initialize-Backup {
    param([string]$SourceExe)

    if (-not (Test-Path -LiteralPath $script:BackupRoot)) {
        New-Item -ItemType Directory -Force -Path $script:BackupRoot | Out-Null
    }

    if (Test-Path -LiteralPath $script:OrigBackup) {
        Write-Info "原版备份已存在，保留不覆盖：$script:OrigBackup"
        return $script:OrigBackup
    }

    # 若当前 exe 已经是汉化过的（找不到标志性英文串），则不要当原版备份
    if (-not (Test-IsOriginalExe $SourceExe)) {
        Write-Warn2 '当前 exe 似乎已经是汉化版，无法据此生成"英文原版"备份。'
        Write-Info '如需干净的原版备份，请从官网重新安装后再运行本脚本。'
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $alt = Join-Path $script:BackupRoot "NeatDM.exe.zh_$ts"
        Copy-Item -LiteralPath $SourceExe -Destination $alt -Force
        Write-Info "已保存当前状态副本：$alt"
        return $null
    }

    Copy-Item -LiteralPath $SourceExe -Destination $script:OrigBackup -Force
    Write-Ok "已备份英文原版 → $script:OrigBackup"
    return $script:OrigBackup
}

# ============ 判断是否已汉化 ============
function Test-IsOriginalExe {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hay = $script:Latin1.GetString($bytes)
    # "Settings" / "Download" 这类一定存在的英文界面串
    $probe = $script:Latin1.GetString($script:Enc16.GetBytes('Settings' + [char]0))
    return ($hay.IndexOf($probe, [StringComparison]::Ordinal) -ge 0)
}

# ============ 读取翻译表 ============
function Get-TranslationPairs {
    $jsonPath = Join-Path $PSScriptRoot 'translations.json'
    if (-not (Test-Path -LiteralPath $jsonPath)) {
        Write-Err2 "找不到翻译表: $jsonPath"
        Write-Info '请确保 translations.json 与本脚本放在同一目录。'
        exit 1
    }

    $raw = [System.IO.File]::ReadAllText($jsonPath, [System.Text.Encoding]::UTF8)
    $json = $raw | ConvertFrom-Json

    $pairs = New-Object System.Collections.Generic.List[object]
    foreach ($group in $json.translations.PSObject.Properties) {
        foreach ($item in $group.Value.PSObject.Properties) {
            $pairs.Add([pscustomobject]@{
                English = $item.Name
                Chinese = [string]$item.Value
                Group   = $group.Name
            })
        }
    }
    return $pairs
}

# ============ 核心：等长替换 ============
function Invoke-Replace {
    param(
        [byte[]]$Bytes,
        [object[]]$Pairs
    )

    $hay = $script:Latin1.GetString($Bytes)

    # 长串优先，避免短串先命中长串内部（理论上已由 \0 终止符隔离，这里再加一层保险）
    $sorted = $Pairs | Sort-Object -Property @{ Expression = { $_.English.Length } } -Descending

    $replaced = New-Object System.Collections.Generic.List[object]
    $tooLong  = New-Object System.Collections.Generic.List[object]
    $missing  = New-Object System.Collections.Generic.List[object]

    foreach ($p in $sorted) {
        $eb = $script:Enc16.GetBytes($p.English + [char]0)
        $cb = $script:Enc16.GetBytes($p.Chinese + [char]0)

        if ($cb.Length -gt $eb.Length) {
            $tooLong.Add([pscustomobject]@{ English = $p.English; Chinese = $p.Chinese; EngBytes = $eb.Length; ChsBytes = $cb.Length })
            continue
        }

        $needle = $script:Latin1.GetString($eb)
        $pad    = New-Object byte[] ($eb.Length - $cb.Length)   # 自动全 0
        $repl   = New-Object 'byte[]' $eb.Length
        [Array]::Copy($cb, 0, $repl, 0, $cb.Length)
        [Array]::Copy($pad, 0, $repl, $cb.Length, $pad.Length)

        $count = 0
        $pos = 0
        while ($true) {
            $idx = $hay.IndexOf($needle, $pos, [StringComparison]::Ordinal)
            if ($idx -lt 0) { break }
            [Array]::Copy($repl, 0, $Bytes, $idx, $repl.Length)
            $count++
            $pos = $idx + $eb.Length
        }

        if ($count -gt 0) {
            $replaced.Add([pscustomobject]@{ English = $p.English; Chinese = $p.Chinese; Count = $count })
        } else {
            $missing.Add([pscustomobject]@{ English = $p.English; Chinese = $p.Chinese })
        }
    }

    return @{
        Replaced = $replaced
        TooLong  = $tooLong
        Missing  = $missing
    }
}

# ============ 动作：Status ============
function Invoke-Status {
    param([string]$Exe)

    Write-Title '当前状态'

    if (-not $Exe) {
        Write-Err2 '未找到 NeatDM.exe，请用 -ExePath 指定路径。'
        exit 1
    }

    $item = Get-Item -LiteralPath $Exe
    Write-Info "程序路径 : $($item.FullName)"
    Write-Info "文件版本 : $($item.VersionInfo.FileVersion)"
    Write-Info "文件大小 : $($item.Length) 字节"
    Write-Info "SHA256   : $((Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash)"

    if (Test-IsOriginalExe $Exe) {
        Write-Info '界面语言 : 英文原版（未汉化）'
    } else {
        Write-Ok '界面语言 : 已汉化（简体中文）'
    }

    if (Test-Path -LiteralPath $script:OrigBackup) {
        $bo = Get-Item -LiteralPath $script:OrigBackup
        Write-Ok "原版备份 : $($bo.FullName)  ($($bo.LastWriteTime))"
    } else {
        Write-Warn2 '原版备份 : 不存在（无法用 Restore 还原，需重装官方版）'
    }

    $running = @(Get-NDMProcess)
    if ($running.Count -gt 0) { Write-Info "运行状态 : 正在运行 (PID: $($running.Id -join ', '))" }
    else { Write-Info '运行状态 : 未运行' }
}

# ============ 动作：DryRun ============
function Invoke-DryRun {
    param([string]$Exe)

    Write-Title '预演模式（不修改任何文件）'

    $bytes = [System.IO.File]::ReadAllBytes($Exe)
    $pairs = Get-TranslationPairs
    Write-Info "翻译表词条数: $($pairs.Count)"
    Write-Info "exe 大小     : $($bytes.Length) 字节"

    $work = New-Object 'byte[]' $bytes.Length
    [Array]::Copy($bytes, 0, $work, 0, $bytes.Length)

    $r = Invoke-Replace -Bytes $work -Pairs @($pairs)

    Write-Info "可替换 : $($r.Replaced.Count) 条（共 $(($r.Replaced | Measure-Object Count -Sum).Sum) 处）"
    Write-Info "中文过长跳过 : $($r.TooLong.Count) 条"
    Write-Info "exe 中未找到 : $($r.Missing.Count) 条"

    if ($r.TooLong.Count -gt 0) {
        Write-Warn2 '以下词条中文比英文长，会被跳过：'
        $r.TooLong | ForEach-Object { Write-Info ("  {0}  ({1} vs {2} 字节)" -f $_.English, $_.EngBytes, $_.ChsBytes) }
    }
    if ($r.Missing.Count -gt 0) {
        Write-Warn2 '以下词条在当前版本 exe 中不存在（可能是版本差异，或已汉化）：'
        $r.Missing | Select-Object -First 30 | ForEach-Object { Write-Info ("  {0}" -f $_.English) }
        if ($r.Missing.Count -gt 30) { Write-Info "  ...（共 $($r.Missing.Count) 条）" }
    }
    Write-Ok '预演完成，未写入任何文件。'
}

# ============ 动作：Install ============
function Invoke-Install {
    param([string]$Exe)

    Write-Title 'Neat Download Manager 简体中文汉化'

    $ver = (Get-Item -LiteralPath $Exe).VersionInfo.FileVersion
    Write-Info "目标程序 : $Exe"
    Write-Info "文件版本 : $ver"
    if ($ver -and $ver -notlike "$script:TargetVersion*") {
        Write-Warn2 "本补丁针对 $script:TargetVersion 开发，当前版本 $ver 可能存在少量词条差异（脚本会自动跳过不匹配项，不会损坏文件）。"
    }

    if (-not (Test-IsOriginalExe $Exe)) {
        Write-Warn2 '当前 exe 看起来已经是汉化状态。'
        Write-Info '如需重新汉化（例如更新了 NDM），可以直接继续；如需先还原请用 -Action Restore。'
    }

    if (-not (Stop-NDMProcess)) { exit 1 }

    Initialize-Backup -SourceExe $Exe | Out-Null

    Write-Title '正在替换界面文字'
    $orig = [System.IO.File]::ReadAllBytes($Exe)
    $origSize = $orig.Length
    $bytes = New-Object 'byte[]' $origSize
    [Array]::Copy($orig, 0, $bytes, 0, $origSize)

    $pairs = Get-TranslationPairs
    $r = Invoke-Replace -Bytes $bytes -Pairs @($pairs)

    $total = ($r.Replaced | Measure-Object Count -Sum).Sum
    Write-Info "成功替换 : $($r.Replaced.Count) 条词条 / 共 $total 处"
    if ($r.TooLong.Count -gt 0)  { Write-Info "中文过长跳过 : $($r.TooLong.Count) 条" }
    if ($r.Missing.Count -gt 0)  { Write-Info "未找到 : $($r.Missing.Count) 条（版本差异或已汉化）" }

    # 完整性校验：长度必须不变
    if ($bytes.Length -ne $origSize) {
        Write-Err2 "内部错误：文件长度发生变化（$origSize → $($bytes.Length)），已中止写入。原始文件未受影响。"
        exit 1
    }

    # 写入（先写临时文件再替换，避免写入中途失败留下坏文件）
    $tmp = "$Exe.ndmzh.tmp"
    try {
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
        if ((Get-Item -LiteralPath $tmp).Length -ne $origSize) { throw '临时文件长度校验失败' }
        Move-Item -LiteralPath $tmp -Destination $Exe -Force
    } catch {
        Write-Err2 "写入失败: $($_.Exception.Message)"
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        exit 1
    }

    # 记录报告
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) { New-Item -ItemType Directory -Force -Path $script:BackupRoot | Out-Null }
    $report = @()
    $report += "时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $report += "程序: $Exe"
    $report += "版本: $ver"
    $report += "替换: $($r.Replaced.Count) 条词条 / $total 处"
    $report += "跳过(过长): $($r.TooLong.Count)"
    $report += "未找到: $($r.Missing.Count)"
    $report += ''
    $report += '[已替换]'
    $r.Replaced | ForEach-Object { $report += ("  [{0}处] {1} -> {2}" -f $_.Count, $_.English, $_.Chinese) }
    if ($r.Missing.Count -gt 0) {
        $report += ''
        $report += '[未找到]'
        $r.Missing | ForEach-Object { $report += ("  {0}" -f $_.English) }
    }
    $report | Set-Content -LiteralPath $script:LastReport -Encoding UTF8

    Write-Ok "汉化完成！文件大小保持 $origSize 字节不变。"
    Write-Info "详细报告 : $script:LastReport"
    Write-Info "原版备份 : $script:OrigBackup"
    Write-Info '如需还原英文：.\Invoke-NDMzhPatch.ps1 -Action Restore'

    if (-not $NoRestart) {
        Start-NDMProcess -Path $Exe
    }
}

# ============ 动作：Restore ============
function Invoke-Restore {
    param([string]$Exe)

    Write-Title '还原英文原版'

    if (-not (Test-Path -LiteralPath $script:OrigBackup)) {
        Write-Err2 "找不到原版备份: $script:OrigBackup"
        Write-Info '可以安装程序重新覆盖安装 NDM，即可恢复英文原版。'
        Write-Info '官网: https://www.neatdownloadmanager.com'
        exit 1
    }

    if (-not $Exe) {
        Write-Err2 '未找到 NeatDM.exe，请用 -ExePath 指定路径。'
        exit 1
    }

    if (-not (Stop-NDMProcess)) { exit 1 }

    try {
        Copy-Item -LiteralPath $script:OrigBackup -Destination $Exe -Force
        Write-Ok "已从备份还原: $script:OrigBackup → $Exe"
    } catch {
        Write-Err2 "还原失败: $($_.Exception.Message)"
        exit 1
    }

    if (-not $NoRestart) {
        Start-NDMProcess -Path $Exe
    }
}

# ============ 主流程 ============
try {
    Write-Host ''
    Write-Host '  Neat Download Manager 简体中文汉化脚本' -ForegroundColor Cyan
    Write-Host '  Windows 版 / 纯 PowerShell 实现 / 详见 README' -ForegroundColor DarkGray

    $needAdmin = ($Action -eq 'Install' -or $Action -eq 'Restore')
    if ($needAdmin) { Assert-Admin }

    $exe = Find-NDMExe -Hint $ExePath
    if (-not $exe -and $Action -ne 'Status') {
        Write-Err2 '未找到 Neat Download Manager 的安装位置。'
        Write-Info '请确认已安装 NDM，或用 -ExePath 手动指定 NeatDM.exe 路径：'
        Write-Info '  .\Invoke-NDMzhPatch.ps1 -ExePath "D:\Neat Download Manager\NeatDM.exe"'
        exit 1
    }

    switch ($Action) {
        'Status'  { Invoke-Status -Exe $exe }
        'DryRun'  { Invoke-DryRun -Exe $exe }
        'Install' { Invoke-Install -Exe $exe }
        'Restore' { Invoke-Restore -Exe $exe }
    }

    Write-Host ''
} catch {
    Write-Host ''
    Write-Err2 "脚本执行出错: $($_.Exception.Message)"
    Write-Info $_.ScriptStackTrace
    exit 1
}
