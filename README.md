# AgentScope

AgentScope 是一个本地优先的 macOS 后台程序审计工具：把本机后台运行和自动启动的第三方程序全部找出来（LaunchAgent / LaunchDaemon、登录项、特权助手、系统与内核扩展、定时任务、常驻进程、系统设置「允许在后台」列表），按用途分类、按应用聚合，每项附一句话说明，并标出卸载残留。Apple 自带项目不显示。

0.3.0 起：残留和自建脚本可以卸载（先停止服务，再把文件移到废纸篓；系统目录的文件弹一次管理员密码框）；定时脚本显示上次和下次运行时间；AI 支持 Claude、ChatGPT、DeepSeek 等常用服务商，Key 按服务商存入钥匙串，可以测试连接。其他第三方项目仍然只读。

## 功能

- **找全**：用户 / 系统 LaunchAgent、LaunchDaemon、登录项、应用内置登录项、特权助手、系统扩展、内核扩展、cron、Shell 启动项、Homebrew、Docker、tmux、常驻进程，以及系统设置「允许在后台」列表（深度扫描）。
- **说明**：按用途分类、按应用聚合，内置知识库给出一句话说明；未知项可以用 AI 解释（结果为中文）。
- **残留**：所属应用已不在、配置失效、目标缺失的项单独标出，可以卸载。卸载先停止服务，再把文件移到废纸篓，可以恢复。
- **运行时间**：显示定时脚本的上次运行、下次运行和运行次数。
- **AI**：支持 Claude、ChatGPT、DeepSeek、Gemini、通义千问、Kimi、智谱、OpenRouter、Ollama 和自定义接口。Key 存在 macOS 钥匙串里；发送前会脱敏，并限制配置和源码的大小。

## 构建

需要 macOS 13 以上和 Xcode 16 以上。

```bash
cd AgentScope
xcodebuild test -project AgentScope.xcodeproj -scheme AgentScope -destination 'platform=macOS'
xcodebuild -project AgentScope.xcodeproj -scheme AgentScope -configuration Release -derivedDataPath build build
open build/Build/Products/Release/AgentScope.app
```

本机相关的测试默认跳过，设置对应的 `TEST_RUNNER_AGENTSCOPE_*` 环境变量后才运行，见 `AgentScopeTests/LiveInventoryProbeTests.swift`。

## 文档

- [最新设计：找全后台项 + 分类说明（2026-11-10）](docs/superpowers/specs/2026-11-10-background-inventory-design.md)
- [原始产品与技术设计稿](docs/2026-08-02-macos-agent-service-manager-design.md)

## 许可证

[GPL-3.0](LICENSE)
