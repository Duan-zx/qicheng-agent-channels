# 启程 Windows 频道｜快速说明

这是 Windows 10/11 Pro 或 Enterprise 上的实验性 Hyper-V 频道包装。它把已有的查看器、Host CLI 和 MCP 入口安装到当前用户目录，方便在两台已经准备好的 Windows 虚拟机之间切换。它不会安装 Windows、创建或下载镜像、创建虚拟机、开启 Hyper-V、安装微信开发者工具、登录账号或把 guest agent 自动装进虚拟机。

## 依赖与当前边界

- Windows 10/11 Pro 或 Enterprise；已由管理员启用 Hyper-V，`vmms` 服务可用。
- 宿主安装 Python 3.12 或更高版本。Host 与 MCP 使用 Python 标准库的 `AF_HYPERV`，旧版 Python 不支持。
- 系统自带 .NET Framework 4.x；构建包时还需 `csc.exe`，普通安装只运行已构建的 EXE。
- 两台现有 Hyper-V 虚拟机应已完成 Windows 安装、激活、各自的本地用户登录、guest payload 安装和 Host service 注册。客体内需在目标用户的交互桌面运行 agent。三凭据 Broker 模式须按下文使用离线安装器；旧 `Install-GuestPayloadDirect.ps1` 只接受单令牌 payload。
- 查看器的“AI 可用”状态只表示本地接口可配置，不代表实际客户端已加载 MCP，也不代表 Hyper-V 通信、微信开发者工具或 Computer Use 已通过真机验收。

## 双击安装

解压发布包后，双击 **Install-Qicheng-Windows-Channels.cmd**。它会在当前用户范围安装程序、自动定位并核验支持 `AF_HYPERV` 的 Python 3.12+，创建中文快捷方式，并立即打开首次设置向导（已有有效配置时打开工作台）；默认也会在当前用户下次登录时启动工作台。不要求先输入两条 PowerShell 命令。如果依赖缺失，窗口会保留明确错误，不会偷偷下载或修改系统组件。它不会设置 VM 自动登录，也不会注册系统级自启动服务。

需要先审阅或从命令行导入已有配置时，可运行：

```powershell
.\Install-WindowsChannels.ps1
.\Install-WindowsChannels.ps1 -ImportConfigPath 'D:\Private\channels.json'
.\Install-WindowsChannels.ps1 -ImportConfigPath 'D:\Private\channels.json' -Apply
.\Install-WindowsChannels.ps1 -AutoStart Disabled -Apply
```

前两条只显示计划；带 `-Apply` 才执行。安装位置为 `%LOCALAPPDATA%\Programs\QichengWindowsChannels`，用户数据位于 `%LOCALAPPDATA%\Qicheng\WindowsChannels`。导入会解析原配置的相对 token 路径，将每个 token 复制到受当前 Windows 用户保护的 `DataRoot\tokens` 并写入规范化配置，不会把凭据放入程序包或命令输出。已有目标配置默认拒绝覆盖，只有明确审阅后才能加 `-ReplaceConfig`。

默认自启动只创建当前用户 Startup 目录中的“启程 Windows 频道”快捷方式。要关闭它，用同一发布包重新运行 `Install-WindowsChannels.ps1 -AutoStart Disabled -Apply`；卸载也只删除这个本产品命名的快捷方式。

升级前请关闭频道工作台，以及正在使用本频道 MCP 的 AI/Codex 客户端。安装器检测到本产品 Viewer 或 MCP 启动器仍在运行时，会显示“关闭频道客户端后重试”，保持当前版本不变，也不会自动终止 Python、Codex 或其他进程。

## 首次设置

第一次启动且尚无 `channels.json` 时，程序会自动打开中文设置向导。已有频道配置应优先选择“导入已有频道配置”：向导会显示检测到的 `qicheng-win-1..8` VM，并安全复制配置与 token，不重建 VM。

全新电脑可选择 1–8 台工作区、Windows ISO、已存在的 VM 目标目录和 Hyper-V 虚拟交换机。每台 VM 使用 8 GiB 静态内存和最多 80 GiB 动态磁盘；向导会显示总量，并按“VM 总内存 + 至少 8 GiB 主机余量”给出建议。确认后它实际调用 `source\New-ChannelVMs.ps1 -Count N -Apply`。

