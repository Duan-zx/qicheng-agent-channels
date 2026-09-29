# Stop or remove Qicheng Lite / 停用或移除启程轻量版

This is the manual alpha.16 procedure. There is no one-click uninstaller. First export any Downloads you need from the installed Start-menu shortcut and save unfinished web forms. In the viewer tray, choose **Exit and pause input**. Remove the current user's “启程轻量工作台” shortcut from the Windows Startup folder to prevent the next sign-in from starting it.

Open PowerShell as the same Windows user who installed Lite, then stop only the Qicheng Compose project:

```powershell
$install = Join-Path $env:LOCALAPPDATA 'Programs\QichengLite'
docker compose --project-name qicheng-agent-channels --project-directory $install -f (Join-Path $install 'compose.yaml') --profile second stop
```

Remove the Qicheng Lite shortcuts from this user's desktop and Start menu. You can leave the program directory in place while testing. If you remove it, first keep a private backup of the **whole** `%LOCALAPPDATA%\Programs\QichengLite` directory: its `.local` subfolder holds channel, viewer and optional Lite broker tokens. Keeping only the Docker volumes will not preserve those credentials or the existing AI connection. Do not upload the backup to GitHub.

The stop command leaves containers, user settings, exported Downloads, and browser volumes intact. Before moving the program directory, you may replace `stop` with `down` in the same command to remove the Qicheng containers and network; **do not add `-v`** if you want to keep browser data. The two possible named volumes are `qicheng-lite-home-1` and `qicheng-lite-home-2`. User settings and exported Downloads are under `%LOCALAPPDATA%\Qicheng\Lite`. Remove these volumes and files separately only after you have backed up anything you need. Task Lease, Windows guests, and their licenses are separate and are not removed by these steps.

---

这是 alpha.16 的手工步骤，目前没有一键卸载。先从开始菜单取回需要的频道下载文件，保存未提交的网页表单，再从托盘选择“退出并暂停输入”；删除当前用户“启动”目录里的“启程轻量工作台”快捷方式。用安装时的同一用户在 PowerShell 运行上面的命令，只停止启程 Compose 项目。

桌面和开始菜单快捷方式可随后移除。准备将 `%LOCALAPPDATA%\Programs\QichengLite` 程序目录移走或删除时，先把**整个目录**备份到自己可访问的本机私有位置；其中 `.local` 保存频道、Viewer 和可选 Lite broker token。仅保留 Docker 卷不保证以后能原样恢复 AI 接线。上述 `stop` 默认保留容器、`%LOCALAPPDATA%\Qicheng\Lite` 用户数据及 `qicheng-lite-home-1/2` 浏览器卷；需要移除容器时，可在移走程序目录前把同一命令末尾改为 `down`，不要加 `-v`。永久清理卷和用户目录前先备份。Task Lease、Windows 客体及许可另行处理。
