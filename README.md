# CodeApp

一个非常轻量的远程开发客户端，Windows / macOS / iPhone 一套代码（Flutter）。
所有计算都在你的云端服务器上，客户端只是一个通过 SSH 连过去的 UI。

功能：

- **SSH 主机管理**：保存多台服务器，私钥/密码存在系统钥匙串里，首次连接确认主机指纹。
- **文件与编辑器**：通过 SFTP 浏览、新建、重命名、删除、编辑文件，带语法高亮，Ctrl/Cmd+S 保存。
- **终端**：完整的 xterm 终端，手机上有 Esc / Tab / Ctrl / 方向键等辅助按键。
- **Claude Code**：在服务器上以无头模式运行 `claude`，用你自己的订阅登录。
  聊天界面渲染 Markdown、工具调用卡片，工具权限弹出 允许 / 拒绝 按钮。
  可以列出、恢复、删除该目录下的历史 session。
- **端口转发**：自动发现服务器上新监听的端口并转发到本机（像 VS Code 一样），
  iPhone / Mac 上可以直接在应用内打开预览。

## 服务器端要求

只需要一台能 SSH 上去的 Linux 机器，并且装好了 Claude Code：

```bash
npm install -g @anthropic-ai/claude-code
claude   # 第一次运行按提示用订阅账号登录
```

登录一次之后，客户端就能直接用了，不需要在服务器上部署别的东西。

## 打包

推到 GitHub 后，Actions 会自动构建：

| 平台 | 产物 | 说明 |
| --- | --- | --- |
| Windows | `CodeApp-windows-x64.zip` | 解压运行 `codeapp.exe` |
| macOS | `CodeApp-macos.zip` | 未签名。首次打开右键 → 打开，或 `xattr -dr com.apple.quarantine codeapp.app` |
| iOS | `CodeApp-ios-unsigned.ipa` | 未签名，需要用你的 Apple 开发者账号签名后安装（Xcode / Sideloadly / AltStore） |

打一个 `v*` 标签（例如 `git tag v0.1.0 && git push --tags`）会自动创建 GitHub Release 并附上三个产物。

## 本地开发

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d macos      # 或 windows / linux / 你的 iPhone
```

## 代码结构

```
lib/
  core/
    models/host.dart          主机配置模型
    storage/host_store.dart   主机列表 JSON + 钥匙串密钥 + known_hosts
    ssh/ssh_connection.dart   一条 SSH 连接：exec / shell / sftp
    ssh/port_forwarder.dart   本地端口转发 + 自动发现
    claude/claude_protocol.dart  stream-json 协议模型
    claude/claude_chat.dart      驱动 claude -p 进程，权限确认
    claude/session_index.dart    读取 ~/.claude/projects 里的 session
    workspace_session.dart    一个已连接工作区的所有状态
  features/
    hosts/      主机列表、编辑表单、连接流程
    workspace/  主界面（宽屏三栏 / 手机底部导航）
    files/      SFTP 文件浏览器
    editor/     多标签编辑器
    terminal/   终端
    claude/     Claude 聊天面板 + session 列表
    ports/      端口面板 + 应用内预览
```