VM 创建成功只表示生成了关闭状态的 Hyper-V VM。Windows 安装、许可与登录、来宾代理安装及最终 `channels.json` 导入仍需完成；向导把这一阶段记录为“等待 Windows/来宾代理”，不会把数量保存成可用频道。配置完成后，登录自启动及默认双击入口都在后台托盘运行；需要显示管理窗口时，从开始菜单打开“管理 Windows 频道”。单独使用 Windows 版时，`Alt+1` 返回本机、`Alt+2..9` 查看最多 8 个频道。若同机已安装 Lite，`Alt+1/2/3` 归 Lite，Windows 版从 `Alt+4` 起使用剩余的最多 6 个快捷键；Windows 版不再单独注册返回本机的热键。超过 6 个 Windows 频道时启动器会明确报错，需减少数量或显式指定无冲突的快捷键。

## 新电脑首次准备 Windows 工作区

发布包不会假设电脑已有 Windows VM，也不会伪装成 Windows 全自动安装器。源码分发目录 `source` 保留了可审阅、可运行的准备脚本。首次准备顺序如下：

1. 以管理员身份确认 Windows 10/11 Pro 或 Enterprise、Hyper-V、固件虚拟化、`vmms` 和目标 VM 名称：`source\Test-Host.ps1`。
2. 自行取得合法、已校验 SHA-256 的 Windows ISO，并选择现有 Hyper-V virtual switch。先运行 `source\Prepare-Channels.ps1` 或不带 `-Apply` 的 `source\New-ChannelVMs.ps1` 查看计划。
3. 审阅计划后，按 `source\README.md` 的参数运行 `New-ChannelVMs.ps1 -Apply`。它只创建两台 Gen2 VM 与 VHDX，不安装 Windows、不接受许可、不登录账号。
4. 用 VMConnect 完成两台客体各自的 Windows 安装、激活、本地用户和应用准备；保持两台客体身份、磁盘和 token 分离。
5. 运行 `source\Register-HostService.ps1` 注册固定 Hyper-V service。对每台客体分别准备互不相同的 channel、broker、human 三份私有 token，以及已核对的 BIOS UUID；用可信的 Python embeddable 目录和 `source\Build-GuestPayload.ps1 -ChannelTokenFile ... -BrokerTokenFile ... -HumanTokenFile ...` 构建 schema 2 payload。三份 token 及 payload 不随发布包分发。
6. 客体首次登录并建立目标用户配置文件后，关闭该 VM。对每台关闭状态的 VM 使用 `source\Install-GuestPayloadOffline.ps1`：先不带 `-Apply` 查看计划，核对 VM ID、BIOS UUID、唯一 VHDX 与 payload；再明确执行 `-Apply -Confirm:$false`。计划阶段不会挂载 VHDX，**不能验证客体内的用户配置文件**；这一步在执行阶段才检查，若有多个合格配置文件须先确认目标账户并指定 `-GuestProfile`。`MountWorkDirectory` 必须是已存在的非宿主 C: 本地目录。此脚本会离线挂载 VHDX 并安装登录启动快捷方式。旧 `source\Install-GuestPayloadDirect.ps1` 只接受 schema 1 单令牌 payload，其计划任务仅传 channel token，不能用于三凭据 Broker 模式。
7. 启动两台客体并登录目标交互用户，分别核对 VM ID、BIOS UUID、三份 token 的隔离、agent 启动和实际通道，再创建或导入 `channels.json`。宿主配置的 `token_file` 对应 channel token；使用人工门禁时另配 `human_token_file`。broker token 用于 Broker 路由，不能当作 channel 或 human token 复用。
8. 若希望客体重启后无人值守恢复，可对每台专用客体先以 `source\Enable-GuestAutologonDirect.ps1` 查看计划，再用 `-Apply -AcceptSysinternalsEula` 配置可选自动登录。脚本下载并核验微软签名的 Sysinternals Autologon，需提供客体本地管理员的内存凭据；不把工具或密码打入安装包。自动登录会让能接触该虚拟机控制台的人进入该账号，仅用于专用工作区。

当前包没有独立的 token 生成器。以下 PowerShell 5.1 示例在 DELL 的私有本地目录生成两台 VM 各三枚随机 token；先把路径换成实际私有目录，确认该盘未与客体或他人共享。目录及其新建文件只授予当前用户、SYSTEM 和 Administrators 完全控制，不要把此目录放进源码或压缩包。

```powershell
$privateRoot = 'D:\Private\QichengTokens'
New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
$ownerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetOwner($ownerSid)
$acl.SetAccessRuleProtection($true, $false)
foreach ($sidText in @($ownerSid.Value, 'S-1-5-18', 'S-1-5-32-544')) {
    $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    [void]$acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $privateRoot -AclObject $acl
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try {
    foreach ($vm in @('channel-1', 'channel-2')) {
        foreach ($role in @('channel', 'broker', 'human')) {
            $file = Join-Path $privateRoot "$vm.$role.token"
            if (Test-Path -LiteralPath $file) { throw "Token file already exists: $file" }
            $bytes = New-Object byte[] 32
            $rng.GetBytes($bytes)
            [IO.File]::WriteAllText($file, ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant() + [Environment]::NewLine), [Text.Encoding]::ASCII)
        }
    }
} finally { $rng.Dispose() }
```

