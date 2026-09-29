# Linux 微信开发者工具可选镜像

此入口沿用启程 Lite 的私有 X11 桌面、`channel1`/`channel2`、`qicheng-lite-home-1`/`qicheng-lite-home-2`、控制权门禁、截图及 MCP 桥。切换镜像会重建对应容器，先保存频道内的未保存工作，并核对当前 Compose 项目和资料卷。它不会删除 volume。不要对正在执行业务的频道直接运行下列命令。

Docker Linux engine 是外部依赖，本产品不内置 Docker Desktop；Docker Desktop 是否免费取决于其官方条款和具体商用场景。首次微信镜像构建会下载约 195 MB 的 DEB，还会安装依赖并占用额外镜像空间。2026-09-28 在一台试验主机的快照中，派生镜像约 816 MB、Lite 基础镜像约 332 MB，两微信试验频道约占 950/832 MiB 内存；这些是单机观测，不是其他设备的资源保证。

源码和安装包仅包含构建说明及启程编写的 CLI shim。腾讯开发者工具 DEB 在用户明确构建可选镜像时从 [msojocs 的 GitHub Release](https://github.com/msojocs/wechat-web-devtools-linux/releases/tag/v2.02.2608070-2) 下载，固定为 `io.github.msojocs.wechat-devtools-linux_2.02.2608070-2_amd64.deb`，SHA-256 必须等于 `c5246f3f7548905a8e768ed464d9f6400e3a59d0cd539f1fe6a85dde29860457`。校验失败会中止构建。该第三方二进制不受本包 Apache-2.0 许可覆盖，下载、安装与账号使用遵循其适用条款。

在已安装 Lite 的根目录执行；需要 Linux Docker engine、网络与原有 `.local/channel.token`。如果启用了 broker，附加原有 `compose.broker.yaml`；所有后续 Compose 命令均须使用相同文件组合。

Windows 用户应在新包的 `Qicheng-Lite` 目录通过安装器预览并应用持久选择：`./Install-Qicheng-Lite.ps1 -DesktopApp wechat`，核对计划后执行 `./Install-Qicheng-Lite.ps1 -DesktopApp wechat -LaunchAfterInstall -Apply`。安装记录会保存 `desktopApp=wechat`，以后普通启动和登录恢复读取同一记录，并在现有 broker token 存在时继续叠加 `compose.broker.yaml`。升级默认保留已选桌面应用；要切回 Firefox，显式用 `-DesktopApp firefox -LaunchAfterInstall -Apply`。默认路径联网构建新的 Lite 底座及微信镜像。安装前请先保存频道内未保存工作并退出查看器。

若 Docker Hub 的基础镜像元数据不可达，但**当前安装的 Lite 基镜像仍在本机且能通过旧包 manifest、正在使用的容器、两个资料卷和镜像内后端内容核验**，可选择本机 DEB 路径升级：

```powershell
.\Install-Qicheng-Lite.ps1 -DesktopApp wechat -ReuseExistingBackendImage -WechatDebPath 'C:\private\io.github.msojocs.wechat-devtools-linux_2.02.2608070-2_amd64.deb'
.\Install-Qicheng-Lite.ps1 -DesktopApp wechat -ReuseExistingBackendImage -WechatDebPath 'C:\private\io.github.msojocs.wechat-devtools-linux_2.02.2608070-2_amd64.deb' -LaunchAfterInstall -Apply
```

这条路径只免去**重新拉取 Lite 基础镜像**和远程下载微信 DEB。基础 Lite 镜像未内置 `libgbm1`、`libxss1` 等微信运行依赖，派生镜像仍需从 Debian 软件源安装依赖；Debian 源不可达时构建失败并保留旧安装。DEB 必须是本机绝对路径的普通文件，不得经符号链接或 junction 指向其他位置，不得放在安装包或安装目录内；安装器在预览和复制到临时 Docker 构建上下文后均核对固定 SHA-256。临时上下文中的 DEB 不进入 Git、安装目录或公开 ZIP，构建结束即清理。升级保留基础镜像原标签；仅微信派生镜像使用候选标签构建，失败时恢复旧标签。

```sh
# 构建已有 Lite 底座；不会启动容器。
docker build -t qicheng-agent-channels:0.1-local -f Dockerfile .
# 构建两频道共用的可选镜像；DEB 只存在于构建过程和本地镜像中。
docker compose --project-name qicheng-agent-channels -f compose.yaml -f compose.wechat.yaml --profile second build channel1
# 核对输出的项目、端口、卷与镜像后，显式切换两个频道。
docker compose --project-name qicheng-agent-channels -f compose.yaml -f compose.wechat.yaml --profile second config
docker compose --project-name qicheng-agent-channels -f compose.yaml -f compose.wechat.yaml --profile second up -d --no-build channel1 channel2
```

若已有 broker token，在上述三个 `docker compose` 命令的 `-f compose.wechat.yaml` 后追加 `-f compose.broker.yaml`。不要把 broker token 内容写入命令行。只启动频道一时省略 `--profile second` 和 `channel2`，并保留频道二的原状态。

可选镜像启动时自动打开微信开发者工具 GUI。每个频道的 `$HOME=/home/channel` 挂载到其独立资料卷，因此登录资料也分别保存。账号登录、扫码及开发者工具“设置 → 安全设置 → 服务端口”的开启须由使用者在对应频道完成；新 profile 默认关闭，A 频道开启不会替 B 频道开启。不要自动开启“允许获取登录票据”。微信 CLI 仅在各自客体内通过 `127.0.0.1` 使用；Compose 不映射微信 CLI 服务端口给宿主。服务端口未开时 CLI 操作可能无法工作。

容器内 CLI 使用 `/usr/local/bin/wechat-devtools-cli`，例如：

```sh
docker compose --project-name qicheng-agent-channels -f compose.yaml -f compose.wechat.yaml exec channel1 wechat-devtools-cli islogin
```

shim 直接以 `ELECTRON_RUN_AS_NODE=1` 执行 Electron 的 `js/common/cli/index.js`。上游的 `bin/wechat-devtools-cli` 包装脚本对 `islogin` 只打印帮助，不能作为验收入口。上游 JS 在某些失败中会以退出码 0 打印 `[error]` 或非零 JSON `code`；shim 将其转成非零退出码。`{"login":false}` 是有效的未登录状态，不代表登录成功。`open --project ...` 需要额外核对开发者工具中的实际项目状态，不能仅凭进程退出码或命令受理报告成功。

验收顺序：确认两频道的 `/health` 和认证后的 `/api/state` 分别显示正确 `channel_id`、私有 Linux display 和预期输入授权模式；分别截图确认 GUI 与频道资料；逐频道运行 `islogin` 并核对输出；在用户完成登录和打开服务端口后再试实际项目操作。MCP 仍通过原有 `bridge.py --channel 1/2` 接入；新频道默认是 `agent`，人工接管或暂停后须由人在查看器里交回 AI，所选状态会随各频道资料卷保留。切回 Firefox 可用原 `compose.yaml`（及已启用的 broker 覆盖文件）重建容器，保留同一资料卷。
