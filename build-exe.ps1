<#
    打包脚本：用 ps2exe 生成两个 exe
      dist\campus-autologin.exe      命令行版（保留控制台窗口，适合 -Status / -Watch / 计划任务）
      dist\campus-autologin-gui.exe  图形界面版（无控制台窗口，双击即用，可缩到托盘后台重连）

    用法： powershell -NoProfile -ExecutionPolicy Bypass -File .\build-exe.ps1
    可选： -Version 1.0.0   -OutputDir <目录>
    首次运行需要联网，从 PSGallery 安装 ps2exe（仅当前用户，无需管理员）。
#>
[CmdletBinding()]
param(
    [string]$Version = '1.0.0',
    [string]$OutputDir
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host '未检测到 ps2exe，正在从 PSGallery 安装（当前用户）...'
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -Force

$root = Split-Path -Parent $PSCommandPath
if (-not $OutputDir) { $OutputDir = Join-Path $root 'dist' }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$iconArgs = @{}
$icon = Join-Path $root 'assets\icon.ico'
if (Test-Path -LiteralPath $icon) { $iconArgs['IconFile'] = $icon }

$common = @{
    Product = 'campus-autologin'
    Company = 'campus-autologin'
    Version = $Version
}
foreach ($k in @($iconArgs.Keys)) { $common[$k] = $iconArgs[$k] }

# 1) 命令行版：保留控制台窗口
Invoke-PS2EXE -InputFile (Join-Path $root 'campus-autologin.ps1') `
    -OutputFile (Join-Path $OutputDir 'campus-autologin.exe') `
    -Title '校园网自动登录' -Description 'Dr.COM 校园网自动登录 / 断网自动重连（命令行版）' `
    -NoConsole:$false @common

# 2) 图形界面版：无控制台窗口 + STA（WinForms 必须）
Invoke-PS2EXE -InputFile (Join-Path $root 'campus-autologin-gui.ps1') `
    -OutputFile (Join-Path $OutputDir 'campus-autologin-gui.exe') `
    -Title '校园网自动登录' -Description 'Dr.COM 校园网自动登录 / 断网自动重连（图形界面版）' `
    -NoConsole -STA @common

Get-ChildItem -LiteralPath $OutputDir -Filter *.exe | ForEach-Object {
    Write-Host ('已生成: {0}  ({1:N0} 字节)' -f $_.FullName, $_.Length)
}
Write-Host '提示：exe 没有代码签名，Windows SmartScreen 可能提示"未知发布者"，属正常现象。'