对两台 VM 分别核对 `Get-VM` 返回的名称、ID、关闭状态和宿主 Hyper-V BIOS UUID；先完成 Windows 首次登录以创建目标用户配置文件。将下列示例中的 VM 名称、ID、BIOS UUID、可信 Python embeddable 目录和非 C: 临时挂载目录换成 DELL 实值。`D:\QichengMount` 必须预先存在且不含待覆盖资料，payload 输出路径必须尚不存在。每台 VM 重复执行，使用各自三份 token；先检查 JSON 计划，再显式执行离线安装。

```powershell
$vmName = 'qicheng-win-1'
$vmId = '<Get-VM 核对后的 VM ID>'
$biosUuid = '<宿主核对后的 BIOS UUID>'
$payload = 'D:\Private\channel-1-payload'
$mountWork = 'D:\QichengMount'
.\source\Build-GuestPayload.ps1 -EmbeddedPythonDirectory 'D:\TrustedPythonEmbed' -OutputDirectory $payload -BIOSUUID $biosUuid -ChannelTokenFile (Join-Path $privateRoot 'channel-1.channel.token') -BrokerTokenFile (Join-Path $privateRoot 'channel-1.broker.token') -HumanTokenFile (Join-Path $privateRoot 'channel-1.human.token')
.\source\Install-GuestPayloadOffline.ps1 -VMName $vmName -ExpectedVMId $vmId -PayloadDirectory $payload -MountWorkDirectory $mountWork
.\source\Install-GuestPayloadOffline.ps1 -VMName $vmName -ExpectedVMId $vmId -PayloadDirectory $payload -MountWorkDirectory $mountWork -Apply -Confirm:$false
```

离线脚本会拒绝多于一个合格用户配置文件；此时核对目标账户后，在计划和执行两条命令中都加 `-GuestProfile '实际用户名'`。`-Apply` 后再启动 VM，并在目标用户的交互桌面检查 agent。配置 `channels.json` 时用对应的 channel/human token 文件、真实 VM ID 和 BIOS UUID；broker token 单独用于 Broker 路由。只有实际通道、人工门禁和 Broker 路由通过后，才把频道视为可用。

详细参数和边界见 `source\Build-GuestPayload.ps1`、`source\Install-GuestPayloadOffline.ps1`、`source\README.md`、`source\guest\README.md` 与 `source\ARCHITECTURE.md`。离线安装器的计划模式不挂载磁盘；`-Apply` 才进行离线写入。安装后仍需真实 Host↔Guest、Broker 门禁与人工接管验收。当前包没有镜像下载器、自动装 Windows 或账号迁移，自动登录是完成准备后的单独可选操作。

## 接入已有 Windows 工作区

已有合格 Windows VM 时不要重新创建。记录每台 VM 的 ID、已核对 BIOS UUID 和准确 VM 名称；每个频道使用不同 token。可直接用安装器的 `-ImportConfigPath`，或安装后从开始菜单选择“导入已有频道配置”。手工创建时，私有文件只放用户数据目录：

```json
{
  "schema_version": 1,
  "projects": {
    "channel-1": {
      "vm_id": "现有虚拟机的 VM ID",
      "bios_uuid": "已核对的客体 BIOS UUID",
      "token_file": "D:\\Private\\QichengTokens\\channel-1.channel.token",
      "human_token_file": "D:\\Private\\QichengTokens\\channel-1.human.token",
      "vm_name": "现有 Hyper-V VM 的准确名称"
    },
    "channel-2": {
      "vm_id": "另一台现有虚拟机的 VM ID",
      "bios_uuid": "另一台客体的 BIOS UUID",
      "token_file": "D:\\Private\\QichengTokens\\channel-2.channel.token",
      "human_token_file": "D:\\Private\\QichengTokens\\channel-2.human.token",
      "vm_name": "另一台 Hyper-V VM 的准确名称"
    }
  }
}
```

保存为 `%LOCALAPPDATA%\Qicheng\WindowsChannels\channels.json`，或用安装器的 `-ImportConfigPath` 导入。示例使用上文 DELL 私有目录的绝对路径；相对 token 路径则相对配置文件解析。`token_file` 与 `human_token_file` 分别对应 guest payload 中该客体的 channel token 与 human token；broker token 单独交给 Broker 路由配置，不写成这两个字段。每个 token 文件只能包含对应的 64 位小写十六进制 token，三种凭据及两台客体之间不能复用值。不要复制另一台宿主的 token、账号或虚拟磁盘。确认每台 VM 的 guest agent 与配置中的 VM ID、BIOS UUID、三份 token 一一对应。

