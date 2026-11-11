# macOS Agent & Service Manager 设计稿

日期：2026-08-02
状态：第一版设计，已确认产品边界

## 1. 产品定位

一个本地优先的 macOS 后台服务控制台，帮助 AI 开发者发现、理解和管理 LaunchAgent、LaunchDaemon、Login Item 以及临时运行的 Python、Node、Shell 和 MCP 服务。

第一版重点是安全的运行管理，而不是自动清理或安全软件替代品。

## 2. 已确认范围

### 纳入范围

- 完整管理用户自己的 LaunchAgent。
- 发现并解释用户自己的 LaunchAgent、Login Item、cron、Shell 启动和开发生态来源。
- 系统级 LaunchAgent、LaunchDaemon、periodic 和系统只读条目不进入生产库存。
- 展示启动配置、当前状态、日志、运行历史和有效性检查。
- 使用本地确定性规则解释配置、依赖、风险和可能的过期原因；AI 接口保留为后续显式配置项。

### 暂不纳入

- 自动删除服务或脚本。
- 自动修改系统服务。
- 自动终止 root 进程。
- 未经确认将普通脚本转换为持久化 LaunchAgent。
- 自动运行未知代码进行“测试”。
- 把 AI 判断作为安全结论。

## 3. 核心概念

每个条目拆成两个维度：

- 来源：LaunchAgent、LaunchDaemon、Login Item、cron、periodic、Shell 启动和生态适配器。
- 状态：已发现、已启用、运行中、已停止、已禁用、失败、失效、无权限、系统只读。

“停止当前运行实例”和“禁用后续自动启动”必须是两个独立操作。

## 4. 数据采集层

### 静态来源

- `~/Library/LaunchAgents`
- 系统级 Launchd 目录不在生产扫描范围内。
- macOS Background Task / Login Item 状态
- 用户 crontab 和常见 shell 启动文件

### 运行时来源

- `launchctl` 当前 job 状态
- 进程 PID、父子关系、命令行和工作目录
- CPU、内存、监听端口和网络连接
- stdout/stderr 及相关系统日志
- 进程启动、退出和退出码事件

### 代码和归属来源

- 目标文件存在性、所有者、权限和修改时间
- Apple/Developer ID 签名及哈希
- Git 仓库、最近提交、项目路径和当前用户关联
- Python 虚拟环境、Node 模块和外部命令依赖
- plist 中的 `Program`、`ProgramArguments`、`KeepAlive`、`RunAtLoad`、`StartInterval` 和日历计划

## 5. 运行管理能力

### 用户 LaunchAgent

- 启动现在
- 停止当前实例
- 重启
- 启用自动启动
- 禁用自动启动
- 测试运行
- 查看并编辑配置
- 查看日志
- 打开配置文件和目标目录
- 修改前备份，支持恢复

使用现代 `launchctl` 操作，并在执行后重新读取状态验证结果。

### 系统服务

- 默认只读查看。
- 可以展示运行状态、PID、退出码、签名、来源和日志。
- 涉及停止或管理员权限时必须单独确认。
- 不提供删除和编辑系统 plist 的入口。

### 手动启动进程

- 显示命令、PID、父进程、工作目录、端口和启动时间。
- 支持停止进程组和重启当前实例。
- 明确标记“未发现持久化启动来源”。
- 后续可提供“纳入托管”，由用户确认生成 LaunchAgent。

## 6. 有效性判断

有效性由确定性检测和 AI 解释共同完成。

确定性检测包括：

- plist、脚本、解释器和配置文件是否存在。
- Python、Node 和外部命令依赖是否存在。
- 路径是否仍位于有效项目或 App 内。
- 最近退出码和连续失败次数。
- 计划触发时间是否符合实际运行记录。
- 服务是否仍监听端口或被其他程序引用。

不能简单以“长期未运行”判断无用。按需服务、定时任务和 KeepAlive 服务必须使用不同规则。

建议输出：保留、可能过期、已失效、运行异常、用途不明，并同时展示证据和置信度。

## 7. AI 分析层

AI 输入应是经过脱敏的结构化信息和必要的代码片段，而不是完整环境变量或密钥文件。

AI 输出固定为结构化结果：

