# 启程工作台 · Windows 频道

这是安装后驻留在 Windows 托盘的统一工作空间。默认启动不打开管理窗口、不抢占当前焦点；用户通过全局快捷键或托盘直接进入指定频道。

## 日常使用

- `Alt+1`：返回本机并隐藏频道窗口。
- `Alt+2` 到 `Alt+9`：按配置顺序进入最多 8 个 Windows 频道。只为实际存在的 bindings 注册快捷键。
- 选择频道后直接进入全屏远程画面。顶部栏显示明确的频道编号、项目名和真实 mode，并保留 **返回本机 / 人接管 / 交给 AI / 暂停 / 设置 / 隐藏控制栏 / 退出全屏**。
- 隐藏控制栏后画面占满窗口；按 `Escape` 恢复控制栏。控制栏显示时按 `Escape` 退出全屏，回到设置与管理窗口。
- 托盘菜单根据 bindings 动态生成频道项。双击托盘图标打开设置与管理窗口。
- 关闭管理窗口只隐藏到托盘；使用托盘“退出”才结束程序。

尚未载入真实截图时，Viewer 可显示安装根 `theme\ai-space.png`。画面中央始终明确写出“正在连接 / 尚未显示真实桌面”或“频道未就绪”，不会把主题图伪装成客体桌面。

## 控制权与输入

- **人接管**进入 human 模式，可在远程画面点击、输入字符和白名单按键，也可从底部文字框发送一段文字。
- **交给 AI**会先清理尚未发送的人类输入；若当前为 human，会先 pause 再 allow。
- **暂停**停止人和 AI 输入。
- 控制权切换期间不接收新的人类输入。输入失败后，Viewer 对原项目 best-effort pause 并重新读取 state；只按回读结果显示真实模式，无法回读时显示“状态未知”。

截图约每 1.8 秒刷新，状态约每六轮重新读取。项目切换立即清除旧画面，generation 检查阻止旧项目的异步结果写入新频道。人工输入按顺序发送，截图刷新期间产生的输入进入有限队列。

## 启动与首次设置

安装布局保留：

```text
<安装根>/
  Setup-WindowsChannels.ps1
  Start-WindowsChannels.ps1
  host/
  theme/ai-space.png
  viewer/
    dist/WindowsChannelsViewer.exe
```

正常后台启动：

```powershell
WindowsChannelsViewer.exe --config 'D:\ProgramData\Qicheng\channels.json' --python 'C:\Program Files\Python312\python.exe'
```

用户明确打开设置与管理窗口：

```powershell
WindowsChannelsViewer.exe --config 'D:\ProgramData\Qicheng\channels.json' --python 'C:\Program Files\Python312\python.exe' --show
```

`--config` 与 `--python` 必须是盘符开头的完整本地路径；相对路径、`C:folder`、根相对路径和 UNC 会被拒绝。配置支持 1–8 个项目。缺少配置时 Viewer 显示首次设置提示，并只查找安装根的 `Setup-WindowsChannels.ps1`。设置入口启动该脚本后退出 Viewer，设置完成后由 `Start-WindowsChannels.ps1` 重新启动，避免继续使用旧配置快照。

同一 Windows 用户只运行一个 Viewer。第二次后台启动不会弹出窗口；第二次使用 `--show` 会唤出已运行实例的管理窗口。

## 构建与验证

```powershell
.\Build.ps1
```

Viewer 保持以下 host CLI 接口：

```text
python -m host.client --config ... --project ... state|screenshot|allow|pause|takeover
python -m host.client --config ... --project ... input --actor human --action ...
```

截图临时文件只写入 `<安装根>\.local\viewer`，验证 PNG 和尺寸后载入并删除。Viewer 不读取 token、不把 guest 输入改发到宿主桌面，也不提供 shell。文字目前经既有 CLI 参数传递。

`--self-test <absolute-output.json>` 验证参数、配置变化拒绝、`--show`、默认隐藏、动态快捷键边界、坐标映射和 human actor 路由；不打开 GUI、不调用 Host CLI。真实托盘、全局快捷键、全屏、DPI 和多频道体验仍需安装版桌面验收。
