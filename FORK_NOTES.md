# BeanPod 改造说明

本仓库由 [cclank](https://github.com/cclank) 维护，fork 自 [andyhuo520/beanpod](https://github.com/andyhuo520/beanpod)，保留上游历史、MIT LICENSE 和第三方 NOTICE。

## 开发主线

- 自有仓库：`https://github.com/cclank/beanpod`
- 开发分支：`main`
- `origin` 指向自有仓库，默认推送到这里。
- `upstream` 指向原项目，便于按需比较和合并上游更新。
- 2026-11-27 建立改造基线，包含上游 `0e883bbe9daff0c1f13ea6ad4e3165ea2b2fc734` 的人物、标签换行修复。

## 已有改造

1. **HTTP MCP 加固**：绑定 IPv4 loopback，要求本机随机 Bearer 凭证，校验 Host，拒绝 Origin 和浏览器 Fetch Metadata 请求头，移除开放 CORS；限制请求路径、类型、大小和接收超时。原有 stdio MCP 接入保留。
2. **移除刘海功能**：删除浮层和动画实现、启动挂载、开关、预览菜单及相关文案。
3. **自定义语音输入快捷键**：支持普通键、F 键、方向键、数字键盘和修饰键组合；录制后持久保存；处理自动重复与松键结束，并拦截触发字符。旧的单修饰键配置继续有效。

## 本机验证与边界

- CLI 可通过 `swift build --product beanpod` 构建。
- HTTP 回归覆盖 8 组检查；快捷键状态与录制覆盖 30 项行为检查。
- 设置界面实际录制 F8 和 `⌃⌥K` 已验证。跨应用快捷键需要 macOS 辅助功能授权，完整跨应用实机验证仍待授权后完成。
- 本机曾安装并校验 Qwen3-ASR 0.6B、Qwen3-4B 模型，用一条设备录音跑通过转写和纪要。模型权重、用户录音、MCP 凭证属于运行时数据，不纳入仓库。
- 原有 BeanKit 协议单测需要 Swift Testing；仅有 Command Line Tools 的本机环境此前缺少该模块。完整 App 的标准构建方式仍见 README。
- 上游 DMG 不含本仓库的改造；当前没有发布本 fork 的独立安装包。

在仓库根目录运行回归检查：

```bash
swift build --product beanpod
python3 Tests/HTTPMCP/test_http_mcp.py
swiftc -swift-version 6 -default-isolation MainActor -target arm64-apple-macos26.0 \
  App/DictationShortcut.swift Tests/DictationShortcut/main.swift \
  -o /tmp/beanpod-shortcut-tests
/tmp/beanpod-shortcut-tests
```

HTTP 测试使用隔离的临时 macOS 配置目录。测试不会读取或写入真实录音库。
