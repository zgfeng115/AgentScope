import Foundation

public enum SourceFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case projects
    case automaticStartup
    case scheduledTasks
    case loginItems
    case shellStartup
    case ecosystems
    case attention
    case extensions
    // Kept for compatibility with older saved UI state and tests.
    case launchAgents
    case processes
    case systemReadonly

    public static var allCases: [SourceFilter] {
        [.all, .projects, .automaticStartup, .scheduledTasks, .loginItems, .shellStartup, .ecosystems, .attention]
    }

    /// Sidebar "按启动方式" section.
    public static var mechanismFilters: [SourceFilter] {
        [.loginItems, .automaticStartup, .extensions, .scheduledTasks, .processes, .ecosystems, .shellStartup, .projects]
    }

    /// Filters whose list is shown as one row per app / vendor.
    public var showsVendorGroups: Bool {
        [.all, .attention, .processes, .extensions].contains(self)
    }
}

public enum SidebarItem: Hashable, Sendable {
    case source(SourceFilter)
    case purpose(PurposeCategory)
}

public enum ServiceSort: String, CaseIterable, Hashable, Sendable {
    case name
    case source
    case state
}

public enum DashboardLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case partiallyFailed
    case failed(String)
}

public enum LoginItemEnabledState: Hashable, Sendable {
    case enabled
    case disabled
    case partiallyEnabled
    case unknown

    public var displayName: String {
        switch self {
        case .enabled: return "已启用"
        case .disabled: return "已禁用"
        case .partiallyEnabled: return "部分启用"
        case .unknown: return "未知"
        }
    }
}

public struct LoginItemApplicationGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let applicationName: String
    public let applicationPath: String?
    public let bundleIdentifier: String?
    public let project: ProjectIdentity?
    public let enabledState: LoginItemEnabledState
    public let items: [ServiceItem]

    public init(
        id: String,
        applicationName: String,
        applicationPath: String? = nil,
        bundleIdentifier: String? = nil,
        project: ProjectIdentity? = nil,
        enabledState: LoginItemEnabledState,
        items: [ServiceItem]
    ) {
        self.id = id
        self.applicationName = applicationName
        self.applicationPath = applicationPath
        self.bundleIdentifier = bundleIdentifier
        self.project = project
        self.enabledState = enabledState
        self.items = items
    }
}

public protocol OperationHistoryProviding: Sendable {
    func fetchOperationRecords(serviceID: String?) throws -> [OperationRecord]
}

extension LocalStore: OperationHistoryProviding {}
extension LocalStore: OperationRecording {}

public protocol OperationRecording: Sendable {
    func record(_ record: OperationRecord) throws
}
extension LocalStore: AnalysisResultStoring {}

public extension SourceFilter {
    var displayName: String {
        switch self {
        case .all: return "全部"
        case .projects: return "项目视图"
        case .automaticStartup: return "自动启动项"
        case .scheduledTasks: return "定时任务"
        case .loginItems: return "启动项总览"
        case .shellStartup: return "Shell 启动"
        case .ecosystems: return "开发生态"
        case .attention: return "需要关注"
        case .extensions: return "驱动与扩展"
        case .launchAgents: return "用户 LaunchAgent"
        case .processes: return "常驻进程"
        case .systemReadonly: return "系统只读"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .projects: return "folder"
        case .automaticStartup: return "bolt.circle"
        case .scheduledTasks: return "calendar.badge.clock"
        case .loginItems: return "rectangle.3.group"
        case .shellStartup: return "terminal"
        case .ecosystems: return "shippingbox"
        case .attention: return "exclamationmark.triangle"
        case .extensions: return "puzzlepiece.extension"
        case .launchAgents: return "person.crop.square"
        case .processes: return "cpu"
        case .systemReadonly: return "lock.shield"
        }
    }

    var coverageDescription: String? {
        switch self {
        case .loginItems:
            return "当前读取传统 Login Item、LaunchAgent、App 内置 LoginItem；系统设置中的「允许在后台」列表需点击工具栏「深度扫描」读取。"
        case .processes:
            return "正在运行、但找不到对应启动项的第三方后台进程（菜单栏工具、手动启动的脚本等）；已在 Dock 中打开的前台应用不计入。"
        case .extensions:
            return "第三方特权助手、系统扩展和内核扩展；Apple 自带的不显示。"
        default:
            return nil
        }
    }
}

public extension ServiceSort {
    var displayName: String {
        switch self {
        case .name: return "名称"
        case .source: return "来源"
        case .state: return "状态"
        }
    }
}

public extension SourceType {
    var displayName: String {
        switch self {
        case .launchAgent: return "LaunchAgent"
        case .launchDaemon: return "LaunchDaemon"
        case .loginItem: return "传统 Login Item"
        case .embeddedLoginItem: return "App 内置 LoginItem"
        case .cron: return "cron"
        case .periodic: return "periodic"
        case .shellStartup: return "Shell 启动"
        case .homebrew: return "Homebrew"
        case .docker: return "Docker"
        case .tmux: return "tmux"
        case .process: return "常驻进程"
        case .privilegedHelper: return "特权助手"
        case .systemExtension: return "系统扩展"
        case .kernelExtension: return "内核扩展"
        case .backgroundTask: return "后台活动"
        case .unknown: return "未知来源"
        }
    }
}

