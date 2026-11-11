# AgentScope 重新梳理：找全后台 / 启动项 + 按用途分类 + 一句话说明

日期：2026-11-10
状态：已实现（版本 0.3.0 build 9，已安装到 /Applications）

## 1. 目标

把 Mac 上后台运行和自动启动的第三方程序**找全**，并**按用途分类、按应用聚合、每项一句话说明**，同时标出卸载残留。

## 2. 范围决策（2026-11-10 用户确认）

| 决策 | 结论 |
|---|---|
| 扫描范围 | 只排除 Apple 自带（`/System` 路径、`com.apple.*` 标识、Apple 签名的非脚本程序），第三方全部加载（0.3.0 起，残留、自建脚本、孤儿特权助手可以卸载，其他仍只读）。修正了 8/3 把「系统的不加载」实现成「只扫 `~/Library`」导致 `/Library` 下第三方项目全部漏掉的问题。 |
| 后台活动（BTM） | 工具栏「深度扫描」按钮手动触发 `sfltool dumpbtm`，macOS 自带授权弹窗；结果缓存到 `~/Library/Application Support/AgentScope/background-tasks.json`，启动时不调用。 |
| 后台运行 | 包含第三方常驻进程：运行中但找不到启动来源的非 Apple 进程；Dock 中打开的前台应用、终端会话及其子进程不计入。 |
| 分类 | 一级按用途（远程控制、网银 / U 盾、自动更新、代理 / VPN、开发工具、同步备份、安全清理、硬件驱动、通讯、办公效率、自建脚本、未识别），同一应用跨来源聚合成一行。 |

## 3. 数据来源

| 来源 | 实现 |
|---|---|
| `~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons` | `LaunchdCollector`；`launchctl print` 与 `print-disabled` 无需 root。读不了的 plist（如卸载后残留的悬空符号链接）作为失效项列出，不再只是警告。 |
| `/Library/PrivilegedHelperTools` | `PrivilegedHelperCollector`：已被 LaunchDaemon 引用的跳过，无引用的标为「孤儿特权助手」。 |
| 系统扩展 | `SystemExtensionCollector` 解析 `systemextensionsctl list`，同一 bundle 多版本合并。 |
| 内核扩展 | `KernelExtensionCollector` 枚举 `/Library/Extensions`，用 `kmutil showloaded` 判断是否已加载。 |
| 登录项 / 应用内置登录项 / cron / Shell / Homebrew / Docker / tmux | 沿用原采集器。内置登录项改为递归扫描 `/Applications` 下的分类子文件夹（不进入 `.app` 包内部），不再扫描 `/System`。periodic 只读 `/usr/local/etc/periodic`（`/etc/periodic` 在当前系统已不存在，且其中都是 Apple 脚本）。 |
| 常驻进程 | `ResidentProcessScanner`：先把进程挂到已知启动项上，剩余的按应用 / 脚本聚合。launchd 项以 `launchctl` 报告的状态为准，进程只更新登录项、内置登录项、后台活动、特权助手这类没有自身状态来源的项目；`/bin/bash`、`/usr/bin/ssh` 这类共用系统工具不参与匹配。路径用 `proc_pidpath`，因为 `ps` 会转义中文路径。 |
| 后台活动（BTM） | `BackgroundTaskScan`：能匹配已有项的只追加「允许在后台」证据，匹配不上的新增为 `.backgroundTask`。 |

## 4. 分类与说明

- 签名：`SecurityCodeSignatureReader` 在进程内用 Security.framework 读取签名，得到 Team ID 和组织名；脚本解释器（zsh / python / open 等）改看其参数中的脚本文件。
- `KnowledgeBase`（Swift 内置表）按标识前缀、Team ID、路径片段匹配，越具体越优先，给出产品名、用途和说明。
- `ItemExplainer`：知识库未命中时走规则。用户作用域、非 Developer ID 签名的 LaunchAgent / 进程 / cron 视为自建脚本，说明中显示实际命令。
- 所属应用是否还在：先看程序路径所在的 `.app`，再用知识库中的 bundle id 查 `NSWorkspace`。不在的进入「需要关注」，并标「疑似残留」。
- AI：工具栏「AI 解释」先弹窗说明发送目标、条目数和其中的自建脚本数，确认后逐个解释只有规则说明的项目，过程中可随时停止；结果写入 `LocalStore`，刷新后保留。未配置 AI 时按钮禁用，不报错。

