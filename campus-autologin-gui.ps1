<#
.SYNOPSIS
    Dr.COM quickauth 门户 校园网自动登录 / 断网自动重连 —— 图形界面版。

.DESCRIPTION
    与 campus-autologin.ps1 共用同一套配置文件、日志、状态文件，两个脚本任选其一即可。
    本文件自带完整引擎（联网探测 / 选网卡 / 解析门户参数 / 认证），打包成 exe 后可独立运行。

.PARAMETER Tray
    启动后不显示主窗口，直接缩到托盘后台运行（开机自启用的就是这个模式）。

.PARAMETER Library
    只加载函数、不弹窗口（开发/测试用）。

.EXAMPLE
    .\campus-autologin-gui.ps1
    .\campus-autologin-gui.ps1 -Tray
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = '',
    [string]$LogFile    = '',
    [string]$StateFile  = '',
    [switch]$Tray,
    [switch]$Library
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-SelfPath {
    try {
        $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($exe -and $exe -match '\.exe$' -and $exe -notmatch 'powershell\.exe$|pwsh\.exe$') { return $exe }
    } catch { }
    if ($PSCommandPath) { return $PSCommandPath }
    return $MyInvocation.MyCommand.Path
}

$SelfPath   = Get-SelfPath
$ScriptRoot = if ($SelfPath) { Split-Path -Parent $SelfPath } else { (Get-Location).Path }
if (-not $ConfigFile) { $ConfigFile = Join-Path $ScriptRoot 'campus-autologin.config.json' }
if (-not $LogFile)    { $LogFile    = Join-Path $ScriptRoot 'campus-autologin.log' }
if (-not $StateFile)  { $StateFile  = Join-Path $ScriptRoot 'campus-autologin.state.json' }

$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) '校园网自动登录(GUI).lnk'

