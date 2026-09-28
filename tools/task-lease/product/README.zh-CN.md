# 启程 Task Lease（可选组件）

此组件在单台 Windows 主机上提供本地任务租约和固定 CLI 动作代理。它只保护经 `/v1/execute` 进入 broker 的动作；已有 MCP、微信 CLI、Computer Use 和 n8n 工作流不会被自动拦截。需要 Python 3.10+ 与 Windows PowerShell 5.1 或 PowerShell 7，不需要管理员权限或第三方 Python 包。
源码和安装包按随附 `LICENSE` 的 Apache-2.0 条款提供。

## 独立公开源码候选

从私有仓导出源码时，先在仓外创建一个**已存在的空目录**，再运行：

```powershell
New-Item -ItemType Directory 'D:\handoff\TaskLeasePublicSource' | Out-Null
& .\tools\task-lease\product\Export-PublicSource.ps1 -OutputDirectory 'D:\handoff\TaskLeasePublicSource'
```

导出器只复制显式列出的 Task Lease 源码、产品脚本、测试和所需的 Windows Channels host 客户端模块，保留 `tools/` 相对结构。根目录 `LICENSE` 与 `PUBLIC-SOURCE-MANIFEST.json` 单独记录许可和每个文件的 SHA-256；该清单与安装包的 `package-manifest.json` 互不替代。配置、账号、token、数据库、任务证据、内部项目记忆和 Git 元数据不在白名单内。公开前仍需人工审查导出目录；该命令不发布或推送。

在 Windows PowerShell 5.1 中可运行 `& .\tools\task-lease\product\tests\Test-PublicSourceExport.ps1` 检查输出边界、清单哈希和导出树构包。导出树中的包构建脚本路径为 `tools\task-lease\product\Build-Package.ps1`。

## 构包和安装

在源码仓执行（可把包复制到 DELL，解压后在目标机运行安装）：

```powershell
& .\tools\task-lease\product\Build-Package.ps1 -OutputDirectory 'D:\handoff\QichengTaskLease-0.1.0'
Expand-Archive 'D:\handoff\QichengTaskLease-0.1.0.zip' 'D:\handoff\unpacked'
& 'D:\handoff\unpacked\product\runtime\Install-TaskLease.ps1' -PackageRoot 'D:\handoff\unpacked' # 预览
& 'D:\handoff\unpacked\product\runtime\Install-TaskLease.ps1' -PackageRoot 'D:\handoff\unpacked' -Apply
```

如果 `python.exe` 不在 PATH，附加 `-PythonPath 'C:\...\python.exe'`。默认安装在 `%LOCALAPPDATA%\Programs\QichengTaskLease`，私有数据在 `%LOCALAPPDATA%\Qicheng\TaskLease`。安装会检查包清单和 SHA-256、复制白名单文件，并生成 `broker.token`。不自动启动、不自动修改现有工具配置。安装脚本拒绝覆盖未知目录和现有安装；更新前先停止 broker 并卸载旧包，用户数据默认保留。

## 配置和启动

在 `%LOCALAPPDATA%\Qicheng\TaskLease\config.json` 创建本机配置。下面是格式示意，必须替换成目标机的现有隔离项目路径与可执行文件绝对路径。示例动作只做只读探测；注册生产动作前需单独审核其副作用和端口。

```json
{
  "default_ttl_seconds": 60,
  "max_ttl_seconds": 300,
  "channels": [{
    "channel_id": "channel-2",
    "endpoint_id": "wechat-instance-2",
    "tool_id": "wechat-cli",
    "project_id": "demo",
    "project_path": "C:/Users/USER/work/demo",
    "exclusive_ports": [55975, 9420],
    "actions": {
      "check-login": {
        "argv": ["C:/path/to/cli.bat", "islogin", "--project", "C:/Users/USER/work/demo", "--port", "55975"],
        "timeout_seconds": 5
      }
    }
  }]
}
```

配置只接受已存在且互不重叠的绝对项目目录、固定命令及最长 8 秒动作。`endpoint_id` 必须指向实际独占工具实例。端口要与真实 CLI 服务及自动化端口核对。配置、凭据、`leases.db` 和其 `.key` 文件均留在用户数据目录，不要放在仓库或压缩包里。数据库和密钥备份时成对保存。

