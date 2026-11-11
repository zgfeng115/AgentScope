import AppKit
import Foundation

public protocol ApplicationLocating: Sendable {
    func isInstalled(bundleIdentifier: String) -> Bool
}

public struct WorkspaceApplicationLocator: ApplicationLocating {
    public init() {}

    public func isInstalled(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}

/// Gives every item a purpose category, a one-line plain-language summary and a leftover signal.
/// Order: built-in knowledge base → deterministic rules. AI explanations are layered on later and cached separately.
public struct ItemExplainer: Sendable {
    private let knowledgeBase: KnowledgeBase
    private let locator: any ApplicationLocating
    private let homeDirectory: String

    public init(
        knowledgeBase: KnowledgeBase = KnowledgeBase(),
        locator: any ApplicationLocating = WorkspaceApplicationLocator(),
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.knowledgeBase = knowledgeBase
        self.locator = locator
        self.homeDirectory = homeDirectory
    }

    public func explain(_ item: ServiceItem) -> ServiceItem {
        var explained = item
        if explained.ownerAppPath == nil {
            explained.ownerAppPath = item.programPath.flatMap(ResidentProcessScanner.outermostAppPath)
                ?? item.attributionHostAppPath
        }

        if let entry = knowledgeBase.match(explained) {
            explained.vendorName = entry.product
            explained.purpose = entry.purpose
            explained.summary = entry.summary
            explained.summarySource = .knowledgeBase
            explained.ownerAppStatus = ownerAppStatus(for: explained, knownApps: entry.appBundleIDs)
        } else {
            explained.vendorName = fallbackVendorName(for: explained)
            explained.purpose = rulePurpose(for: explained)
            explained.summary = ruleSummary(for: explained)
            explained.summarySource = .rule
            explained.ownerAppStatus = ownerAppStatus(for: explained, knownApps: [])
        }
        return explained
    }

    // MARK: - Leftover detection

    private func ownerAppStatus(for item: ServiceItem, knownApps: [String]) -> OwnerAppStatus {
        if let appPath = item.ownerAppPath {
            return FileManager.default.fileExists(atPath: appPath) ? .installed : .missing
        }
        guard !knownApps.isEmpty else { return .notApplicable }
        return knownApps.contains(where: locator.isInstalled(bundleIdentifier:)) ? .installed : .missing
    }

    // MARK: - Rules

    func rulePurpose(for item: ServiceItem) -> PurposeCategory {
        let identifier = (item.label ?? item.name).lowercased()
        switch item.sourceType {
        case .cron, .shellStartup, .periodic:
            return .userScript
        case .homebrew, .docker, .tmux:
            return .devTools
        case .kernelExtension:
            return .peripheralDriver
        default:
            break
        }
        if identifier.contains("update") || identifier.contains("upgrade") {
            return .updater
        }
        if isUserAuthored(item) {
            return .userScript
        }
        if identifier.contains("vpn") || identifier.contains("proxy") || identifier.contains("tunnel") {
            return .proxyVPN
        }
        if identifier.contains("sync") || identifier.contains("backup") || identifier.contains("drive") {
            return .syncBackup
        }
        return .unknown
    }

    /// A user-scope agent/process/cron with no Developer ID vendor is something the user set up themselves:
    /// it runs their own script, or an Apple tool (ssh, zsh, python) with their own arguments.
    func isUserAuthored(_ item: ServiceItem) -> Bool {
        guard item.scope == .user else { return false }
        guard [.launchAgent, .process, .cron, .shellStartup, .periodic].contains(item.sourceType) else { return false }
        if item.signing?.signature == .developerID { return false }
        if item.ownerAppPath != nil { return false }
        return true
    }

    func ruleSummary(for item: ServiceItem) -> String {
        if isUserAuthored(item) {
            return userScriptSummary(for: item)
        }
        let maker = item.vendorName ?? item.signing?.organization ?? "未知厂商"
        var parts = ["\(maker)的\(mechanismDescription(item.sourceType))"]
        if let trigger = triggerDescription(item) {
            parts.append(trigger)
        }
        parts.append(stateDescription(item))
        return parts.joined(separator: "，") + "。"
    }

    private func userScriptSummary(for item: ServiceItem) -> String {
        var parts = ["自建\(mechanismDescription(item.sourceType))"]
        if let command = commandPreview(for: item) {
            parts.append("执行 \(command)")
        }
        if let trigger = triggerDescription(item) {
            parts.append(trigger)
        }
        parts.append(stateDescription(item))
        return parts.joined(separator: "，") + "。"
    }

    /// Short, home-relative command line for display; long commands are truncated.
    private func commandPreview(for item: ServiceItem) -> String? {
        let words: [String]
        if item.sourceType == .cron || item.sourceType == .shellStartup {
            words = [item.name]
        } else {
            words = ([item.programPath].compactMap { $0 } + item.arguments)
        }
        guard !words.isEmpty else { return nil }
        let joined = words.joined(separator: " ").replacingOccurrences(of: homeDirectory, with: "~")
        let limit = 90
        return joined.count > limit ? String(joined.prefix(limit)) + "…" : joined
    }

    private func fallbackVendorName(for item: ServiceItem) -> String? {
        if let appPath = item.ownerAppPath {
            return URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
        }
        if let organization = item.signing?.organization {
            return organization
        }
        if item.sourceType == .homebrew {
            return item.name
        }
        return nil
    }

    private func mechanismDescription(_ source: SourceType) -> String {
        switch source {
        case .launchAgent: return "登录后在后台运行的代理程序（LaunchAgent）"
        case .launchDaemon: return "开机即以管理员权限运行的守护进程（LaunchDaemon）"
        case .loginItem: return "登录时自动打开的应用"
        case .embeddedLoginItem: return "应用内置的开机助手"
        case .privilegedHelper: return "特权助手程序"
        case .systemExtension: return "系统扩展"
        case .kernelExtension: return "内核扩展驱动"
        case .backgroundTask: return "后台活动项"
        case .process: return "常驻后台进程"
        case .cron: return "cron 定时任务"
        case .periodic: return "periodic 定期脚本"
        case .shellStartup: return "终端启动时执行的命令"
        case .homebrew: return "Homebrew 后台服务"
        case .docker: return "Docker 容器"
        case .tmux: return "tmux 会话"
        case .unknown: return "后台项目"
        }
    }

    private func triggerDescription(_ item: ServiceItem) -> String? {
        guard let triggers = item.triggers, !triggers.isEmpty else { return nil }
        let kinds = Set(triggers.map(\.kind))
        if kinds.contains(.keepAlive) { return "常驻运行，退出后会被自动拉起" }
        if kinds.contains(.calendar) || kinds.contains(.cron) { return "按计划定时执行" }
        if kinds.contains(.startInterval) { return triggers.first { $0.kind == .startInterval }?.summary }
        if kinds.contains(.runAtLoad) { return "登录或开机时运行一次" }
        return nil
    }

    private func stateDescription(_ item: ServiceItem) -> String {
        switch item.state {
        case .running: return "当前正在运行"
        case .disabled: return "已被禁用"
        case .stale: return "已失效或疑似残留"
        case .failed: return "上次运行失败"
        case .stopped: return "当前未运行"
        case .enabled: return "已启用"
        case .discovered where item.sourceType == .embeddedLoginItem:
            return "是否已开启开机自启以「深度扫描」结果为准"
        default: return "状态未知"
        }
    }
}

private extension ServiceItem {
    var attributionHostAppPath: String? {
        sourceType == .embeddedLoginItem ? project?.rootPath : nil
    }
}
