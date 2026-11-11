# AgentScope 登录项采集与应用聚合设计

日期：2026-08-05  
状态：已确认

## 1. 背景与目标

当前登录项采集器在 App 启动时执行 `/usr/bin/sfltool dumpbtm`。该命令是 macOS 的诊断工具，不适合作为普通 App 的常规数据源，会导致授权提示、启动变慢，并且在 macOS 测试版上容易出现超时或失败。

腾讯柠檬的开源 `QMAppLoginItemManage` 模块采用传统 `LSSharedFileList` 读取用户登录项，并把登录项、LaunchAgent/LaunchDaemon 和 App 内置 LoginItems 分开管理。本设计采用同样的分层方式，并保留现代 macOS 的能力边界：不伪装存在一个公开 API 可以枚举所有新式 Background Items。

目标：

- 启动时不调用 `sfltool`，不因登录项扫描弹出授权。
- 使用 `LSSharedFileList` 读取用户可见的传统登录项。
- 继续把用户 LaunchAgent、定时任务和开发生态作为独立来源。
- 登录项列表按应用聚合，采用已确认的方案 A；展开后显示具体条目详情。
- 显示应用启用状态、项目归属、条目数量、路径、触发方式和审计结果。

## 2. 数据源边界

### 2.1 传统用户登录项

`LoginItemCollector` 改为使用原生 `SharedFileListLoginItemReader`，通过 CoreServices 的共享文件列表 API 读取：

```objc
LSSharedFileListCreate(NULL, kLSSharedFileListSessionLoginItems, NULL)
LSSharedFileListCopySnapshot(loginItems, &seed)
LSSharedFileListItemResolve(item, 0, &url, NULL)
```

Swift 通过 CoreServices/相关系统框架桥接这些 API。每条解析成 `ServiceItem`，来源类型仍为 `.loginItem`，作用域为 `.user`，状态默认为已启用，启用证据标记为 `LSSharedFileList`。

如果共享文件列表 API 返回空或不可用，采集器返回空登录项和明确的“传统登录项不可用”诊断，不调用 `sfltool` 作为自动 fallback。

### 2.2 LaunchAgent 与 LaunchDaemon

沿用现有 Launchd 采集器。用户 `~/Library/LaunchAgents` 属于“自动启动项”，不再进入“登录项”分组。生产清单仍不加载系统 LaunchDaemon。

### 2.3 App 内置 LoginItems 与现代 Background Items

不在普通启动扫描中读取 BTM 数据库，也不通过私有框架模拟系统设置。`SMAppService` 仅用于未来识别 AgentScope 自己注册的服务，不作为全局枚举器。

现代后台项若无法从公开来源确认，显示为未知或不列入普通登录项，不将推断结果标记为已启用。

## 3. 应用聚合模型

新增 UI 层聚合模型，避免改变底层 `ServiceItem` 的来源语义：

```swift
struct LoginItemApplicationGroup: Identifiable, Hashable {
    let id: String
    let applicationName: String
    let applicationPath: String?
    let bundleIdentifier: String?
    let project: ProjectIdentity?
    let enabled: Bool?
    let items: [ServiceItem]
}
```

聚合键优先级：

1. 可解析应用 Bundle ID。
2. 标准化 `.app` 路径。
3. 登录项稳定 ID。

同一应用的多个辅助项显示为一个应用行，展开后显示每个具体 Login Item。无法解析应用的条目仍保留，以“未知应用”分组，不丢数据。

## 4. 界面设计：方案 A

登录项列表使用表格化应用行：

- 应用图标和名称。
- 启用状态：已启用、已禁用、未知。
- 项目归属：项目名或“未识别”。
- 条目数量。
- 展开箭头。

展开后显示明细行：

- 具体 Login Item 名称。
- `Login Item · 用户` 来源标签。
- 项目归属。
- 用户登录时启动。
- 应用路径、辅助程序路径和 Bundle ID。
- 只读标记、规则审计结果和 AI 分析入口。

应用行和明细行使用不同层级的字号与背景，避免把多个辅助项看成多个独立应用。默认只展开用户当前点击的应用组。

## 5. 启动与刷新行为

- App 启动时只扫描不需要额外授权的来源。
- 登录项 collector 通过 `LSSharedFileList` 同步参与第一次扫描。
- 刷新时重新读取共享文件列表，并保持当前应用组展开状态；如果组消失则清除选择。
- 不再显示 `sfltool` 超时、权限或授权错误。
- 如果系统 API 不可用，警告只出现在“登录项”分类的空状态中，不阻塞其他来源。

## 6. 测试策略

先写测试再改生产代码，覆盖：

- 共享文件列表解析多个登录项。
- 同一应用多个辅助项按 Bundle ID 或标准化路径聚合。
- 不同应用不会错误合并。
- 缺失应用路径时保留“未知应用”条目。
- 登录项不再调用 `sfltool` 命令执行器。
- LaunchAgent 和 Login Item 仍保持不同来源分类。
- 应用组启用状态为全组一致时显示启用，不一致时显示“部分启用”，未知时显示未知。
- 方案 A 的列表计数为应用组数量，展开计数为组内条目数量。

测试通过注入的命令执行器或原生数据适配器完成，不依赖真实系统登录项数据库。SwiftUI target 通过编译验证，完整测试仍需通过。

## 7. 不在本次范围内

- 修改其他 App 的现代 Background Item 状态。
- 调用私有框架或安装特权辅助工具。
- 通过 `sudo`、AppleScript 或 System Events 绕过系统授权。
- 对现代 BTM 数据库做未经公开 API 支持的直接解析。
- 登录项的批量启用/禁用；本次先保证读取、分组和审计准确。

## 8. 验收标准

- App 启动不再弹出 `sfltool` 授权。
- 登录项来源不调用 `/usr/bin/sfltool`。
- 登录项列表按应用聚合，视觉上接近腾讯柠檬参考图。
- 应用行能看到项目归属、启用状态和条目数量。
- 展开后能看到具体 Login Item 的路径、来源、项目和审计信息。
- 自动启动项、定时任务和登录项在来源上不重复冒充。
- 全量测试和 App 构建通过。