可选的私有 Windows guest 通道需要在对应 channel 增加 `guest`，其中 `host_config_path` 和 `broker_token_file` 必须是目标机上的绝对路径，`project` 必须是 host 配置中已有的项目名：

```json
"guest": {
  "host_config_path": "C:/private/windows-host.json",
  "project": "guest-a",
  "broker_token_file": "C:/private/guest-broker.token"
}
```

包内含固定的 Windows Channels host 客户端模块，安装时逐文件核对 SHA-256。host 配置及各通道、broker 凭据由目标机单独准备，不随包分发。普通不含 `guest` 的配置仍可使用。此包的离线测试只验证配置绑定与客户端构造；真实 guest 输入还需要目标 Windows/Hyper-V 环境单独验收。

### 将频道令牌迁入私有 DataRoot

若 Limited 计划任务无法读取原 `channels.json` 引用的频道 `token_file`，先**停止 broker**，确认没有其他程序会同时写其 `leases.db`，再对含此脚本的新安装包运行离线迁移。旧安装包需按前述卸载流程保留 DataRoot，安装新包后再执行；不要直接覆盖安装文件破坏包校验。源 host 配置和频道 token 必须由当前用户可读；此脚本不提高计划任务权限，也不输出 token 值。默认只预览：

```powershell
$migration = "$env:LOCALAPPDATA\Programs\QichengTaskLease\product\runtime\Migrate-GuestTokens.ps1"
& $migration -SourceHostConfig 'C:\private\channels.json'
& $migration -SourceHostConfig 'C:\private\channels.json' -BrokerStopped -Apply
```

脚本把 host 配置中由 broker 引用的频道 token 复制到私有 `DataRoot\guest-tokens`，生成私有 `DataRoot\channels.json`，并更新 `DataRoot\config.json` 中相应 `guest.host_config_path`。源文件保留。迁移前检查数据库的 guest 绑定指纹与当前配置一致，要求 `leases` 无记录、`guest_dirty` 为空、所有历史输入均为 `success` 且已 `acked`；成功历史记录保留旧指纹作为审计。迁移备份放在私有 `DataRoot\migration-backups`，包括 SQLite 一致性数据库快照、`.key`、旧 broker 配置和源 host 配置。若迁移被拒绝，先处理实际租约或未确认输入，不能删表或强行改指纹。异常回滚配置和指纹；若进程或主机在切换文件期间意外中断，应保持 broker 停止，使用该备份还原数据库与配置后再重试。完成后以原 Limited 任务身份做实际启动和 token 读取验收；预览与离线测试不证明该身份有文件读取权限。

Guest 输入采用 `acquire → input → ack → release`。每次 `/v1/input` 使用同一租约内稳定且唯一的 `action_id`；确认成功后调用 `/v1/ack`，正文为 `{"channel_id":"...","token":"<租约令牌>","action_id":"..."}`，收到对应成功回执后再继续下一动作。正常释放且所有动作均已确认时才解除该客体端点的占用。丢响应、失败或少了 ack 后，`GET /v1/status` 的 `guest_dirty=true` 会阻止后继任务，即使租约过期或 broker 重启也不会自动重做输入。需要核对客体实际结果后按随包技术说明离线处理；普通 HTTP 凭据不能直接清除该状态。旧版未接入 broker 的 MCP、查看器或 CLI 仍不受此门保护，必须完成客体门禁和新版客户端部署再声称隔离生效。

```powershell
& "$env:LOCALAPPDATA\Programs\QichengTaskLease\product\runtime\Start-TaskLease.ps1"
```

该命令在当前终端前台运行，监听 `127.0.0.1:18770`；Ctrl+C 停止。可用 `-Port` 指定端口。应由需要租约的任务启动器显式调用，不要同时启动同端口的第二份 broker。

如需在**当前用户登录 Windows 后**后台自动启动，可预览并安装当前用户的计划任务（无需管理员权限）：

```powershell
& "$env:LOCALAPPDATA\Programs\QichengTaskLease\product\runtime\Install-TaskLeaseAutostart.ps1" # 预览
& "$env:LOCALAPPDATA\Programs\QichengTaskLease\product\runtime\Install-TaskLeaseAutostart.ps1" -Apply
```