public extension ServiceItem {
    var isReadOnlyInStartupOverview: Bool {
        scope != .user || sourceType != .launchAgent
    }

    var startupOverviewAccessDisplayName: String {
        if !isReadOnlyInStartupOverview {
            return scope.displayName
        }
        return scope == .user ? "用户只读" : "系统只读"
    }

    var startupOverviewDetailTitle: String {
        switch sourceType {
        case .loginItem: return "传统 Login Item 信息"
        case .embeddedLoginItem: return "App 内置 LoginItem 信息"
        default: return "启动项信息"
        }
    }

    var startupOverviewEvidenceLabel: String {
        switch sourceType {
        case .loginItem: return "LSSharedFileList 证据"
        case .embeddedLoginItem: return "App Bundle 证据"
        default: return "执行证据"
        }
    }

    var startupOverviewEvidenceFallback: String {
        switch sourceType {
        case .loginItem: return "LSSharedFileList（传统用户登录项）"
        case .embeddedLoginItem: return "App Bundle LoginItems（只读发现）"
        default: return "未知"
        }
    }

    var startupOverviewHostApplicationPath: String? {
        sourceType == .embeddedLoginItem ? project?.rootPath : nil
    }

    var startupOverviewReadOnlyDescription: String {
        switch sourceType {
        case .loginItem:
            return "该条目是用户级传统 Login Item 的只读记录，普通操作不会修改它。"
        case .embeddedLoginItem:
            return "该条目来自 App 包内置 LoginItems，仅作只读发现，普通操作不会修改它。"
        default:
            return scope == .user
                ? "该来源只读，普通操作不会修改它。"
                : "系统或全局项目只读，普通操作不会修改它。"
        }
    }
}

public extension LoginItemApplicationGroup {
    var sourceSummary: String {
        let presentSources = Set(items.map(\.sourceType))
        let preferredOrder: [SourceType] = [.loginItem, .launchAgent, .embeddedLoginItem]
        let knownSources = preferredOrder.filter(presentSources.contains)
        let remainingSources = presentSources
            .subtracting(knownSources)
            .sorted { $0.displayName < $1.displayName }
        return (knownSources + remainingSources).map(\.displayName).joined(separator: "、")
    }

    var accessSummary: String {
        let accessNames = Set(items.map(\.startupOverviewAccessDisplayName))
        let preferredOrder = ["用户", "用户只读", "系统只读"]
        let knownNames = preferredOrder.filter(accessNames.contains)
        let remainingNames = accessNames.subtracting(knownNames).sorted()
        return (knownNames + remainingNames).joined(separator: "、")
    }

    var stateSummary: String {
        let states = Set(items.map(\.state))
        let preferredOrder: [ServiceState] = [
            .discovered, .enabled, .running, .disabled, .stopped,
            .failed, .stale, .permissionDenied, .systemReadonly
        ]
        return preferredOrder.filter(states.contains).map(\.displayName).joined(separator: "、")
    }
}

public extension Scope {
    var displayName: String {
        switch self {
        case .user: return "用户"
        case .global: return "全局"
        case .system: return "系统"
        }
    }
}

public extension ServiceState {
    var displayName: String {
        switch self {
        case .discovered: return "已发现"
        case .enabled: return "已启用"
        case .running: return "运行中"
        case .stopped: return "已停止"
        case .disabled: return "已禁用"
        case .failed: return "失败"
        case .stale: return "失效"
        case .permissionDenied: return "无权限"
        case .systemReadonly: return "系统只读"
        }
    }
}

public extension ValidityStatus {
    var displayName: String {
        switch self {
        case .healthy: return "有效"
        case .missingTarget: return "目标缺失"
        case .missingInterpreter: return "解释器缺失"
        case .invalidConfiguration: return "配置无效"
        case .unknown: return "未知"
        }
    }
}

public extension SignatureClass {
    var displayName: String {
        switch self {
        case .apple: return "Apple 签名"
        case .developerID: return "Developer ID"
        case .adhoc: return "Ad Hoc"
        case .unsigned: return "未签名"
        case .invalid: return "签名无效"
        case .unknown: return "未知"
        }
    }
}

public extension RunTimePrecision {
    var displayName: String {
        switch self {
        case .exact: return "精确"
        case .approximate: return "约略"
        case .unknown: return "未知"
        }
    }
}

public extension OperationAction {
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .start: return "启动"
        case .stop: return "停止"
        case .restart: return "重启"
        case .enable: return "启用"
        case .disable: return "禁用"
        case .testRun: return "测试运行"
        case .backup: return "备份"
        case .restore: return "恢复"
        case .uninstall: return "卸载"
        }
    }

    var systemImage: String {
        switch self {
        case .start: return "play.fill"
        case .stop: return "stop.fill"
        case .restart: return "arrow.clockwise"
        case .enable: return "checkmark.shield"
        case .disable: return "nosign"
        case .testRun: return "stethoscope"
        case .backup: return "archivebox"
        case .restore: return "arrow.uturn.backward"
        case .uninstall: return "trash"
        }
    }
}

extension OperationAction: Identifiable {}