## 5. 与计划的偏差

- 知识库用 Swift 字面量，没有用 JSON 资源，以获得编译期类型检查，也省去资源加载代码。
- 三个系统级采集器合并在 `SystemLevelCollectors.swift` 一个文件中。
- AI 只补全说明，不补全用途分类（需要改动提示词和 JSON 协议，留待后续）。
- AI 缓存按条目 ID 存最新结果，没有按「路径 + 修改时间 + 配置哈希」失效。

## 6. 验证（开发机实测）

- 各来源逐一与磁盘目录或系统命令输出核对数量：`~/Library/LaunchAgents`、`/Library/LaunchAgents`、`/Library/LaunchDaemons`（含悬空链接，标为失效）、无 daemon 引用的孤儿特权助手、系统扩展、第三方 kext（排除 Apple 自带）、应用内置登录项（排除不属于任何 App 的杂散目录），数量全部一致。
- 「需要关注」的残留组都用 `find /Applications ~/Applications -maxdepth 4` 按名称核对过，确认所属应用确实不在。核对中发现并修正了知识库里一个写错的 bundle id。
- 开发机上约 90% 的第三方项由知识库给出说明，自建脚本和定时任务显示实际命令，剩下少数未识别项可用 AI 解释补全。
- 本机清单探针默认跳过，需设置 `TEST_RUNNER_AGENTSCOPE_LIVE=1` 才运行。
- 启动后进程中没有 `sfltool`。正常退出后再启动，主窗口正常打开；只有用 `pkill` 强制结束后再启动，macOS 恢复窗口状态时才会不开窗口，需要再点一次 Dock 图标。
- 知识库的「所属应用」判断依赖 bundle id，若知识库条目写错 ID，可能误报残留。

## 7. 深度扫描与腾讯柠檬清理对照（2026-11-11）

- 深度扫描：真实 `sfltool dumpbtm` 的记录全部挂到已有项上，没有多出孤立项。
- 修了两个问题：
  - 合并时按「标识或路径」取第一个匹配，多个共用 `/usr/bin/ssh`、`/bin/bash` 的项会抢同一条记录。改为先按标识匹配，再按路径匹配，且 `/bin`、`/usr/bin` 等系统共用程序不参与路径匹配。
  - 系统设置里关掉的项原来只加一条提示证据，状态仍是「已停止」。现在改为「已禁用」，正在运行的项不受影响；同一项有多条记录、其中任意一条是允许的，就不改。
- 与柠檬清理「启动项」对照：
  - 登录项完全一致。
  - 启动配置：柠檬列出的全部在 AgentScope 中。柠檬没列出的有：柠檬自己的配置（自我过滤）、部分厂商的自动更新助手、已卸载应用的残留、悬空链接。
  - 柠檬不覆盖、AgentScope 覆盖的：已注册的 App 内置登录项、特权助手、系统扩展、内核扩展、cron、Homebrew、Docker 容器、常驻进程。
  - 状态差异：同一项在深度扫描里同时有允许和关闭的记录时，柠檬显示禁用，AgentScope 显示已停止。

## 8. 0.3.0：卸载、运行时间、2 倍窗口、多 AI 服务商、图标（2026-11-11）