# =====================================================================
#  引擎：与 campus-autologin.ps1 保持一致
#  同一份定义同时用于本进程（按钮操作）和后台线程（断网自动重连）
# =====================================================================
$script:EngineParam = 'param([string]$ConfigFile, [string]$LogFile, [string]$StateFile)'
$script:EngineDefs = {
    $DefaultConfig = [ordered]@{
        portalHost           = 'http://10.0.0.1'
        userId               = ''
        password             = ''
        passwordEncrypted    = ''
        passwordProtection   = 'dpapi'
        ispSuffix            = ''
        portalType           = '0'
        ssidPattern          = '校园|CMCC|WiFi'
        wlanacname           = ''
        vlan                 = ''
        watchIntervalSeconds = 15
        offlineConfirmCount  = 2
        showNotifications    = $true
        probeUrls            = @('http://connect.rom.miui.com/generate_204', 'http://www.gstatic.com/generate_204')
    }

    function Write-Log([string]$Message) {
        $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    }

    function Protect-String([string]$plain) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
        $enc   = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Convert]::ToBase64String($enc)
    }

    function Unprotect-String([string]$cipher) {
        $bytes = [Convert]::FromBase64String($cipher)
        $dec   = [Security.Cryptography.ProtectedData]::Unprotect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($dec)
    }
    function Get-Settings {
        $cfg = [ordered]@{}
        foreach ($defaultKey in @($DefaultConfig.Keys)) { $cfg[$defaultKey] = $DefaultConfig[$defaultKey] }
        if (Test-Path -LiteralPath $ConfigFile) {
            try {
                $file = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($key in @($cfg.Keys)) {
                    $value = $file.$key
                    if ($null -ne $value -and "$value" -ne '') { $cfg[$key] = $value }
                }
            } catch {
                Write-Log ("配置文件解析失败，使用默认值: {0}" -f $_.Exception.Message)
            }
        }
        if (-not $cfg.retryTimes) { $cfg.retryTimes = 3 }

        $cfg.portalHost = ([string]$cfg.portalHost).TrimEnd('/')
        $cfg.userId     = ([string]$cfg.userId) -replace '@.*$', ''
        if ($cfg.ispSuffix -and $cfg.userId -notmatch '@') { $cfg.userId = "$($cfg.userId)$($cfg.ispSuffix)" }

        if ($cfg.passwordEncrypted) {
            try { $cfg.password = Unprotect-String ([string]$cfg.passwordEncrypted) }
            catch { Write-Log ('密码解密失败（DPAPI 绑定当前用户/本机），请重新保存配置。原因: {0}' -f $_.Exception.Message) }
        }
        if ($cfg.probeUrls -is [string]) { $cfg.probeUrls = @($cfg.probeUrls) }
        return $cfg
    }

    function Save-Config($cfg) {
        $out = [ordered]@{
            portalHost           = $cfg.portalHost
            userId               = $cfg.userId
            password             = ''
            passwordEncrypted    = $cfg.passwordEncrypted
            passwordProtection   = 'dpapi'
            ispSuffix            = $cfg.ispSuffix
            portalType           = $cfg.portalType
            ssidPattern          = $cfg.ssidPattern
            wlanacname           = $cfg.wlanacname
            vlan                 = $cfg.vlan
            watchIntervalSeconds = $cfg.watchIntervalSeconds
            offlineConfirmCount  = $cfg.offlineConfirmCount
            showNotifications    = $cfg.showNotifications
            probeUrls            = @($cfg.probeUrls)
        }
        [IO.File]::WriteAllText($ConfigFile, ($out | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
    }

    function Save-State($net) {
        try {
            $obj = [ordered]@{ wlanacname = $net.AcName; vlan = $net.Vlan; ip = $net.IP; mac = $net.Mac; savedAt = (Get-Date).ToString('s') }
            [IO.File]::WriteAllText($StateFile, ($obj | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
        } catch { }
    }

    function Get-CachedState {
        if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
        try {
            $s = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            return [ordered]@{ AcName = [string]$s.wlanacname; Vlan = [string]$s.vlan }
        } catch { return $null }
    }

    function Test-Online($cfg) {
        foreach ($probe in @($cfg.probeUrls)) {
            try {
                $r = Invoke-WebRequest -Uri $probe -TimeoutSec 5 -UseBasicParsing
                if ($r.StatusCode -eq 204) { return $true }
                if ($r.StatusCode -eq 200) {
                    $body = ''
                    try { $body = [string]$r.Content } catch { $body = '' }
                    if ($body -and ($body -notmatch '<html')) { return $true }
                }
            } catch { }
        }
        return $false
    }

    function Get-Ssid {
        try {
            $out = (netsh wlan show interfaces) | Out-String
            $m = [regex]::Match($out, '(?m)^\s*SSID\s*:\s*(.+?)\s*$')
            if ($m.Success) { return $m.Groups[1].Value.Trim() }
        } catch { }
        return ''
    }

    function Get-CampusAdapter($ssidPattern) {
        $ssid = Get-Ssid
        $adapters = @()
        foreach ($item in (Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
            if (-not $item.IPv4Address) { continue }
            if ($item.NetAdapter.Status -ne 'Up') { continue }
            if ($item.InterfaceAlias -match 'Loopback') { continue }
            if ($item.InterfaceDescription -match 'Radmin|VPN|TAP|Virtual|WireGuard|Bluetooth|Hyper-V|WAN Miniport') { continue }
            $adapters += [pscustomobject]@{
                Alias   = [string]$item.InterfaceAlias
                Index   = [int]$item.InterfaceIndex
                IP      = [string]$item.IPv4Address.IPAddress
                Gateway = [string]$item.IPv4DefaultGateway.NextHop
            }
        }
        if (-not $adapters) { return $null }

        if ($ssid -and $ssidPattern -and ($ssid -match $ssidPattern)) {
            $hit = $adapters | Where-Object { $_.Alias -match 'WLAN|Wi-?Fi|无线|Wi-Fi' } | Select-Object -First 1
            if ($hit) { return [pscustomobject]@{ Adapter = $hit; Ssid = $ssid; MatchedBy = 'SSID' } }
        }
        $routes = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric
        foreach ($route in $routes) {
            $hit = $adapters | Where-Object { $_.Index -eq $route.InterfaceIndex } | Select-Object -First 1
            if ($hit) { return [pscustomobject]@{ Adapter = $hit; Ssid = $ssid; MatchedBy = '默认路由' } }
        }
        return [pscustomobject]@{ Adapter = $adapters[0]; Ssid = $ssid; MatchedBy = '仅存网卡' }
    }

    function Get-MacOf([int]$index) {
        $a = Get-NetAdapter -InterfaceIndex $index -ErrorAction SilentlyContinue
        if (-not $a) { return '' }
        return ([string]$a.MacAddress).Replace('-', ':')
    }

    function Get-PortalUrlFromRedirect {
        $probes = @('http://connect.rom.miui.com/generate_204', 'http://www.gstatic.com/generate_204',
                    'http://www.baidu.com/', 'http://neverssl.com/', 'http://223.5.5.5/')
        foreach ($probe in $probes) {
            try {
                $req = [Net.HttpWebRequest]::Create($probe)
                $req.AllowAutoRedirect = $false
                $req.Timeout = 6000
                $req.UserAgent = 'Mozilla/5.0'
                $req.Proxy = $null
                $resp = $req.GetResponse()
                $loc = [string]$resp.Headers['Location']
                $body = ''
                if (-not ($loc -match 'wlanuserip=')) {
                    try {
                        $reader = New-Object IO.StreamReader($resp.GetResponseStream())
                        $body = $reader.ReadToEnd()
                        $reader.Close()
                    } catch { }
                }
                $resp.Close()
                $cand = $loc
                if (-not ($cand -match 'wlanuserip=')) {
                    $m = [regex]::Match($body, 'http://\d{1,3}(\.\d{1,3}){3}[^"''<>\s]*wlanuserip=[^"''<>\s]*')
                    if ($m.Success) { $cand = $m.Value }
                }
                if ($cand -match 'wlanuserip=') { return $cand }
            } catch { }
        }
        return $null
    }

    function ConvertFrom-PortalUrl([string]$url) {
        $h = @{}
        foreach ($m in [regex]::Matches($url, '[?&]([A-Za-z0-9_]+)=([^&]*)')) {
            $h[$m.Groups[1].Value] = [uri]::UnescapeDataString($m.Groups[2].Value)
        }
        return $h
    }

    function Resolve-PortalParams($cfg) {
        $url = Get-PortalUrlFromRedirect
        if ($url) {
            $h = ConvertFrom-PortalUrl $url
            if ($h['wlanuserip'] -and $h['wlanacname']) {
                return [ordered]@{ IP = $h['wlanuserip']; Mac = $h['mac']; AcName = $h['wlanacname']; Vlan = $h['vlan']; Source = '门户重定向' }
            }
        }
        $picked = Get-CampusAdapter $cfg.ssidPattern
        if (-not $picked) { return $null }
        $cached = Get-CachedState
        return [ordered]@{
            IP     = $picked.Adapter.IP
            Mac    = Get-MacOf $picked.Adapter.Index
            AcName = $(if ($cfg.wlanacname) { $cfg.wlanacname } elseif ($cached) { $cached.AcName } else { '' })
            Vlan   = $(if ($cfg.vlan) { $cfg.vlan } elseif ($cached) { $cached.Vlan } else { '' })
            Source = ('本机网卡({0}/{1})' -f $picked.Adapter.Alias, $picked.MatchedBy)
        }
    }

    function Invoke-PortalLogin($cfg, $net) {
        $parts = @(
            ('userid='     + [uri]::EscapeDataString($cfg.userId)),
            ('passwd='     + [uri]::EscapeDataString($cfg.password)),
            ('wlanuserip=' + $net.IP),
            ('wlanacname=' + $net.AcName),
            ('vlan='       + $net.Vlan),
            ('mac='        + $net.Mac),
            ('portaltype=' + $cfg.portalType)
        )
        $query = $parts -join [char]38
        $url = '{0}/quickauth.do?{1}' -f $cfg.portalHost.TrimEnd('/'), $query
        $r = Invoke-WebRequest -Uri $url -TimeoutSec 12 -UseBasicParsing
        $json = $r.Content | ConvertFrom-Json
        return @{ Code = [string]$json.code; Message = [string]$json.message; UserId = [string]$json.userId }
    }

    function Try-Login($cfg) {
        if (-not $cfg.userId -or -not $cfg.password) {
            Write-Log '配置缺少账号或密码，请先填写并保存。'
            return $false
        }
        for ($attempt = 1; $attempt -le [int]$cfg.retryTimes; $attempt++) {
            $net = Resolve-PortalParams $cfg
            if (-not $net) { Write-Log '未找到可用网卡，无法认证。'; return $false }
            if (-not $net.AcName) {
                Write-Log ('未取到门户参数（wlanacname 为空），5 秒后重试；当前来源: {0}' -f $net.Source)
                Start-Sleep -Seconds 5
                continue
            }
            Write-Log ('尝试登录({0}/{1}) 账号={2} IP={3} AC={4} VLAN={5} MAC={6} 来源={7}' -f $attempt, $cfg.retryTimes, $net.IP, $net.AcName, $net.Vlan, $net.Mac, $net.Source)
            try {
                $result = Invoke-PortalLogin $cfg $net
            } catch {
                Write-Log ('请求异常: {0}' -f $_.Exception.Message)
                Start-Sleep -Seconds 3
                continue
            }
            if ($result.Code -eq '0') { Write-Log ('登录成功 ({0})' -f $result.Message); Save-State $net; return $true }
            Write-Log ('登录失败: code={0} message={1}' -f $result.Code, $result.Message)
            Start-Sleep -Seconds 3
        }
        return $false
    }

    function Show-Status($cfg) {
        Write-Log ('门户地址: {0}' -f $cfg.portalHost)
        Write-Log ('登录账号: {0}' -f $cfg.userId)
        Write-Log ('密码来源: {0}' -f $(if ($cfg.passwordEncrypted) { 'DPAPI 加密存储' } elseif ($cfg.password) { '明文配置' } else { '未配置' }))
        Write-Log ('当前网络: {0}' -f $(if (Test-Online $cfg) { '已联网' } else { '未联网（需要认证）' }))
        $picked = Get-CampusAdapter $cfg.ssidPattern
        if ($picked) { Write-Log ('选用网卡: {0}  IP={1}  GW={2}  匹配方式={3}' -f $picked.Adapter.Alias, $picked.Adapter.IP, $picked.Adapter.Gateway, $picked.MatchedBy) }
        else { Write-Log '选用网卡: 未找到可用网卡' }
        $net = Resolve-PortalParams $cfg
        if ($net) { Write-Log ('认证参数: IP={0} AC={1} VLAN={2} MAC={3} 来源={4}' -f $net.IP, $net.AcName, $net.Vlan, $net.Mac, $net.Source) }
        else { Write-Log '认证参数: 无法确定' }
    }

    function Start-WatchLoop {
        Write-Log '后台监听已启动，断网后会自动重连。'
        $fail = 0
        while ($true) {
            $cfg = Get-Settings
            if (Test-Online $cfg) {
                if ($fail -gt 0) { Write-Log '网络已恢复。' }
                $fail = 0
            } else {
                $fail++
                if ($fail -eq 1) { Write-Log '疑似断网，下次检测二次确认...' }
                if ($fail -ge [int]$cfg.offlineConfirmCount) {
                    if ($fail -eq [int]$cfg.offlineConfirmCount) { Write-Log '确认断网，开始自动认证...' }
                    if ((Try-Login $cfg) -and (Test-Online $cfg)) { Write-Log '重连成功。'; $fail = 0 }
                }
            }
            Start-Sleep -Seconds ([int]$cfg.watchIntervalSeconds)
        }
    }
}
. $script:EngineDefs
# =====================================================================
#  图形界面
# =====================================================================
$script:Operators = [ordered]@{
    '校园网(本地)'       = ''
    '中国移动(@cmcc)'    = '@cmcc'
    '中国联通(@unicom)'  = '@unicom'
    '中国电信(@telecom)' = '@telecom'
}
$script:UiLogMax      = 400
$script:LogShown      = 0
$script:NotifyEnabled = $true
$script:ReallyExit    = $false
$script:LoadingConfig = $false
$script:Task          = $null
$script:Watcher       = $null
$script:TrayIcon      = $null

function Normalize-Portal([string]$value) {
    $v = ([string]$value).Trim()
    if (-not $v) { return '' }
    if ($v -notmatch '^https?://') { $v = 'http://' + $v }
    $v = $v.TrimEnd('/')
    try {
        $u = [uri]$v
        if ($u.Host) { return ('{0}://{1}' -f $u.Scheme, $u.Authority) }
    } catch { }
    return $v
}

function Add-UiLog([string]$line) {
    if (-not $script:LogBox) { return }
    $line = $line -replace '^\[\d{4}-\d{2}-\d{2} ', '['
    $box = $script:LogBox
    $box.Text = $box.Text + $line + [Environment]::NewLine
    $lines = @($box.Text -split "`r?`n")
    if ($lines.Count -gt $script:UiLogMax) {
        $box.Text = (($lines[($lines.Count - $script:UiLogMax)..($lines.Count - 1)]) -join [Environment]::NewLine) + [Environment]::NewLine
    }
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
    Update-StatusFromLine $line
}

function Update-StatusFromLine([string]$line) {
    if ($script:StatusLabel) {
        if ($line -match '重连成功|登录成功|网络已恢复') {
            $script:StatusLabel.Text = '状态: 已联网'
            $script:StatusLabel.ForeColor = [Drawing.Color]::ForestGreen
        } elseif ($line -match '确认断网') {
            $script:StatusLabel.Text = '状态: 已断网，正在自动认证…'
            $script:StatusLabel.ForeColor = [Drawing.Color]::Firebrick
        } elseif ($line -match '疑似断网') {
            $script:StatusLabel.Text = '状态: 网络不稳定…'
            $script:StatusLabel.ForeColor = [Drawing.Color]::DarkOrange
        } elseif ($line -match '未联网（需要认证）') {
            $script:StatusLabel.Text = '状态: 未联网（需要认证）'
            $script:StatusLabel.ForeColor = [Drawing.Color]::Firebrick
        } elseif ($line -match '当前网络: 已联网') {
            $script:StatusLabel.Text = '状态: 已联网'
            $script:StatusLabel.ForeColor = [Drawing.Color]::ForestGreen
        }
    }
    if ($script:NotifyEnabled -and $script:TrayIcon -and ($line -match '登录成功|重连成功')) {
        try { $script:TrayIcon.ShowBalloonTip(3000, '校园网自动登录', $line, [Windows.Forms.ToolTipIcon]::Info) } catch { }
    }
}

function Read-NewLogLines {
    if (-not (Test-Path -LiteralPath $LogFile)) { return }
    try { $all = @(Get-Content -LiteralPath $LogFile -Encoding UTF8 -ErrorAction Stop) } catch { return }
    if ($all.Count -lt $script:LogShown) { $script:LogShown = 0 }
    if ($all.Count -le $script:LogShown) { return }
    $new = @($all[$script:LogShown..($all.Count - 1)])
    $script:LogShown = $all.Count
    foreach ($line in $new) { if (([string]$line).Trim()) { Add-UiLog ([string]$line) } }
}

function Start-Engine([string]$Command) {
    $text = $script:EngineParam + "`n" + $script:EngineDefs.ToString() + "`n" + $Command
    $ps = [PowerShell]::Create()
    $rs = [RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [Threading.ApartmentState]::MTA
    $rs.Open()
    $ps.Runspace = $rs
    [void]$ps.AddScript($text).AddArgument($ConfigFile).AddArgument($LogFile).AddArgument($StateFile)
    $handle = $ps.BeginInvoke()
    return @{ Ps = $ps; Handle = $handle; Label = '' }
}

function Start-EngineTask([string]$Command, [string]$Label) {
    if ($script:Task -and -not $script:Task.Handle.IsCompleted) { Add-UiLog '上一个操作还在进行，请稍候…'; return }
    $script:Task = Start-Engine $Command
    $script:Task.Label = $Label
    $script:BtnLogin.Enabled = $false
    $script:BtnStatus.Enabled = $false
    $script:BtnForce.Enabled = $false
    Add-UiLog ('开始: ' + $Label)
}

function Start-Watcher {
    if ($script:Watcher -and -not $script:Watcher.Handle.IsCompleted) { return }
    $script:Watcher = Start-Engine 'Start-WatchLoop'
}

function Stop-Engine {
    foreach ($t in @($script:Task, $script:Watcher)) {
        if ($t) {
            try { $t.Ps.Stop() } catch { }
            try { $t.Ps.Runspace.Dispose() } catch { }
            try { $t.Ps.Dispose() } catch { }
        }
    }
    $script:Task = $null
    $script:Watcher = $null
}

function Update-Ui {
    if ($script:ShowEvent) { try { if ($script:ShowEvent.WaitOne(0)) { Show-MainWindow } } catch { } }
    Read-NewLogLines
    if ($script:Task -and $script:Task.Handle.IsCompleted) {
        $label = [string]$script:Task.Label
        try { [void]$script:Task.Ps.EndInvoke($script:Task.Handle) } catch { Add-UiLog ('操作异常: ' + $_.Exception.Message) }
        try { $script:Task.Ps.Runspace.Dispose(); $script:Task.Ps.Dispose() } catch { }
        $script:Task = $null
        $script:BtnLogin.Enabled = $true
        $script:BtnStatus.Enabled = $true
        $script:BtnForce.Enabled = $true
        Add-UiLog ('完成: ' + $label)
    }
    if ($script:Watcher -and $script:Watcher.Handle.IsCompleted) {
        try { [void]$script:Watcher.Ps.EndInvoke($script:Watcher.Handle) } catch { Add-UiLog ('后台监听异常: ' + $_.Exception.Message) }
        try { $script:Watcher.Ps.Runspace.Dispose(); $script:Watcher.Ps.Dispose() } catch { }
        $script:Watcher = $null
        Add-UiLog '后台监听已退出，正在重启…'
        Start-Watcher
    }
}

function Get-StartupTarget {
    if ($SelfPath -and $SelfPath -match '\.exe$' -and $SelfPath -notmatch 'powershell\.exe$|pwsh\.exe$') {
        return @{ Exe = $SelfPath; Args = '-Tray' }
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return @{ Exe = $psExe; Args = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Tray' -f $SelfPath) }
}

function Add-AutoStart {
    $t = Get-StartupTarget
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($StartupLnk)
    $sc.TargetPath = $t.Exe
    $sc.Arguments = $t.Args
    $sc.WorkingDirectory = $ScriptRoot
    $sc.WindowStyle = 7
    $sc.Description = '校园网自动登录（开机后缩到托盘后台重连）'
    $sc.Save()
}

function Remove-AutoStart {
    if (Test-Path -LiteralPath $StartupLnk) { Remove-Item -LiteralPath $StartupLnk -Force }
}

function Save-UiConfig {
    $cfg = Get-Settings
    $portal = Normalize-Portal $script:TxtPortal.Text
    if (-not $portal) { throw '请填写认证地址（例如 http://10.0.0.1）。' }
    $uid = ([string]$script:TxtUser.Text).Trim() -replace '@.*$', ''
    if (-not $uid) { throw '请填写账号。' }
    $plain = [string]$script:TxtPass.Text
    if (-not $plain -and -not $cfg.passwordEncrypted) { throw '请填写密码。' }

    $cfg.portalHost           = $portal
    $cfg.userId               = $uid
    $cfg.ispSuffix            = [string]$script:Operators[$script:CmbIsp.Text]
    $cfg.watchIntervalSeconds = [int]$script:NumInterval.Value
    $cfg.showNotifications    = [bool]$script:ChkNotify.Checked
    if ($plain) { $cfg.passwordEncrypted = Protect-String $plain; $cfg.password = $plain }

    Save-Config $cfg
    Write-Log ('配置已保存: {0}' -f $ConfigFile)
    return $cfg
}

function Load-ConfigIntoUi {
    $cfg = Get-Settings
    $script:TxtPortal.Text = [string]$cfg.portalHost
    $script:TxtUser.Text   = ([string]$cfg.userId) -replace '@.*$', ''
    if ($cfg.password) { $script:TxtPass.Text = [string]$cfg.password }
    $idx = 0
    $i = 0
    foreach ($k in @($script:Operators.Keys)) {
        if ([string]$script:Operators[$k] -eq [string]$cfg.ispSuffix) { $idx = $i }
        $i++
    }
    $script:CmbIsp.SelectedIndex = $idx
    $v = [int]$cfg.watchIntervalSeconds
    if ($v -lt 5) { $v = 5 }
    if ($v -gt 600) { $v = 600 }
    $script:NumInterval.Value = $v
    $script:NotifyEnabled = [bool]$cfg.showNotifications
    $script:ChkNotify.Checked = [bool]$cfg.showNotifications
    $script:ChkAuto.Checked = (Test-Path -LiteralPath $StartupLnk)
}

function Get-AppIcon {
    $icon = $null
    try { $icon = [Drawing.Icon]::ExtractAssociatedIcon([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { }
    if (-not $icon) { $icon = [Drawing.SystemIcons]::Application }
    return $icon
}

function Build-MainWindow {    $form = New-Object Windows.Forms.Form
    $form.Text = '校园网自动登录 (Dr.COM 版)'
    $form.ClientSize = New-Object Drawing.Size(468, 596)
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $true
    $form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)
    $form.Icon = Get-AppIcon
    $script:Form = $form

    $title = New-Object Windows.Forms.Label
    $title.Text = '校园网自动登录'
    $title.Font = New-Object Drawing.Font('Microsoft YaHei UI', 15, [Drawing.FontStyle]::Bold)
    $title.TextAlign = 'MiddleCenter'
    $title.SetBounds(16, 12, 436, 34)

    $sub = New-Object Windows.Forms.Label
    $sub.Text = 'Dr.COM 城市热点认证 · 断网自动重连'
    $sub.ForeColor = [Drawing.Color]::Gray
    $sub.TextAlign = 'MiddleCenter'
    $sub.SetBounds(16, 46, 436, 20)

    $rows = @(
        @{ Caption = '认证地址:'; Y = 80 },
        @{ Caption = '账    号:'; Y = 114 },
        @{ Caption = '密    码:'; Y = 148 },
        @{ Caption = '运 营 商:'; Y = 182 },
        @{ Caption = '检测间隔:'; Y = 216 }
    )
    foreach ($row in $rows) {
        $l = New-Object Windows.Forms.Label
        $l.Text = $row.Caption
        $l.TextAlign = 'MiddleRight'
        $l.SetBounds(12, $row.Y, 74, 24)
        $form.Controls.Add($l)
    }

    $script:TxtPortal = New-Object Windows.Forms.TextBox
    $script:TxtPortal.SetBounds(92, 80, 356, 24)

    $script:TxtUser = New-Object Windows.Forms.TextBox
    $script:TxtUser.SetBounds(92, 114, 356, 24)

    $script:TxtPass = New-Object Windows.Forms.TextBox
    $script:TxtPass.UseSystemPasswordChar = $true
    $script:TxtPass.SetBounds(92, 148, 356, 24)

    $script:CmbIsp = New-Object Windows.Forms.ComboBox
    $script:CmbIsp.DropDownStyle = 'DropDownList'
    [void]$script:CmbIsp.Items.AddRange(@($script:Operators.Keys))
    $script:CmbIsp.SetBounds(92, 182, 356, 24)

    $script:NumInterval = New-Object Windows.Forms.NumericUpDown
    $script:NumInterval.Minimum = 5
    $script:NumInterval.Maximum = 600
    $script:NumInterval.SetBounds(92, 216, 70, 24)

    $unit = New-Object Windows.Forms.Label
    $unit.Text = '秒（断网检测间隔）'
    $unit.ForeColor = [Drawing.Color]::Gray
    $unit.TextAlign = 'MiddleLeft'
    $unit.SetBounds(168, 216, 200, 24)

    $script:ChkAuto = New-Object Windows.Forms.CheckBox
    $script:ChkAuto.Text = '开机自动登录'
    $script:ChkAuto.SetBounds(92, 250, 130, 24)

    $script:ChkNotify = New-Object Windows.Forms.CheckBox
    $script:ChkNotify.Text = '显示登录通知'
    $script:ChkNotify.SetBounds(236, 250, 140, 24)

    $script:BtnLogin = New-Object Windows.Forms.Button
    $script:BtnLogin.Text = '保存并登录'
    $script:BtnLogin.SetBounds(92, 284, 104, 30)

    $script:BtnSave = New-Object Windows.Forms.Button
    $script:BtnSave.Text = '仅保存'
    $script:BtnSave.SetBounds(202, 284, 76, 30)

    $script:BtnStatus = New-Object Windows.Forms.Button
    $script:BtnStatus.Text = '检查状态'
    $script:BtnStatus.SetBounds(284, 284, 84, 30)

    $script:BtnForce = New-Object Windows.Forms.Button
    $script:BtnForce.Text = '立即重连'
    $script:BtnForce.SetBounds(374, 284, 74, 30)

    $script:StatusLabel = New-Object Windows.Forms.Label
    $script:StatusLabel.Text = '状态: 启动中…'
    $script:StatusLabel.SetBounds(92, 322, 356, 22)

    $logCaption = New-Object Windows.Forms.Label
    $logCaption.Text = '运行日志'
    $logCaption.TextAlign = 'MiddleRight'
    $logCaption.SetBounds(12, 352, 74, 20)

    $script:LogBox = New-Object Windows.Forms.TextBox
    $script:LogBox.Multiline = $true
    $script:LogBox.ReadOnly = $true
    $script:LogBox.ScrollBars = 'Vertical'
    $script:LogBox.BackColor = [Drawing.Color]::White
    $script:LogBox.SetBounds(92, 352, 356, 232)

    $form.Controls.AddRange(@($title, $sub, $script:TxtPortal, $script:TxtUser, $script:TxtPass,
        $script:CmbIsp, $script:NumInterval, $unit, $script:ChkAuto, $script:ChkNotify,
        $script:BtnLogin, $script:BtnSave, $script:BtnStatus, $script:BtnForce, $script:StatusLabel,
        $logCaption, $script:LogBox))

    $script:BtnLogin.add_Click({
        try { Save-UiConfig | Out-Null; Start-EngineTask 'Try-Login (Get-Settings) | Out-Null' '登录' }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '校园网自动登录', 'OK', 'Warning') | Out-Null }
    })
    $script:BtnSave.add_Click({
        try { Save-UiConfig | Out-Null; Add-UiLog '已保存配置（未发起登录）。' }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, '校园网自动登录', 'OK', 'Warning') | Out-Null }
    })
    $script:BtnStatus.add_Click({ Start-EngineTask 'Show-Status (Get-Settings)' '检查状态' })
    $script:BtnForce.add_Click({ Start-EngineTask 'Try-Login (Get-Settings) | Out-Null' '强制认证' })

    $script:ChkNotify.add_CheckedChanged({
        if ($script:LoadingConfig) { return }
        $script:NotifyEnabled = [bool]$script:ChkNotify.Checked
        try { Save-UiConfig | Out-Null } catch { }
    })
    $script:ChkAuto.add_CheckedChanged({
        if ($script:LoadingConfig) { return }
        try {
            if ($script:ChkAuto.Checked) {
                Add-AutoStart
                Write-Log '已设置开机自动登录（开机后自动缩到托盘后台重连）。'
            } else {
                Remove-AutoStart
                Write-Log '已取消开机自动登录。'
            }
        } catch {
            [Windows.Forms.MessageBox]::Show($_.Exception.Message, '校园网自动登录', 'OK', 'Warning') | Out-Null
        }
    })

    $form.add_FormClosing({
        param($sender, $e)
        if ($script:TrayEnabled -and -not $script:ReallyExit) {
            $e.Cancel = $true
            $script:Form.Hide()
            $script:Form.ShowInTaskbar = $false
            if ($script:TrayIcon -and $script:ChkNotify.Checked) {
                try { $script:TrayIcon.ShowBalloonTip(2500, '校园网自动登录', '已缩到托盘，仍在后台自动重连。右键托盘图标可退出。', [Windows.Forms.ToolTipIcon]::Info) } catch { }
            }
        }
    })
    $form.add_FormClosed({
        try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
    })
    return $form
}

function Enable-Tray {
    $icon = Get-AppIcon

    $script:TrayIcon = New-Object Windows.Forms.NotifyIcon
    $script:TrayIcon.Icon = $icon
    $script:TrayIcon.Text = '校园网自动登录'
    $script:TrayIcon.Visible = $true

    $menu = New-Object Windows.Forms.ContextMenuStrip
    $miOpen = $menu.Items.Add('打开主界面')
    $miOpen.add_Click({ Show-MainWindow })
    $miLogin = $menu.Items.Add('立即重连')
    $miLogin.add_Click({ Start-EngineTask 'Try-Login (Get-Settings) | Out-Null' '强制认证' })
    [void]$menu.Items.Add('-')
    $miExit = $menu.Items.Add('退出')
    $miExit.add_Click({ Exit-App })
    $script:TrayIcon.ContextMenuStrip = $menu
    $script:TrayIcon.add_DoubleClick({ Show-MainWindow })
}

function Show-MainWindow {
    $script:Form.Show()
    $script:Form.ShowInTaskbar = $true
    $script:Form.WindowState = 'Normal'
    $script:Form.Activate()
}

function Exit-App {
    $script:ReallyExit = $true
    try { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() } catch { }
    Stop-Engine
    $script:Form.Close()
}

function Start-Gui {
    $script:SingleMutex = New-Object Threading.Mutex($false, 'Local\CampusAutologinGui')
    if (-not $script:SingleMutex.WaitOne(0)) {
        try {
            $evt = [Threading.EventWaitHandle]::OpenExisting('Local\CampusAutologinGuiShow')
            [void]$evt.Set()
            $evt.Dispose()
        } catch { }
        return
    }

    [Windows.Forms.Application]::EnableVisualStyles()
    [Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
    $script:TrayEnabled = $true

    Build-MainWindow | Out-Null
    $script:LoadingConfig = $true
    Load-ConfigIntoUi
    $script:LoadingConfig = $false
    Enable-Tray

    if ($Tray) {
        $script:Form.WindowState = 'Minimized'
        $script:Form.ShowInTaskbar = $false
        $script:Form.add_Load({ $script:Form.Hide() })
    }

    if (Test-Path -LiteralPath $LogFile) {
        try {
            $count = @(Get-Content -LiteralPath $LogFile -Encoding UTF8).Count
            $script:LogShown = [Math]::Max(0, $count - 20)
        } catch { $script:LogShown = 0 }
    }
    Read-NewLogLines

    Start-Watcher

    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.add_Tick({ Update-Ui })
    try { $script:ShowEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\CampusAutologinGuiShow') } catch { $script:ShowEvent = $null }
    $timer.Start()

    Add-UiLog ('配置文件: ' + $ConfigFile)
    Add-UiLog '就绪：点「保存并登录」立即认证；断网后后台会自动重连。'
    Start-EngineTask 'Show-Status (Get-Settings)' '检查状态'

    [Windows.Forms.Application]::Run($script:Form)
    $timer.Stop()
    Stop-Engine
}

if (-not $Library) { Start-Gui }
