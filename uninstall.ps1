<#
    卸载脚本：删除自启项、结束监听进程，并删除安装目录。
    用法： powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'CampusAutologin')
)
$ErrorActionPreference = 'Stop'
$main = Join-Path $InstallDir 'campus-autologin.ps1'
if (Test-Path -LiteralPath $main) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $main -UnregisterTask
} else {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*campus-autologin.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
$guiLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '校园网自动登录(GUI).lnk'
if (Test-Path -LiteralPath $guiLnk) {
    Remove-Item -LiteralPath $guiLnk -Force
    Write-Host '已删除图形版开机自启快捷方式。'
}

$resolved = [IO.Path]::GetFullPath($InstallDir)
if (-not $resolved.TrimEnd('\').EndsWith('CampusAutologin')) {
    throw ("拒绝删除非预期目录: {0}" -f $resolved)
}
if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
Write-Host ('已卸载: {0}' -f $resolved)
