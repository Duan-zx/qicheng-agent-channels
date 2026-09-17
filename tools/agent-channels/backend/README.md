# Linux 轻量频道后端

后端在每个容器的私有 X11 桌面内提供现有 `state`、`control`、`input` 和 PNG `screenshot` 接口，并增加受同一 Bearer token 保护的 `GET /api/frame.jpg`。JPEG 固定质量为 72，响应禁止缓存，供人工查看器降低连续刷新开销。

`frame.jpg` 仍是按请求生成的单张画面，不是视频流，也不保证固定帧率。查看器需要按自己的节奏轮询，并把 HTTP 错误显示为频道故障。

默认桌面为 1600×900。Firefox 使用正常地址栏和标签页；compose 为两个频道分别把完整 `/home/channel` 挂载到固定命名卷 `qicheng-lite-home-1`、`qicheng-lite-home-2`，因此默认 Firefox profile 与 `Downloads` 能一起迁移和持久化。

镜像安装最小 Firefox 企业策略：跳过首次使用、更新后欢迎页和功能推荐，并关闭翻译面板自动弹出。翻译功能本身仍可手动使用；标签页会话恢复、Safe Browsing、沙箱和操作系统保护警告不被改变或隐藏。
