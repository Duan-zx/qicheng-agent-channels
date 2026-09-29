# Agent Channel validation and limits / 验证范围与限制

The [Alpha 23 r2 trial package](../downloads/Agent-Channel-Windows-Linux-alpha23-r2.zip) is a development-machine candidate. Its package manifest and SHA-256 are described in the [install guide](INSTALL.zh-CN.md). The public Releases page still lists earlier Alpha builds. Source tests, package checks, and local repair do not prove independent installation on another PC.

Alpha 23 was installed on one Windows development machine after an explicit, ownership-checked repair of an existing Linux WeChat image. The installed files, record, and running image agreed; final diagnostics reported healthy with zero failures. A fresh MCP session used two independent Linux channels to enter different Chinese text, press Enter, click a button, and read back each channel's own saved value. Both sessions finished with no residual lease or input error. The installed viewer switched with Alt+1/2/3, preserved independent pause/takeover state, and successfully clicked a scaled guest form from a larger host display.

A roughly 31-second foreground-window sample during both channel actions observed the AI client at its 100 ms sample points. An earlier sample briefly saw a terminal switch of unknown cause. These observations do not establish that every shorter focus change is absent. The package's full-file hash check and isolated Windows PowerShell 5.1 installation success/failure tests passed; the keep-data uninstaller passed isolated tests only. A login-recovery entry point started successfully, but the host was not rebooted for this acceptance.

**Still unverified:** independent first installation and network image build on another physical Windows PC; recovery after its reboot; other physical DPI or multi-monitor arrangements; real WeChat sign-in, opening and compiling a legitimate project; and long-term behavior on arbitrary sites or AI clients. No business, publishing, or account outcome is claimed.

Windows Channels and Task Lease are [separate experimental components](../README.md#other-components). Their isolated tests or synthetic actions do not expand the Lite trial's acceptance.

---

该 [Alpha 23 r2 试用包](../downloads/Agent-Channel-Windows-Linux-alpha23-r2.zip) 属于开发机候选；包清单与 SHA-256 见[安装说明](INSTALL.zh-CN.md)。公开 Release 仍是旧版。源码测试、包校验和本机修复，不能代替另一台电脑的独立首装。

一台 Windows 开发机在核对现有镜像和容器归属后，按明确修复路径安装了 Alpha 23。安装文件、记录与运行镜像一致，末次诊断 healthy、零失败。新的 MCP 会话在两个独立 Linux 频道分别输入不同中文、按 Enter、点击按钮，并读回各自保存值；结束后无遗留租约或输入错误。已安装查看器的 Alt+1/2/3、频道独立暂停与接管、缩放客体画面上的实际点击通过。

覆盖双频道动作的一次约 31 秒、100 ms 间隔宿主前台采样，在采样点均看到 AI 客户端；早前一轮曾短暂看到终端切换，原因未知，不能推断更短瞬间绝无切换。试用包完整文件哈希、PowerShell 5.1 隔离安装成功/失败分支通过；保留数据卸载只做了隔离测试。登录恢复入口可启动，但本轮没有整机重启。

**仍待验证：**另一台物理 Windows 电脑的独立首次安装、联网构建与重启恢复；其他物理 DPI 或多屏；真实微信登录、合法项目打开与编译；不同网站和 AI 客户端的长期使用。这里不声称任何业务、发布或账号结果。Windows Channels 与 Task Lease 属于[独立实验组件](../README.zh-CN.md#其他组件)，其隔离或合成测试不扩大本次 Lite 试用验收。