它要求私有 `config.json` 和 `broker.token` 已就绪，只注册 `QichengTaskLease` 任务，**不会立即启动**。下次当前用户登录后，任务在后台运行 Windows PowerShell 5.1 的 `Run-TaskLeaseAutostart.ps1`，再调用正式启动脚本；仍仅监听 broker 固定的 `127.0.0.1`。启动输出和异常记录在私有数据目录的 `broker-autostart.log`，每次启动覆盖上次日志。可在安装自启动时附加 `-Port`，但必须先核对端口未被占用；已有同名任务会拒绝覆盖。任务依赖用户登录，不在无人登录的系统启动阶段运行。计划任务使用单实例设置；现有手工 broker 占用端口时，新实例会启动失败，不会接管它。登录后用诊断脚本检查真实 HTTP 回应和私有启动日志；睡眠、用户注销或任务进程退出会中断服务。

撤销自启动先运行 `Uninstall-TaskLeaseAutostart.ps1` 预览，再加 `-Apply` 移除该计划任务。脚本可识别同一路径的早期 `Start-TaskLease.ps1` 任务和当前启动器，只移除能匹配本安装路径的任务，不停止当前运行的 broker。卸载组件前必须先移除计划任务；如需停用当前 broker，应按实际进程单独停止。不要用 `Start-Process` 后台拉起启动脚本，其子进程 PowerShell 环境可能无法发现 `Get-FileHash`；计划任务直接运行脚本，运行时包校验使用 .NET SHA-256。

## n8n 连接

n8n 若在 Windows 宿主运行，HTTP Request 节点使用 `http://127.0.0.1:18770`；若在本机 Docker Desktop 容器中，01 已实测可经 `http://host.docker.internal:18770` 访问宿主 broker，容器内的 `127.0.0.1` 则指向容器自己。其他主机或容器网络需独立验证；broker 只绑定宿主回环，不提供通用远程服务。把 `broker.token` 存为 n8n 私有 Bearer 凭据，避免写入工作流导出、日志或节点正文；设置 `Content-Type: application/json`：

1. `POST /v1/acquire`，正文如 `{"request_id":"run-123-attempt-1","task_id":"run-123","channel_id":"channel-2","ttl_seconds":60}`。每次新执行用新的 `request_id`，同次重试沿用原值。
2. 只把响应的租约 `token` 传给可信的后续节点；`POST /v1/execute`，正文如 `{"channel_id":"channel-2","token":"<lease token>","action":"check-login"}`。节点不可传入任意命令、路径或端口。
3. 若任务继续，过期前 `POST /v1/renew`，正文如 `{"channel_id":"channel-2","token":"<lease token>","ttl_seconds":60}`。无论成功、失败或取消，都在收尾分支 `POST /v1/release`，正文如 `{"channel_id":"channel-2","token":"<lease token>"}`。

`GET /v1/status` 返回不含租约令牌的状态，仍要求 broker Bearer 凭据。409 `busy` 应排队或稍后重试；410 `lease_gone` 必须新建执行尝试；401 表示 broker 凭据错误。租约 TTL 应大于最长动作和排队时间。长期或异步动作需要目标侧另建执行门与心跳，不能只靠此 broker。

## 诊断与卸载

```powershell
& "$env:LOCALAPPDATA\Programs\QichengTaskLease\product\runtime\Diagnose-TaskLease.ps1"
& "$env:LOCALAPPDATA\Programs\QichengTaskLease\product\runtime\Uninstall-TaskLease.ps1" # 预览
& "$env:LOCALAPPDATA\Programs\QichengTaskLease\product\runtime\Uninstall-TaskLease.ps1" -Apply
```

诊断只报告安装、文件、Python、配置和 loopback 状态，不打印令牌。卸载只删除已验证安装目录，保留用户配置、token、数据库与密钥；若 broker 仍在运行会拒绝卸载。需要清除私有数据时由用户单独处理。DELL 复验应记录目标机 Python 版本、安装和诊断 JSON、实际租约 HTTP 往返与目标动作结果，不能以打包或安装成功代替端到端接入。
