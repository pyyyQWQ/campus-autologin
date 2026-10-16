<#
.SYNOPSIS
    Dr.COM quickauth 门户校园网自动登录 / 断网自动重连。

.DESCRIPTION
    适用于采用 Dr.COM Web 门户（/quickauth.do 接口，authByRas=false，即明文参数）的校园网。
    换 AP 或换校区时可自动从门户重定向中读取 wlanuserip / wlanacname / vlan / mac，无需手工维护。

.EXAMPLE
    .\campus-autologin.ps1 -Setup                      # 首次运行向导，生成配置文件（密码 DPAPI 加密）
    .\campus-autologin.ps1 -Status                     # 查看当前网络状态与将使用的认证参数
    .\campus-autologin.ps1                             # 在线则退出，离线才认证
    .\campus-autologin.ps1 -Watch                      # 常驻监听，断网自动重连
    .\install.ps1                                      # 安装为开机自启（启动文件夹或计划任务）

.NOTES
    仅供个人设备在自有账号上自动化登录；使用前请确认符合所在学校/单位网络管理规定。
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = '',
    [string]$LogFile    = '',
    [string]$StateFile  = '',

    [string]$Portal          = '',
    [string]$UserId          = '',
    [string]$SsidPattern     = '',
    [int]   $IntervalSeconds = 0,
    [int]   $RetryTimes      = 0,

    [switch]$Setup,
    [switch]$Status,
    [switch]$Watch,
    [switch]$DryRun,
    [switch]$ForceLogin,
    [switch]$RegisterTask,
    [switch]$UnregisterTask
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { Add-Type -AssemblyName System.Security -ErrorAction Stop } catch { }

