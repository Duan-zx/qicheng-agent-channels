# 素材来源与公开范围

以下记录只说明素材从哪里来、当前文件与原件是否相同；它不替代对第三方界面、商标、隐私或适用许可的发布审查。生成原件、调用时间与提示原文、复制操作和哈希核验记录保存在产品私有任务证据中，不随公开仓分发。

| 素材 | 可复核来源 | 当前 SHA-256 | 状态 |
| --- | --- | --- | --- |
| `tools/windows-channels/theme/ai-space.png` | 2026-09-17 在本产品任务内用内置图像生成工具生成；生成原件与当前文件逐字节哈希相同 | `1cf933351f3a7e401e30e954582ee0d94d75cdb7c71b52d7e68a9920b027149c` | 旧版壁纸，仍随当前源码 |
| `tools/agent-channels/backend/theme/ai-space.png` | 复用上行同一生成原件；哈希相同 | `1cf933351f3a7e401e30e954582ee0d94d75cdb7c71b52d7e68a9920b027149c` | 兼容保留的旧 Lite 素材；当前欢迎页无直接引用 |
| `tools/windows-channels/theme/ai-space-v2.png` | 2026-09-28 在本产品任务内用内置图像生成工具生成；生成原件与当前文件逐字节哈希相同 | `10abe0c2517768476e13962451488776859e8c35716dab789016a96f1b08107e` | 新版 Windows 壁纸 |
| `docs/images/lite-workspace.png`（历史） | 01 测试机原始 `lite-native-welcome.png` 截图；2026-09-17 曾进入仓库，原件与当时仓库文件哈希相同 | `9e7721bece5879528d1cc2b806239b505debf9176f099abcd9ef37ac8ef0867b` | 已从本地候选跟踪树移除；本机原件保留作证据，远端 main 与 Git 历史仍可访问 |
| `docs/images/windows-workbench.png`（历史） | 01 测试机原始 `installed-viewer-wechat-b.png` 截图；2026-09-17 曾进入仓库，原件与当时仓库文件哈希相同 | `442d59effe67a7faddc43fa5a0f595d87e7cd7633a38d2715d3bd7e648f5e90f` | 含 Windows 和微信开发者工具界面；已从本地候选跟踪树移除，远端 main 与 Git 历史仍可访问 |
| `docs/images/workspace-concept.svg` | 在本仓以 SVG 基本图形和文字编写，未嵌入外部图片；本机 XML 解析和渲染读回 | 以提交中的源文件为准 | 首页产品结构示意，明确标注非实机截图 |

旧版生成提示指定深蓝背景、右侧玻璃轨道和少量连接光点，左侧保留桌面图标空间，并排除文字、标志和假 UI。新版提示指定克制的深夜蓝建筑空间、半透明平面、细轨迹、薄荷色光和一点珊瑚色，左侧留白，并排除人物、标志、界面和星体。私有证据保存了两次提示原文与生成原件；公开表格仅列可用于复核的来源与哈希。

这些记录解决了“是否本项目生成、是否与记录中的文件相同”的证据缺口。生成图片仍需按生成时适用条款和人工视觉检查确认使用范围；生成记录本身不保证任何图案都有独占版权或不存在第三方相似性。[OpenAI 当前使用条款](https://openai.com/policies/terms-of-use/)说明输出权利在双方之间的归属与人工审查责任。两张旧截图已从本地候选的跟踪树移除，但删除当前树文件不能抹去远端 main 或 Git 历史；历史 `windows-workbench.png` 含第三方软件界面，不能把它恢复为首页宣传图。

2026-09-28 对当前文件及私有交付 ZIP 中同哈希主题图的补查：两版 PNG 都嵌有 `caBX` 数据块；[C2PA PNG 规范](https://spec.c2pa.org/specifications/specifications/2.4/specs/ContentCredentials.html)将其用于内嵌来源 manifest。C2PA Python SDK 0.37.12 读到的图片数据哈希与声明签名相符，但总体信任状态为 `Invalid`：该 SDK 未信任签名/时间戳证书，并报告签名证书缺少所需 EKU。这不是图片篡改结论，也不能作为来源已获可信认证的证明。定向扫描未在解析出的 manifest JSON 中发现邮箱式字符串或本机私有 Windows 路径；它不替代完整隐私审查。保留原始来源数据块，不通过删去 metadata 制造通过结果。脱敏检查回执留在私有任务证据中。
