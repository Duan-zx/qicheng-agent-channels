# Qicheng Lite 0.2.0-alpha.1-local

这是 Agent Channels 的首个轻量版本地安装候选。

## 下载产物

- `Qicheng-Lite.zip`：Windows 宿主当前用户安装器、双击入口、托盘查看器、两个 Linux 容器工作区、诊断和完整白名单源码。
- `Qicheng-Windows-Channels.zip`：Windows 客体兼容下载，由 `windows-channels` 模块独立构建，不属于本模块产物。

本版本不生成 Linux 主机发行资产。源码中的 Linux shell 脚本只用于开发者验证后端，并不包含 Linux 查看器。

Windows 默认安装根为 `%LOCALAPPDATA%\Programs\QichengLite`，数据根为 `%LOCALAPPDATA%\Qicheng\Lite`。由于既有后端和查看器接口，私有 token 固定在安装根 `.local\channel.token`，安装器会收紧 ACL 且不会显示其内容。

## 行为与兼容性

- Compose 项目固定为 `qicheng-agent-channels`，继续使用两个频道和 `127.0.0.1:18761/18762`。
- 启动和升级不执行 `docker compose down -v`，不删除 volume，不自动终止其他 Python、Docker 或产品进程。
- Windows 默认以 `--background` 托盘模式启动；PowerShell 启动快捷方式隐藏控制台。
- 可选择备份并停用精确名为“启程 Windows 频道.lnk”的旧当前用户 Startup 入口，以避免全局 Alt 快捷键冲突；其他启动项不受影响，备份可恢复。
- 导入现有 token 是显式选项；未导入时生成新的随机 32 字节 token。
- 开始菜单提供两个手动下载快照入口；只有 Compose 项目和服务标签均匹配时才从来宾 `Downloads` 导出到 DataRoot，且不覆盖旧快照或删除来宾文件。

## 依赖和未完成范围

用户必须自行准备并启动获准的 Docker Linux engine。首次镜像构建需要网络访问官方 Python 镜像及 Debian 软件源。Docker Desktop 不随包分发，其授权由 Docker 的现行条款决定。

本 alpha 未宣称容器镜像字节级可复现，也未捆绑第三方二进制许可证全集；构建后应保留镜像内 `/usr/share/doc/*/copyright`。真实安装、容器更新、持久 volume 迁移及业务账号体验由发布前本机验收覆盖，工程测试不替代这些检查。
