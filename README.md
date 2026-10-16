# Dr.COM 校园网自动登录 / 断网自动重连

一个 Dr.COM 门户的校园网自动登录工具，两种形态，**共用同一份配置文件**：

- 图形界面版 `campus-autologin-gui.exe`：双击打开窗口，填好账号密码点一下就登录；关掉窗口会缩到托盘，继续后台断网重连
- 命令行版 `campus-autologin.ps1` / `campus-autologin.exe`：无窗口，适合放进计划任务或配合其他脚本

共同特性：

- 无需安装任何依赖（Windows 自带 PowerShell 5.1 即可），无弹窗打扰
- 断网自动重连（默认每 15 秒探测，连续 2 次确认离线才动作，避免抖动误判）
- 自动从门户重定向里读取 `wlanuserip / wlanacname / vlan / mac`，换 AP、换校区免维护
- 多网卡环境下自动挑选校园网卡（会跳过 Radmin VPN 等虚拟网卡）
- 密码可用 Windows DPAPI 加密保存，配置文件里不出现明文
- 开机自启：命令行版优先注册计划任务（无管理员权限时降级为启动文件夹快捷方式）；图形版勾选「开机自动登录」即可

## 适用 / 不适用

**适用**：Dr.COM 的 Web 门户，登录接口是 `/quickauth.do`，且门户返回的配置里 `authByRas=false`（即明文参数认证）。

判断方法：连上校园网后打开门户登录页，查看网页源码，能看到 `InitPortalConfig`、`portalUtil.js`、`/quickauth.do` 这类特征，基本就适用。

**不适用**（需要自行改造）：
- 门户开启了 RSA（`authByRas=true`）——参数需按门户的 `encryptParam` 加密后再提交
- 登录需要图形验证码（`listpasscode`）
- 根本不是 Dr.COM 门户（华为 AC portal、锐捷 ePortal、深澜 Srun 等）

## 快速开始

> 只想用图形界面的话，不用敲下面这些命令，直接双击 `campus-autologin-gui.exe` 填好点「保存并登录」就行（见「图形界面版」）。

```powershell
# 1) 配置向导（会生成 campus-autologin.config.json，密码默认 DPAPI 加密）
powershell -NoProfile -ExecutionPolicy Bypass -File .\campus-autologin.ps1 -Setup

# 2) 安装到 %LOCALAPPDATA%\CampusAutologin 并设置开机自启
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1

# 3) 看当前状态（联网状态 / 选用网卡 / 将使用的认证参数）
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusAutologin\campus-autologin.ps1" -Status
```

也可以不进向导，直接把 `config.example.json` 复制成 `campus-autologin.config.json` 手工填写。

## 图形界面版（不想碰命令行的同学用这个）

![界面](assets/screenshot.png)

双击 `campus-autologin-gui.exe` 就是一个窗口，填好认证地址 / 账号 / 密码，点「保存并登录」即可。

| 操作 | 说明 |
| --- | --- |
| 保存并登录 | 保存配置（密码 DPAPI 加密存储）并立即认证一次 |
| 仅保存 | 只保存配置，不发起登录 |
| 检查状态 | 显示当前是否联网、选用哪块网卡、将要提交的认证参数 |
| 立即重连 | 强制认证一次（用于排错） |
| 开机自动登录 | 勾选后在启动文件夹生成快捷方式，开机自动缩到托盘、静默重连 |
| 显示登录通知 | 登录 / 重连成功时弹托盘气泡提醒 |

关掉窗口**不会退出**程序，而是缩到托盘继续后台重连；要彻底退出请右键托盘图标 → 退出。

## 预编译 exe

