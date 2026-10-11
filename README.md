# GPT 学习伴侣

一个本地 Markdown 阅读与问答工具：类似 Obsidian 的文件树和标题大纲、文档阅读/编辑、右侧真实 ChatGPT 网页。macOS 使用原生 AppKit/WebKit；Windows 使用 Electron，共用阅读和网页交互资源。

<img src="assets/app-icon.png" width="96" alt="GPT 学习伴侣图标">

## 下载

[GitHub Releases](https://github.com/tttlllxxx/gpt-study-companion/releases) 提供：

- `GPTStudyCompanion-macOS-universal.zip`：macOS 13+，Apple Silicon 和 Intel。解压后打开“GPT 学习伴侣.app”。
- `GPTStudyCompanion-Windows-x64.exe`：Windows 10/11 x64 便携版，双击运行。

发行包未使用商业签名或 Apple 公证，首次运行可能收到系统开发者验证提示。登录和文档数据留在本机，不包含在仓库或发行包中。首次进入右侧 ChatGPT 需要登录；会话过期时仍需重新登录。

## 使用

1. 初次启动显示只读欢迎页。侧栏文件夹图标用于选择目录，文件图标用于打开单个 `.md` / `.markdown`；目录递归显示 Markdown，单击文件切换。
2. 最左侧顶部图标可隐藏/展开文件树；macOS 的 `⌘\` 和 Windows 的 `Ctrl+\` 也可使用。文件夹可折叠，并提供“收起全部”。
3. 文档顶部列表图标显示/隐藏大纲。点击标题跳转，正文上下翻页时大纲跟随当前章节，自动展开对应分组。
4. `⌘F` / `Ctrl+F` 展开文内搜索。阅读位置按文档分别记录，切换回来或重启后恢复章节内的位置。
5. 选中文段，在底部输入问题（可留空），点击“提问”。内容加入真正的 GPT 输入框并保留已有草稿；检查后再发送。不会改写回答中的可编辑代码。
6. “加入聊天”把当前编辑内容作为文件附件加入右侧聊天，并填写配套学习提示词；包含尚未保存的修改。等待网页上传完成后编辑提示词并发送。
7. 切换到编辑模式，放置光标，选中或复制右侧回答，点击“插入选中回答”写回当前笔记。`⌘S` / `Ctrl+S` 保存。切换、退出或关闭窗口前有未保存修改时，提供保存、放弃和取消。
8. 如果文档在外部程序中更改或被删除，工具会阻止覆盖，提示先保留编辑内容并重新打开。

只有“加入聊天”或用户发送问题时才将相关内容交给 ChatGPT；浏览本地文档不会自动上传。两平台的登录存储独立，不交换账户数据。

## 从源码构建

需要 Node.js 24。原生 macOS 构建还需要 Xcode Command Line Tools。

```bash
git clone https://github.com/tttlllxxx/gpt-study-companion.git
cd gpt-study-companion
npm ci
```

macOS 本机架构：

```bash
./build.sh
open "GPT 学习伴侣.app"
```

Windows 开发与打包（在 Windows 运行）：

```bash
npm start
npm run dist:windows
```

输出位于 `release/`。Windows 用 WebContentsView 隔离聊天页面，远端页面没有 Node 或本地文件桥接权限。

GitHub Actions 在 `v*` 标签推送时分别在 Windows、macOS runner 构建和检查，然后把两种产物放进同一个 Release。Mac 产物由两种架构二进制合并生成。构建工作流位于 [.github/workflows/release.yml](.github/workflows/release.yml)。

## 验证

```bash
npm test
npm run test:desktop
```

原生 Mac 的文件写入、窗口决策、分栏、大纲联动、附件、聊天输入框和 Markdown 渲染检查：

```bash
"./GPT 学习伴侣.app/Contents/MacOS/GPTStudyCompanion" --self-test -ApplePersistenceIgnoreState YES
```

跨进程阅读恢复与登录数据持久化：

```bash
"./GPT 学习伴侣.app/Contents/MacOS/GPTStudyCompanion" --test-reading-write -ApplePersistenceIgnoreState YES
"./GPT 学习伴侣.app/Contents/MacOS/GPTStudyCompanion" --test-reading-read -ApplePersistenceIgnoreState YES
"./GPT 学习伴侣.app/Contents/MacOS/GPTStudyCompanion" --test-session-write -ApplePersistenceIgnoreState YES
"./GPT 学习伴侣.app/Contents/MacOS/GPTStudyCompanion" --test-session-read -ApplePersistenceIgnoreState YES
```

上述测试用专用临时文档和测试设置，不改写个人笔记，也不上传测试文档。Mac 的阅读示例截图输出为 `output/reader-preview.png`。

真实 ChatGPT 网页输入框的只读检查：

```bash
"./GPT 学习伴侣.app/Contents/MacOS/GPTStudyCompanion" --inspect-chat-composer -ApplePersistenceIgnoreState YES
```

## 已知边界与审阅

网页输入框、附件入口以及部分登录流程依赖 ChatGPT 当前界面，不是官方稳定 API；网页更新后可能需要调整。文件上传仍受账号能力、额度和网络状态约束，工具显示附件已加入不等于服务器已处理成功。

运行时依赖审计无已知漏洞。打包工具的开发依赖目前保留 8 项 moderate 告警，来源与处理说明见 [REVIEW.md](REVIEW.md)。未强行降级到带有更严重问题的旧工具版本。

项目审阅与修复记录见 [REVIEW.md](REVIEW.md)，第三方组件许可证说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。项目源码未授予开源许可（`UNLICENSED`）。
