# Keep-data uninstall / 保留数据卸载

For the [Alpha 23 r2 trial package](../downloads/Agent-Channel-Windows-Linux-alpha23-r2.zip), save unfinished forms and export any guest Downloads you need first. With Docker Desktop's Linux engine running, exit the viewer through **Exit and pause input**. Run `Uninstall-Qicheng-Lite.cmd` from the installed Agent Channel program directory. Review its preview before confirming. It stops only the containers owned by this installation, removes its shortcuts, and moves the complete program directory—including local credentials—to the recovery location shown in its receipt. User data, Docker volumes, and images remain in place. Keep the recovery directory private; do not upload it to Git or a cloud drive.

The current uninstall path has passed isolated tests; it has not been used to remove the development-machine installation. If the command is absent, you have an older package: use that package's uninstall instructions instead of copying this command into an unmatched installation. Task Lease and native Windows guests have separate lifecycles.

---

使用 [Alpha 23 r2 试用包](../downloads/Agent-Channel-Windows-Linux-alpha23-r2.zip) 时，先保存未提交的表单，并取回需要的频道下载文件。保持 Docker Desktop 的 Linux engine 运行，从查看器托盘选“退出并暂停输入”。在已安装的 Agent Channel 程序目录双击 `Uninstall-Qicheng-Lite.cmd`，查看预览后再确认。它只停止本安装的容器、移除本安装的快捷方式，并把完整程序目录及其中的本地凭据移到回执列出的恢复位置；用户数据、Docker 数据卷和镜像保留。恢复目录应保存在本机私有位置，不要上传到 Git 或网盘。

这条卸载路径只通过隔离测试，尚未在开发机正式安装上执行。若当前安装没有该命令，说明它是较早版本；请按该包自己的卸载说明处理，不要把新命令套用到旧安装。Task Lease 和 Windows 原生客体需分别处理。
