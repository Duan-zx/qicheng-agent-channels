# 启程轻量版快速说明

版本以安装包内 `package-manifest.json` 为准。

## 先确认依赖

轻量版需要已经可用的 Docker Linux engine。安装包不包含 Docker Desktop，也不声称 Docker Desktop 开源或无条件免费。首次构建容器镜像需要联网访问官方 Python 镜像与 Debian HTTPS 软件源；后续启动可复用本机镜像。

轻量版启动器运行在 Windows 宿主，需要系统 .NET Framework 4.x。发布包已经带有编译好的 `dist/AgentChannels.exe`，普通安装不需要重新编译；公开源码可用 `source/Build.ps1` 重建。

## Windows 当前用户安装

解压 `Qicheng-Lite.zip`，进入其中的 `Qicheng-Lite` 目录并双击 `Install-Qicheng-Lite.cmd`。默认安装到：

- 程序：`%LOCALAPPDATA%\Programs\QichengLite`
- 用户数据：`%LOCALAPPDATA%\Qicheng\Lite`
- 私有 token：程序根 `.local\channel.token`（后端和查看器的现有接口要求此位置）

双击安装会创建两个频道，使用固定 Compose 项目 `qicheng-agent-channels`，端口仅绑定 `127.0.0.1:18761` 和 `127.0.0.1:18762`。它不会执行 `docker compose down -v`，不会删除 volume，也不会停止无关进程。

要复用已有 token，请从 PowerShell 显式运行：

```powershell
.\Install-Qicheng-Lite.ps1 -ImportTokenPath 'D:\private\channel.token'
.\Install-Qicheng-Lite.ps1 -ImportTokenPath 'D:\private\channel.token' -DisableLegacyWindowsChannelsStartup -LaunchAfterInstall -Apply
```

第一条只显示计划；第二条才执行。token 必须是 64 位小写十六进制，复制后只允许当前用户和 SYSTEM 访问，值不会进入输出或 manifest。

默认从托盘后台启动查看器（`--background`）。桌面、普通开始菜单和登录启动项都使用隐藏 PowerShell；“管理启程轻量工作台”用于打开可见管理界面。

为避免两套产品同时注册全局 Alt 快捷键，双击安装会停用**精确名为**“启程 Windows 频道.lnk”的旧当前用户 Startup 快捷方式，并把原文件备份到轻量版 DataRoot。不会改其他启动项，也不会杀进程。开始菜单“恢复旧 Windows 频道自启动”可恢复备份；目标已存在时拒绝覆盖。

来宾浏览器下载保存在 Docker volume 内。开始菜单“取回频道一/二下载文件”会先核对容器确实属于本产品，再把 `/home/channel/Downloads` 手动导出为 `%LOCALAPPDATA%\Qicheng\Lite\Downloads\频道N\时间戳` 快照并打开目录。每次使用新目录，不覆盖以前同名文件；来宾原文件和 volume 保留。

## 开发者 Linux 后端脚本

源码白名单保留 `product/runtime/linux/` 下的用户目录安装和后端启动脚本，便于开发者验证 Compose 后端。当前版本不生成 Linux 主机发行资产，也不提供兼容的 Linux 查看器；这些脚本不是普通用户下载入口。

```sh
sh ./product/runtime/linux/install.sh --prefix /absolute/path
```

## 诊断与边界

Windows 开始菜单可运行“诊断启程轻量工作台”。诊断只读，不启动、不停止、不重建容器，并使用本地 token 验证两个私有 Linux 显示的认证状态和尺寸。

本版本提供本地安装、两频道容器启动、托盘查看器、诊断和源码重建。它不安装 Docker、不替用户接受第三方许可、不登录业务账号，也不把工程测试等同于真实业务可用性。第三方许可边界见 `THIRD-PARTY-NOTICES.md`。

## AI 客户端接入（Lite）

宿主另需 Python 3.10+。查看器和浏览器本身不依赖宿主 Python；只有 MCP 适配器需要它。启程不附带模型或订阅。

已安装 Codex CLI 和 Python 时，在 PowerShell 注册两个独立服务：

```powershell
$python = (Get-Command python.exe -ErrorAction Stop).Source
$bridge = "$env:LOCALAPPDATA\Programs\QichengLite\bridge.py"
codex mcp add qicheng_lite_1 -- $python $bridge --channel 1
codex mcp add qicheng_lite_2 -- $python $bridge --channel 2
```

重新加载 AI 客户端，按客户端要求批准工具。在频道点击“交给 AI”，再要求 AI 先读取 `channel_state` 和 `channel_screenshot`，确认频道后调用 `channel_input`。人工接管或暂停后，AI 输入会被拒绝；不要改用宿主桌面绕过拒绝。

已验证适配器 stdio 协议、实际频道输入和暂停边界。不同 AI 客户端的加载、权限和端到端执行需要分别验证；注册成功不代表客户端已经可用。两个频道互相独立，工具不会退回宿主桌面。
