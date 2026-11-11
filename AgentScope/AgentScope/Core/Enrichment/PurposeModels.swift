import Foundation

/// Stable English values; Chinese labels live in `displayName`.
public enum PurposeCategory: String, Codable, Hashable, Sendable, CaseIterable {
    case remoteControl
    case bankingSecurity
    case updater
    case proxyVPN
    case devTools
    case syncBackup
    case securityCleaner
    case peripheralDriver
    case communication
    case productivity
    case media
    case userScript
    case unknown

    public var displayName: String {
        switch self {
        case .remoteControl: return "远程控制"
        case .bankingSecurity: return "网银 / U 盾"
        case .updater: return "自动更新"
        case .proxyVPN: return "代理 / VPN / 网络"
        case .devTools: return "开发工具"
        case .syncBackup: return "同步 / 备份 / 网盘"
        case .securityCleaner: return "安全 / 清理"
        case .peripheralDriver: return "硬件 / 驱动"
        case .communication: return "通讯 / 会议"
        case .productivity: return "办公 / 效率"
        case .media: return "影音 / 娱乐 / 学习"
        case .userScript: return "自建脚本"
        case .unknown: return "未识别"
        }
    }

    public var symbolName: String {
        switch self {
        case .remoteControl: return "display.2"
        case .bankingSecurity: return "creditcard"
        case .updater: return "arrow.triangle.2.circlepath"
        case .proxyVPN: return "network"
        case .devTools: return "hammer"
        case .syncBackup: return "externaldrive.badge.icloud"
        case .securityCleaner: return "shield.lefthalf.filled"
        case .peripheralDriver: return "cpu"
        case .communication: return "video"
        case .productivity: return "briefcase"
        case .media: return "play.rectangle"
        case .userScript: return "terminal"
        case .unknown: return "questionmark.circle"
        }
    }
}

public enum SummarySource: String, Codable, Hashable, Sendable {
    case knowledgeBase
    case rule
    case ai

    public var displayName: String {
        switch self {
        case .knowledgeBase: return "内置知识库"
        case .rule: return "规则推断"
        case .ai: return "AI 分析"
        }
    }
}

/// Whether the app that installed an item is still on disk — the key "is this leftover?" signal.
public enum OwnerAppStatus: String, Codable, Hashable, Sendable {
    case installed
    case missing
    case notApplicable
}
