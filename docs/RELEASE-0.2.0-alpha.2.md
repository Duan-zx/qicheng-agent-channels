# Qicheng 0.2.0-alpha.2

本次 Alpha 修复了轻量版在真实 Windows 安装中的几个容易误导用户的问题：

- Windows PowerShell 5.1 直接运行诊断、启动、安装、下载导出和旧入口恢复脚本时，自动从脚本位置解析安装根。
- 保留旧的 `Port1`/`Port2` 参数形式，但只接受 Compose 固定端口 `18761` 和 `18762`，自定义值会得到明确错误。
- 升级安装时快照并恢复启程管理的快捷方式；失败时不会留下指向临时安装目录的入口。
- 欢迎页说明 Firefox 的安全提示和恢复提示属于浏览器原生状态，启程不会隐藏或绕过。

## 验证范围

Windows 本机验证了 65 项 Lite 包、双频道认证状态、后台查看器、JPEG 截图、stdio state/screenshot、暂停输入拒绝和公开源码 round-trip。Lite 仍需要 Windows 主机上的 Docker Linux engine。它提供两个 Linux 浏览器工作区，不替代 Windows 原生应用兼容版；复杂网站、长时间运行、高 DPI 和原生 AI 客户端输入批准闭环仍需单独验证。

Windows 系统、用户账号、Docker Desktop、浏览器业务账号和模型订阅不包含在发行包中。第三方许可见包内 `THIRD-PARTY-NOTICES.md`。