## 启动、诊断与 AI 接入

从桌面或开始菜单打开“启程 Windows 频道”。也可以运行：

```powershell
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Start-WindowsChannels.ps1"
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Diagnose-WindowsChannels.ps1"
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Get-AISetup.ps1"
```

启动器只接受绝对的本地 `--config` 和 `--python` 路径。查看器保留 `viewer\dist` 与 `host` 的相对结构；缺配置时会弹出可操作提示并打开本说明。诊断命令只读取依赖、配置结构、token 文件存在性和 Hyper-V/VM 可见性，不显示 token 内容。

`Get-AISetup.ps1` 为每个 project 输出不依赖客户端 `cwd` 的稳定 MCP 启动命令。以下不带 Broker 参数的添加方式**仅供旧单令牌模式**；三凭据客体不要执行它的 `-Apply`，应直接使用下一段的 Broker 方式，否则直连输入会被客体拒绝。旧模式要显式把某个频道加入本机 Codex CLI，可先查看计划，再执行：

```powershell
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Add-CodexMcp.ps1" -Name 'qicheng-channel-1' -Project 'channel-1'
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Add-CodexMcp.ps1" -Name 'qicheng-channel-1' -Project 'channel-1' -Apply
```

这只修改明确选择的一个 Codex MCP 配置，不自动改其他客户端。`codex mcp add` 成功只表示 CLI 配置已写入；当前任务不会热加载新工具，也不能据此声称原生 MCP 已发现。重启或重新加载客户端后必须实际检查工具，再用合成数据测试 `state`、截图和输入。每个 MCP 进程只绑定一个 project；不要把人工控制切换做成 AI 自动重试。

三凭据 Broker 模式还需另装 Task Lease，并在其私有 `config.json` 为每个频道的 `guest.broker_token_file` 指向该客体 payload 使用的 broker token；本 Windows 包不会安装或配置 Task Lease。Task Lease 安装时生成的 `DataRoot\broker.token` 是 **Broker HTTP API 的 Bearer 凭据**，必须与两台客体的 broker token 都不同。Codex MCP 的 `-BrokerTokenFile` 要填这枚 HTTP Bearer 凭据，两频道共用它；不要填客体 payload 的 broker token。先核对频道映射和实际 loopback 监听地址，再对每个 project 查看计划并显式添加，例如频道 1：

```powershell
$brokerUrl = 'http://127.0.0.1:<已核对端口>'
$addMcp = "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Add-CodexMcp.ps1"
& $addMcp -Name 'qicheng-channel-1-broker' -Project 'channel-1' -BrokerUrl $brokerUrl -BrokerTokenFile "$env:LOCALAPPDATA\Qicheng\TaskLease\broker.token" -BrokerChannelId 'channel-1'
& $addMcp -Name 'qicheng-channel-1-broker' -Project 'channel-1' -BrokerUrl $brokerUrl -BrokerTokenFile "$env:LOCALAPPDATA\Qicheng\TaskLease\broker.token" -BrokerChannelId 'channel-1' -Apply
```

`<已核对端口>` 必须换成 Broker 实际端口；`TaskLease\broker.token` 路径也须与目标机实际安装的数据目录一致。频道 2 的 guest payload 与 Task Lease `config.json` 使用它自己的 guest broker token，Codex MCP 则继续使用同一枚 Broker HTTP Bearer 凭据，并改成对应的 project/channel ID。CLI 配置完成后仍需重载客户端并实测 Broker 的租约门禁及人工接管，不能仅凭配置回执认定门禁生效。

按键输入可用 `Return`、`Enter` 或 `ENTER` 表示回车，客户端会统一转成客体允许的 `Return`；`ctrl+a/c/v/x/z/f/l` 不区分大小写。只支持固定按键白名单，不能发送任意系统快捷键。若微信开发者工具的“安全→服务端口”关闭，CLI 调试仍不可用；启用它是客体内单独的安全设置决定，安装启程不会代为打开。

## 卸载

```powershell
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Uninstall-WindowsChannels.ps1"
& "$env:LOCALAPPDATA\Programs\QichengWindowsChannels\Uninstall-WindowsChannels.ps1" -Apply
```

默认保留 `channels.json` 和 token。只有明确需要清除当前用户数据时才使用 `-RemoveUserData -Apply`。卸载不会删除虚拟机、VHDX、ISO、客体软件或 Hyper-V 配置。
