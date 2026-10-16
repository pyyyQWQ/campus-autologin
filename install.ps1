<#
    安装脚本：把主脚本复制到安装目录，并设置为开机自启。
    用法： powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
    选项： -InstallDir <路径>   -SkipSetup
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'CampusAutologin'),
    [switch]$SkipSetup
)
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $PSCommandPath
$mainSrc = Join-Path $src 'campus-autologin.ps1'
if (-not (Test-Path -LiteralPath $mainSrc)) { throw "找不到 campus-autologin.ps1（应在 install.ps1 同目录）" }

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -LiteralPath $mainSrc -Destination (Join-Path $InstallDir 'campus-autologin.ps1') -Force

$cfgSrc = Join-Path $src 'campus-autologin.config.json'
$cfgDst = Join-Path $InstallDir 'campus-autologin.config.json'
if ((Test-Path -LiteralPath $cfgSrc) -and -not (Test-Path -LiteralPath $cfgDst)) {
    Copy-Item -LiteralPath $cfgSrc -Destination $cfgDst
}

$main = Join-Path $InstallDir 'campus-autologin.ps1'
if (-not $SkipSetup -and -not (Test-Path -LiteralPath $cfgDst)) {
    Write-Host '未发现配置，进入配置向导...'
    & powershell -NoProfile -ExecutionPolicy Bypass -File $main -Setup
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $main -RegisterTask
Write-Host ''
Write-Host '安装完成。常用命令：'
Write-Host ('  查看状态: powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Status' -f $main)
Write-Host ('  卸载    : powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -UnregisterTask' -f $main)