`dist/` 目录里的两个 exe 都是用 [ps2exe](https://github.com/MScholtes/PS2EXE)
从对应 `.ps1` 打包出来的**同一个脚本**，逻辑完全一致：

- `campus-autologin-gui.exe` —— 图形界面版（无控制台窗口）
- `campus-autologin.exe` —— 命令行版（保留控制台窗口），参数与脚本版一致：

```powershell
.\campus-autologin.exe -Setup      # 配置向导
.\campus-autologin.exe -Status     # 看状态
.\campus-autologin.exe             # 在线则退出，离线才认证（适合放进计划任务）
.\campus-autologin.exe -Watch      # 常驻监听，断网自动重连
```

- 双击即可运行，不用装任何东西、不用改执行策略（脚本版才需要 `-ExecutionPolicy Bypass`）。
- 想自己重新打包两个 exe：`powershell -NoProfile -ExecutionPolicy Bypass -File .\build-exe.ps1`
  （会从 PSGallery 安装 `ps2exe`，仅当前用户，无需管理员），生成物直接覆盖 `dist/`
- exe **没有代码签名**，SmartScreen / 部分杀软可能提示「未知发布者」甚至误报，这是所有自打包 PowerShell 程序的通病。
  介意的话直接用 `.ps1` 源码，或自行用 `build-exe.ps1` 重新打包一份。

## 怎么找「认证地址」

1. 连上校园网（此时还不能上网），浏览器访问任意 **http** 网站，会被跳转到门户登录页；
   地址栏里形如 `http://10.0.0.1/portal.do?wlanuserip=...&wlanacname=...` → 认证地址就是 `http://10.0.0.1`。
2. 或者在命令行执行 `ipconfig`，看该网卡的「默认网关」，通常就是门户地址。
3. 或直接问同校同学、学校网络中心。

注意：
- 只填主机，**不要带路径**（`/portal.do`）、也不要带端口，脚本会自己拼 `/quickauth.do`。
- 账号一般只填学号/手机号，后缀（如 `@cmcc`、`@telecom`）由门户自动补；确需固定后缀时用 `ispSuffix`。
- 源码里内置的默认门户只是占位示例地址，请改成你自己学校的门户地址：图形版直接改「认证地址」，命令行版在 `-Setup` 里改。

## 配置项（`campus-autologin.config.json`）

| 字段 | 说明 |
| --- | --- |
| `portalHost` | 门户地址，如 `http://10.0.0.1` |
| `userId` | 登录账号 |
| `password` / `passwordEncrypted` | 二选一。后者为 DPAPI 密文（推荐，`-Setup` 自动生成） |
| `ispSuffix` | 可选账号后缀，留空表示不处理 |
| `portalType` | 门户类型参数，默认 `0`，一般不用改 |
| `ssidPattern` | 校园网 SSID 匹配正则，用于挑选网卡，如 `校园\|CMCC\|WiFi` |
| `wlanacname` / `vlan` | 兜底参数；留空即可，脚本会从门户重定向自动获取 |
| `watchIntervalSeconds` | 监听探测间隔，默认 15 秒 |
| `offlineConfirmCount` | 连续失败几次判定离线，默认 2 |
| `showNotifications` | 图形界面版用：登录 / 重连成功时是否弹托盘通知 |
| `probeUrls` | 联网探测地址（返回 204 视为在线） |

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `-Setup` | 配置向导，生成/更新配置文件 |
| `-Status` | 查看状态与将要使用的认证参数 |
| （无参数） | 在线则退出；离线才认证，适合放进计划任务 |
| `-Watch` | 常驻监听，断网自动重连 |
| `-ForceLogin -DryRun` | 只打印将要发送的请求（不回显密码），用于排错 |
| `-RegisterTask` | 注册开机自启（计划任务 → 失败则启动文件夹快捷方式） |
| `-UnregisterTask` | 删除自启项并结束监听进程 |
| 图形版 `-Tray` | `campus-autologin-gui.exe -Tray`：启动后直接缩到托盘（开机自启用的就是它） |

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

## 工作原理

1. 定时请求 `connect.rom.miui.com/generate_204`、`www.gstatic.com/generate_204`，返回 204 视为在线。
2. 探测失败达到 `offlineConfirmCount` 次后判定离线（防抖）。
3. 尝试从门户重定向（HTTP 302 的 `Location` 或页面里的 `...portal.do?wlanuserip=...`）解析
   `wlanuserip / wlanacname / vlan / mac`；解析不到才回退到「本机网卡 + 上次成功参数」。
4. 以 `GET {门户}/quickauth.do?userid=..&passwd=..&wlanuserip=..&wlanacname=..&vlan=..&mac=..&portaltype=..` 认证，
   返回 `{"code":"0"}` 即成功，并把本次 `wlanacname / vlan` 写入状态文件备下次使用。

## 常见问题

- **日志里出现 `<!DOCTYPE html>` / 「未知响应」**：说明请求打到了不存在的接口（多见于那些"老版 Dr.COM 专用工具"）。
  本脚本用的是门户自己的 `/quickauth.do`，两者不是一回事。
- **「缺少 wlanacname，无法认证」**：不在校园网内（或门户不返回重定向参数），先把配置里的 `wlanacname`/`vlan` 填上兜底值。
- **反复重复认证**：把 `offlineConfirmCount` 调大，或把 `probeUrls` 换成更稳的探测地址。
- **脚本无法运行 / 提示执行策略**：加上 `-ExecutionPolicy Bypass`，或先执行 `Set-ExecutionPolicy RemoteSigned -Scope CurrentUser`。
- **换了电脑或换了 Windows 用户后报密码解密失败**：DPAPI 密文与用户绑定，重新跑一次 `-Setup` 即可。

## 安全与免责

- `campus-autologin.config.json`、`*.log`、`*.state.json` 含个人敏感信息，**已在 `.gitignore` 中排除，切勿提交或分享**。
- 密码使用 DPAPI 加密（`-Setup` 默认），只能在本机当前用户下解密；但脚本本身通过 HTTPS 之外的校园内网提交口令，请自行评估风险。
- 本项目仅用于**个人设备在自有账号上的自动化登录**；请先确认符合你所在学校/单位的网络管理规定，因使用产生的任何后果由使用者自负。
- 不提供批量登录、多账号、代他人认证等功能，请勿改造用于此类用途。

## License

MIT