function Get-SelfPath {
    try {
        $proc = [Diagnostics.Process]::GetCurrentProcess()
        $exe = $proc.MainModule.FileName
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

$DefaultConfig = [ordered]@{
    portalHost          = 'http://10.0.0.1'
    userId              = ''
    password            = ''
    passwordEncrypted   = ''
    passwordProtection  = 'dpapi'
    ispSuffix           = ''
    portalType          = '0'
    ssidPattern         = '校园|CMCC|WiFi'
    wlanacname          = ''
    vlan                = ''
    watchIntervalSeconds = 15
    offlineConfirmCount  = 2
    probeUrls           = @('http://connect.rom.miui.com/generate_204', 'http://www.gstatic.com/generate_204')
}

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
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
    if ($Portal)      { $cfg.portalHost = $Portal }
    if ($UserId)      { $cfg.userId = $UserId }
    if ($SsidPattern) { $cfg.ssidPattern = $SsidPattern }
    if ($IntervalSeconds -gt 0) { $cfg.watchIntervalSeconds = $IntervalSeconds }
    if ($RetryTimes -gt 0)      { $cfg.retryTimes = $RetryTimes }
    if (-not $cfg.retryTimes)   { $cfg.retryTimes = 3 }

    $cfg.portalHost = ([string]$cfg.portalHost).TrimEnd('/')
    $cfg.userId     = ([string]$cfg.userId) -replace '@.*$', ''
    if ($cfg.ispSuffix -and $cfg.userId -notmatch '@') { $cfg.userId = "$($cfg.userId)$($cfg.ispSuffix)" }

    if ($cfg.passwordEncrypted) {
        try { $cfg.password = Unprotect-String ([string]$cfg.passwordEncrypted) }
        catch { Write-Log ('密码解密失败（DPAPI 绑定当前用户/本机），请重新运行 -Setup。原因: {0}' -f $_.Exception.Message) }
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
    foreach ($cfg in (Get-NetIPConfiguration -ErrorAction SilentlyContinue)) {
        if (-not $cfg.IPv4Address) { continue }
        if ($cfg.NetAdapter.Status -ne 'Up') { continue }
        if ($cfg.InterfaceAlias -match 'Loopback') { continue }
        if ($cfg.InterfaceDescription -match 'Radmin|VPN|TAP|Virtual|WireGuard|Bluetooth|Hyper-V|WAN Miniport') { continue }
        $adapters += [pscustomobject]@{
            Alias   = [string]$cfg.InterfaceAlias
            Index   = [int]$cfg.InterfaceIndex
            IP      = [string]$cfg.IPv4Address.IPAddress
            Gateway = [string]$cfg.IPv4DefaultGateway.NextHop
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

function Get-CachedState {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    try {
        $s = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        return [ordered]@{ AcName = [string]$s.wlanacname; Vlan = [string]$s.vlan }
    } catch { return $null }
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

    if ($DryRun) {
        Write-Log ('DRYRUN ' + $url.Replace([uri]::EscapeDataString($cfg.password), '****'))
        return @{ Code = 'dryrun'; Message = 'dry-run' }
    }
    $r = Invoke-WebRequest -Uri $url -TimeoutSec 12 -UseBasicParsing
    $json = $r.Content | ConvertFrom-Json
    return @{ Code = [string]$json.code; Message = [string]$json.message; UserId = [string]$json.userId }
}

function Try-Login($cfg) {
    if (-not $cfg.userId -or -not $cfg.password) {
        Write-Log '配置缺少账号或密码，请先运行 -Setup。'
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
        Write-Log ('尝试登录({0}/{1}) 账号={2} IP={3} AC={4} VLAN={5} MAC={6} 来源={7}' -f `
            $attempt, $cfg.retryTimes, $cfg.userId, $net.IP, $net.AcName, $net.Vlan, $net.Mac, $net.Source)
        try {
            $result = Invoke-PortalLogin $cfg $net
        } catch {
            Write-Log ('请求异常: {0}' -f $_.Exception.Message)
            Start-Sleep -Seconds 3
            continue
        }
        if ($DryRun) { return $false }
        if ($result.Code -eq '0') { Write-Log ('登录成功 ({0})' -f $result.Message); Save-State $net; return $true }
        Write-Log ('登录失败: code={0} message={1}' -f $result.Code, $result.Message)
        Start-Sleep -Seconds 3
    }
    return $false
}

function Show-Status($cfg) {
    $picked = Get-CampusAdapter $cfg.ssidPattern
    Write-Host ('门户地址  : {0}' -f $cfg.portalHost)
    Write-Host ('登录账号  : {0}' -f $cfg.userId)
    Write-Host ('密码来源  : {0}' -f ($(if ($cfg.passwordEncrypted) { 'DPAPI 加密存储' } elseif ($cfg.password) { '明文配置' } else { '未配置' })))
    Write-Host ('当前网络  : {0}' -f ($(if (Test-Online $cfg) { '已联网' } else { '未联网（需要认证）' })))
    if ($picked) {
        Write-Host ('选用网卡  : {0}  IP={1}  GW={2}  (匹配方式: {3})' -f $picked.Adapter.Alias, $picked.Adapter.IP, $picked.Adapter.Gateway, $picked.MatchedBy)
        Write-Host ('无线 SSID : {0}' -f $picked.Ssid)
    } else {
        Write-Host '选用网卡  : 未找到可用网卡'
    }
    $net = Resolve-PortalParams $cfg
    if ($net) {
        Write-Host ('认证参数  : IP={0} AC={1} VLAN={2} MAC={3} 来源={4}' -f $net.IP, $net.AcName, $net.Vlan, $net.Mac, $net.Source)
    } else {
        Write-Host '认证参数  : 无法确定'
    }
}

function Invoke-Setup {
    Write-Host '=== 校园网自动登录 配置向导 ==='
    $cfg = Get-Settings
    $portal = Read-Host ("认证门户地址 [{0}]" -f $cfg.portalHost)
    if ($portal) { $cfg.portalHost = $portal.TrimEnd('/') }
    $user = Read-Host ("登录账号 [{0}]" -f $cfg.userId)
    if ($user) { $cfg.userId = $user }
    $pass = Read-Host '密码（输入后回车，明文不回显）' -AsSecureString
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass))
    if ($plain) { $cfg.password = $plain }
    $ssid = Read-Host ("校园网 SSID 匹配（正则）[{0}]" -f $cfg.ssidPattern)
    if ($ssid) { $cfg.ssidPattern = $ssid }
    $itv = Read-Host ("监听间隔秒数 [{0}]" -f $cfg.watchIntervalSeconds)
    if ($itv -match '^\d+$') { $cfg.watchIntervalSeconds = [int]$itv }

    if (-not $cfg.password) { Write-Host '未输入密码，配置未保存。'; return }
    $cfg.passwordEncrypted = Protect-String $cfg.password
    $cfg.password = ''
    Save-Config $cfg
    Write-Host ('配置已保存: {0}' -f $ConfigFile)
    Write-Host '提示：密码使用 Windows DPAPI 加密，只能在本机当前用户下解密；更换机器或用户需重新运行 -Setup。'
}

function Register-AutoTask($cfg) {
    $self = Get-SelfPath
    if ($self -and $self -match '\.ps1$') {
        $exe  = 'powershell.exe'
        $args = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Watch -IntervalSeconds {1}' -f $self, $cfg.watchIntervalSeconds)
    } else {
        $exe  = $self
        $args = ('-Watch -IntervalSeconds {0}' -f $cfg.watchIntervalSeconds)
    }
    $desc = '校园网自动登录：登录时触发，之后每分钟检测一次，断线自动重连。'

    try {
        $action = New-ScheduledTaskAction -Execute $exe -Argument $args -WorkingDirectory $ScriptRoot
        $atLogon = New-ScheduledTaskTrigger -AtLogOn
        $repeat  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
        $atLogon.Repetition = $repeat.Repetition
        $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName '校园网自动登录' -Action $action -Trigger @($atLogon, $repeat) -Settings $taskSettings -Force -Description $desc | Out-Null
        Write-Log '已注册计划任务：登录时触发 + 每分钟检测。'
        return
    } catch {
        Write-Log ('计划任务注册失败（通常需要管理员权限）: {0}' -f $_.Exception.Message)
    }

    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) '校园网自动登录.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = $exe
    $sc.Arguments = $args
    $sc.WorkingDirectory = $ScriptRoot
    $sc.WindowStyle = 7
    $sc.Description = '校园网自动登录 / 断网自动重连（常驻监听）'
    $sc.Save()
    Write-Log ('已注册开机启动快捷方式（无需管理员）: {0}' -f $lnk)
}

function Unregister-AutoTask {
    try {
        if (Get-ScheduledTask -TaskName '校园网自动登录' -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName '校园网自动登录' -Confirm:$false
            Write-Log '已删除计划任务。'
        }
    } catch { }
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) '校园网自动登录.lnk'
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; Write-Log '已删除启动快捷方式。' }
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*campus-autologin.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Log ('已结束监听进程 PID={0}' -f $_.ProcessId) }
}

# ---------------- main ----------------
if ($Setup) { Invoke-Setup; exit 0 }

$cfg = Get-Settings

if ($Status)         { Show-Status $cfg; exit 0 }
if ($UnregisterTask) { Unregister-AutoTask; exit 0 }
if ($RegisterTask)   { Register-AutoTask $cfg; exit 0 }

if ($Watch) {
    Write-Log ('进入监听模式，每 {0} 秒检测一次（Ctrl+C 退出）。' -f $cfg.watchIntervalSeconds)
    $fail = 0
    while ($true) {
        if (Test-Online $cfg) {
            if ($fail -gt 0) { Write-Log '网络已恢复。' }
            $fail = 0
        } else {
            $fail++
            if ($fail -eq 1) { Write-Log '疑似断网，下次检测二次确认...' }
            if ($fail -ge [int]$cfg.offlineConfirmCount) {
                if ($fail -eq [int]$cfg.offlineConfirmCount) { Write-Log '确认断网，开始自动认证...' }
                $ok = Try-Login $cfg
                if ($ok -and (Test-Online $cfg)) { Write-Log '重连成功。'; $fail = 0 }
            }
        }
        Start-Sleep -Seconds $cfg.watchIntervalSeconds
    }
}

if (-not $ForceLogin -and (Test-Online $cfg)) { Write-Log '当前已在线，无需登录。'; exit 0 }
if ($DryRun) { [void](Try-Login $cfg); exit 0 }
if (Try-Login $cfg) { exit 0 }
exit 1