- **卸载范围**：只对三类项目开放：残留（所属应用已不在、配置失效、目标缺失）、自建脚本、孤儿特权助手。运行失败但应用还在的项目（例如运行失败的 CI runner）不开放，应该修复而不是删除。
- **不动的文件**：系统和包管理器路径、仍安装的 `.app` 内的文件、仍被其他项使用的程序（例如两个启动配置共用的守护程序），都在对话框里写明原因。程序文件只在所属应用已不在时才删。
- **默认不勾选**：自建脚本的脚本文件、内核扩展。
- **执行**：
  - 先 `launchctl bootout`，再移到废纸篓。
  - 是否需要管理员按文件实际能否删除判断（`isDeletableFile`），不按路径前缀。
  - 需要 root 的文件合成一次 `osascript … with administrator privileges`：root 把文件移到 `~/Library/Application Support/AgentScope/Uninstall-staging/` 并 `chown` 给用户，再由 App 自己放进废纸篓。root 直接写 `~/.Trash` 可能被 macOS 隐私保护拒绝，所以绕一步。
  - 取消密码框时不做任何改动。
  - 完成后的提示列出每个文件的原位置，供恢复时参考。
- **cron**：
  - 先备份到 `Backups/crontab-<时间>.txt`，再删除对应行。
  - `crontab` 会截断约 100 字符以上的文件路径，所以新的 crontab 写到 `/tmp` 下的短路径（权限 600）。
  - 首次修改时 macOS 会弹「管理你的电脑」授权，超时设为 120 秒。
  - 失败只记入报告，不影响已完成的步骤。
- **系统扩展**：开启 SIP 时无法直接删除，只给出处理说明。
- **深度扫描缓存**：卸载后删掉对应记录；plist 已不存在的缓存记录也会被跳过。
- **确认按钮**：卸载按钮没有回车快捷键，必须用鼠标点。
- **运行时间**：
  - 下次运行：`StartCalendarInterval` 和 cron 用 `ScheduleCalculator` 精确计算；`StartInterval` 按「上次运行 + 间隔」估算，标「预计」。
  - 上次运行：取 `StandardOutPath` / `StandardErrorPath` 的修改时间，标「约」。
  - 运行次数：取 `launchctl print` 的 `runs`。
  - 「查询系统日志」只在点击时运行。查询范围是 2 倍运行间隔（至少 1 小时，日历任务查 24 小时），实测查 24 小时约 52 秒。
- **2 倍窗口**：`UIScale.factor = 2` 统一控制窗口和控件尺寸，字号和图标不变。窗口默认 1800×1200，受屏幕大小限制。`WindowGroup` 的 id 改为 `main-2x`，避免旧版本保存的窗口尺寸覆盖新默认值。
- **AI**：
  - 预置 Claude、ChatGPT、DeepSeek、Gemini、通义千问、Kimi、智谱、OpenRouter、Ollama 和自定义。
  - Key 按服务商分别存钥匙串（`api-key.<服务商>`），旧的 `api-key` 启动时自动迁移。
  - Claude 走原生 Messages API（`x-api-key`、`anthropic-version: 2026-10-21`）。直连 `api.anthropic.com` 时开启服务端 `fallbacks: "default"`（beta `server-side-fallback-2026-07-01`），被安全分类器拒绝时自动换模型重试。
  - 「测试连接」使用表单中未保存的值，任何 2xx 都算成功，错误信息里会去掉 key。
  - 除 Claude 外，各服务商的默认模型名是未经验证的建议，可以修改。
- **图标**：用 CoreGraphics 脚本绘制，导出全部尺寸放进 `Assets.xcassets/AppIcon`。
- **验证**：
  - XCTest 全部通过，另有 3 个本机测试默认跳过（清单探针、卸载自测、AI 联网）。
  - 引号转义：一个含空格、中文和引号的路径经 osascript（不带管理员参数）执行后移动正确。
  - 卸载自测：临时 LaunchAgent 被识别为自建脚本，上次 / 下次运行和运行次数正确；卸载后进了废纸篓、任务已卸载，`/bin/echo` 被保留。
  - AI：用无效 key 测试，Claude 和 DeepSeek 都返回 401，提示里不含 key。
  - 真实的残留和脚本只打开确认对话框后取消，没有执行卸载。
  - 未验证：管理员密码路径（需要用户输入密码）、cron 真机删除（需要 macOS 授权）。
