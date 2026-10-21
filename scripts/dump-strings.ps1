<#
.SYNOPSIS
    导出 NeatDM.exe 内的全部 UTF-16LE 字符串，用于对照 / 补词条。

.DESCRIPTION
    修改 translations.json 时，英文键必须和 exe 里存储的完全一致（含首尾空格）。
    本脚本把 exe 里所有 UTF-16LE 可打印字符串连同文件偏移导出，方便核对。

.EXAMPLE
    .\dump-strings.ps1
    .\dump-strings.ps1 -ExePath "D:\Neat Download Manager\NeatDM.exe" -Filter "Download"
#>
[CmdletBinding()]
param(
    [string]$ExePath,
    [string]$Filter,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

if (-not $ExePath) {
    $cands = @()
    foreach ($k in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
        Get-ItemProperty -Path $k -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Neat Download Manager*' } |
            ForEach-Object { if ($_.InstallLocation) { $cands += (Join-Path $_.InstallLocation 'NeatDM.exe') } }
    }
    $cands += "${env:ProgramFiles(x86)}\Neat Download Manager\NeatDM.exe"
    $cands += "$env:ProgramFiles\Neat Download Manager\NeatDM.exe"

    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { $ExePath = $c; break } }
}

if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) {
    Write-Host '未找到 NeatDM.exe，请用 -ExePath 指定。' -ForegroundColor Red
    exit 1
}

if (-not $OutFile) {
    $OutFile = Join-Path $PSScriptRoot 'ndm-strings.txt'
}

$bytes = [System.IO.File]::ReadAllBytes($ExePath)
$enc16 = [System.Text.Encoding]::Unicode

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# 来源: $ExePath")
$lines.Add("# 大小: $($bytes.Length) 字节")
$lines.Add("# 格式: <文件偏移>  <字符串>(repr)")
$lines.Add('')

$sb = New-Object System.Text.StringBuilder
$start = -1
for ($i = 0; $i -lt $bytes.Length - 1; $i += 2) {
    $b0 = $bytes[$i]
    $b1 = $bytes[$i + 1]
    if ($b1 -eq 0 -and $b0 -ge 0x20 -and $b0 -le 0x7E) {
        if ($start -lt 0) { $start = $i }
        [void]$sb.Append([char]$b0)
    }
    else {
        if ($start -ge 0 -and $sb.Length -ge 3) {
            $t = $sb.ToString()
            if (-not $Filter -or $t -like "*$Filter*") {
                $lines.Add(('0x{0:X6}  {1}' -f $start, ($t -replace "'", "''")))
            }
        }
        [void]$sb.Clear()
        $start = -1
    }
}

$lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
Write-Host "已导出 $($lines.Count - 4) 条字符串 → $OutFile" -ForegroundColor Green
if ($Filter) { Write-Host "（已按 '$Filter' 过滤）" -ForegroundColor DarkGray }