- 功能摘要
- 启动方式
- 输入、输出和依赖
- 文件、网络和子进程行为
- 可能的项目归属
- 是否仍有用的推测
- 风险提示
- 置信度
- 推荐动作

AI 可以生成待确认的操作计划，例如“停止并禁用这个服务”，但不得绕过用户确认执行停止、删除、提权或持久化注册。

首选本地分析；云端模型必须显式开启，并在上传前隐藏 Token、Cookie、Authorization、私钥和 `.env` 内容。

## 8. 安全和可恢复性

- 默认进入只读模式。
- 用户操作前展示影响范围、权限和目标路径。
- 修改 plist 或 cron 前创建带时间戳的本地备份。
- 禁用优先于删除，所有修改提供撤销入口。
- root 操作使用系统授权，不保存管理员凭据。
- 不自动执行未知脚本。
- 记录操作人、时间、原配置、目标服务和执行结果。
- 系统签名项目默认标记为只读或高保护。

## 9. 推荐技术分层

1. Native macOS Collector：Swift，负责 Service Management、进程、签名、日志和权限。
2. Service Controller：封装 `launchctl`、`SMAppService` 和进程组信号操作。
3. Local Store：保存服务快照、状态变化、运行历史、备份和 AI 分析结果。
4. Analysis Engine：确定性规则、代码特征提取和可选本地/云端 LLM。
5. SwiftUI UI：服务列表、详情页、日志页、操作确认和历史时间线。

第一版建议使用原生 SwiftUI，而不是先引入 Tauri；系统服务、权限和进程管理是核心能力，原生 API 更容易控制权限边界。

## 10. 第一版验收标准

- 能列出用户 LaunchAgent，并准确显示启用和运行状态。
- 能安全完成启动、停止、重启、启用和禁用，并验证结果。
- 能发现当前运行但没有持久化来源的 Python/Node/Shell 进程。
- 能停止和重启一个手动启动的进程组。
- 能发现目标文件或依赖已失效的服务。
- 能保存运行历史和操作记录。
- 系统服务不能被普通操作误修改。
- AI 解释必须附带证据和置信度，不能只给出无依据的安全结论。

## 11. 后续阶段

第一阶段：用户 LaunchAgent 管理、进程发现、日志和有效性检查。

第二阶段：运行事件历史、cron/periodic、Login Item 深度关联、进程组管理。

第三阶段：代码 AI 分析、本地模型、纳入托管、配置修复和自然语言操作。

参考：

- Apple Service Management：<https://developer.apple.com/documentation/servicemanagement/smappservice>
- Apple Endpoint Security：<https://developer.apple.com/documentation/endpointsecurity>
- launchd-ui：<https://github.com/azu/launchd-ui>
- KnockKnock：<https://github.com/objective-see/KnockKnock>

## 12. 外部方案评审与吸收决策

参考方案：`~/.claude/plans/macos-app-macos-agent-ai-python-app-mac-curried-haven.md`。

### 直接吸收

#### Collector + Enrich 分层

采集器按来源拆分，每个采集器负责发现一种数据源；富化管线统一处理签名、归属、风险、依赖和运行状态。单个来源失败时应降级并继续完成其他来源扫描。

建议的采集器包括：

- launchd
- Login Item / Background Task
- cron / periodic
- shell 启动文件
- Homebrew services
- Docker
- tmux
- 当前进程

其中 Homebrew、Docker 和 tmux 作为后续适配器，不阻塞第一版核心能力。

#### 统一 ServiceItem 模型

所有来源统一成同一种服务条目模型，至少包含：

- 稳定 ID、名称、来源类型和作用域
- 配置路径、程序路径、解释器和参数
- 当前运行状态、PID、启动时间和退出码
- 最近运行时间及其精度
- 启用/禁用状态
- 签名、归属、风险和失效原因
- AI 解释及其来源

这样列表、详情、筛选、历史和管理操作不需要感知底层来源差异。

#### 最近运行时间的精度标注

界面不能把推测时间伪装成精确时间，增加以下精度类型：

- `Exact`：当前进程的实际启动时间或可确认的运行事件
- `Approximate`：日志修改时间、会话创建时间等间接证据
- `Unknown`：只有配置，没有可靠运行记录

详情页应显示“最近运行：约 3 天前”或“最近运行时间未知”，并提供推断来源。

#### AI 三级解释管线

采用以下顺序：

1. 内置规则库优先识别常见工具和服务。
2. 使用本地数据库缓存分析结果。
3. 规则无法判断时，再调用本地或云端 LLM。

缓存键由目标路径、修改时间和配置内容哈希组成。代码或配置未变化时不重复调用模型。云端分析需要脱敏、可取消，并限制并发和单次上下文大小。

#### 外部命令的可靠性约束

所有 `launchctl`、`docker`、`brew` 等外部命令都要：

- 使用显式候选路径探测，不能依赖 Finder 启动时的精简 PATH。
- 设置超时。
- 区分命令失败、超时、权限不足和工具不存在。
- 记录可展示给用户的错误原因，但不记录环境变量和密钥。

### 需要改造后吸收

#### 全来源扫描作为路线图，而非第一版硬目标

shell rc、cron、Docker 和 tmux 值得发现，但它们不一定都是“服务”。产品中应标记为“启动来源”或“运行环境”，避免强行使用启用/禁用/重启等不适合的服务操作。

#### 归属判断使用证据评分

路径规则可以作为线索，但不能直接断言“这是用户写的”。归属结果必须同时展示依据，例如 Git 仓库、当前用户、签名、路径、安装来源和最近修改者，并标注置信度。

#### 风险判断保留可解释标记

风险由具体标记组成，例如未签名、root 权限、KeepAlive、写入用户目录之外、目标路径异常、网络监听和依赖缺失。AI 只负责总结这些标记，不直接替代规则引擎。

### 暂不采用

- 第一版不开放删除；采用禁用、备份和恢复流程。
- 第一版不默认引入 Tauri + React。当前优先使用 SwiftUI 和原生系统 API，减少进程、签名、Keychain 和权限边界的复杂度；若后续 UI 迭代速度成为瓶颈，再重新评估 Tauri。
- 第一版不把 Endpoint Security 作为硬依赖。先使用 launchd 状态、进程轮询和可用日志建立基础历史；如果需要准确捕获所有 exec/fork/exit 事件，再增加经过用户批准的 Endpoint Security 扩展。
- Full Disk Access 不作为全局前置条件。各采集器单独报告权限状态并降级，首页只引导用户开启确实需要的权限。

## 13. 2026-08-03 审计优先修订

产品首页不再把当前运行进程作为主要对象，也不扫描并展示数百个系统进程或系统级只读条目。生产库存聚焦于可解释的用户来源：

- 用户 `~/Library/LaunchAgents` 配置，并通过 `launchctl gui/<uid>` 读取状态。
- 用户 crontab 和常见 shell 启动文件。
- Login Items / Background Task、Homebrew services、Docker 容器/Compose 标签和 tmux 会话。

所有来源都以只读审计条目进入统一模型，条目附带触发方式、执行证据、项目归因和确定性规则判断。项目视图按 Git 仓库、App bundle、Homebrew formula、Docker Compose 或 shell 引用聚合；无法可靠归因时显示“未识别”和证据置信度。

规则引擎优先检查配置、目标和解释器是否存在、退出码与连续失败、launchd 失败状态及可验证的执行记录。仅仅“当前已停止”不能判定为无效。可选分析接口默认使用本地规则，云端分析必须显式开启并先脱敏；刷新库存不会自动调用云端模型。

当前生产实现保留用户 LaunchAgent 的启动/停止/重启/启用/禁用/测试操作；系统、定时任务、登录项、Shell、Homebrew、Docker 和 tmux 条目均为只读。

### 新增验证重点

后续实现时增加以下验收：

- 与 `launchctl` 和 LaunchAgents 目录人工对账。
- 同一个服务重复扫描时 ID 和历史保持稳定。
- 没有运行事件时必须显示 `Approximate` 或 `Unknown`，不能伪造时间。
- 规则命中时不调用 LLM；配置未变化时重复扫描不调用 LLM。
- Finder 启动应用时，Homebrew、Docker 和 launchctl 仍能被正确定位或明确显示不可用。
- 任一采集器超时或权限不足时，其他来源仍能完成扫描。
