import Foundation

/// One row in the main list: everything a single app / vendor put on the machine, across all mechanisms.
public struct VendorGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let purpose: PurposeCategory
    public let summary: String
    public let summarySource: SummarySource?
    public let organization: String?
    public let iconPath: String?
    public let items: [ServiceItem]

    public var runningCount: Int {
        items.filter { $0.state == .running }.count
    }

    /// Owning app gone, orphaned, invalid or abnormal — worth a look.
    public var needsAttention: Bool {
        items.contains(where: \.needsAttention)
    }

    public var isLeftover: Bool {
        !items.isEmpty && items.allSatisfy {
            $0.ownerAppStatus == .missing || $0.state == .stale || $0.validity == .missingTarget
        }
    }

    /// "2 个 LaunchAgent · 3 个 LaunchDaemon · 1 个特权助手"
    public var composition: String {
        let counts = Dictionary(grouping: items, by: \.sourceType).mapValues(\.count)
        return VendorGrouping.sourceOrder
            .compactMap { source in counts[source].map { "\($0) 个\(source.displayName)" } }
            .joined(separator: " · ")
    }
}

public extension ServiceItem {
    /// Invalid, failing or leftover — "unclear" (not enough evidence) is deliberately not attention-worthy.
    var needsAttention: Bool {
        if ownerAppStatus == .missing { return true }
        guard let status = assessment?.status else { return false }
        return status == .invalid || status == .abnormal || status == .possiblyStale
    }
}

public enum VendorGrouping {
    static let sourceOrder: [SourceType] = [
        .loginItem, .embeddedLoginItem, .launchAgent, .launchDaemon, .privilegedHelper,
        .systemExtension, .kernelExtension, .backgroundTask, .process, .cron, .periodic,
        .shellStartup, .homebrew, .docker, .tmux, .unknown
    ]

    public static func groups(from items: [ServiceItem]) -> [VendorGroup] {
        let grouped = Dictionary(grouping: items, by: key(for:))
        return grouped.map { key, members in makeGroup(id: key, items: members) }
            .sorted { lhs, rhs in
                if lhs.purpose != rhs.purpose {
                    return purposeRank(lhs.purpose) < purposeRank(rhs.purpose)
                }
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
            }
    }

    static func key(for item: ServiceItem) -> String {
        if item.sourceType == .docker {
            if let project = item.project, project.kind == .dockerCompose {
                return "docker:\(project.displayName)"
            }
            return "docker:standalone"
        }
        if let vendor = item.vendorName, !vendor.isEmpty {
            return "vendor:\(vendor)"
        }
        if let team = item.signing?.teamID {
            return "team:\(team)"
        }
        if let app = item.ownerAppPath {
            return "app:\(app)"
        }
        return "item:\(item.id)"
    }

    private static func makeGroup(id: String, items: [ServiceItem]) -> VendorGroup {
        let sorted = items.sorted { lhs, rhs in
            let left = sourceOrder.firstIndex(of: lhs.sourceType) ?? .max
            let right = sourceOrder.firstIndex(of: rhs.sourceType) ?? .max
            return left == right ? lhs.id < rhs.id : left < right
        }
        let first = sorted[0]
        let purposes = Dictionary(grouping: sorted.compactMap(\.purpose), by: { $0 }).mapValues(\.count)
        let purpose = purposes.max { lhs, rhs in
            lhs.value == rhs.value ? purposeRank(lhs.key) > purposeRank(rhs.key) : lhs.value < rhs.value
        }?.key ?? .unknown
        let preferred = sorted.first { $0.summarySource == .knowledgeBase } ?? sorted.first { $0.summarySource == .ai } ?? first

        return VendorGroup(
            id: id,
            name: groupName(id: id, first: first),
            purpose: purpose,
            summary: groupSummary(id: id, items: sorted, preferred: preferred),
            summarySource: preferred.summarySource,
            organization: sorted.lazy.compactMap { $0.signing?.organization }.first,
            iconPath: sorted.lazy.compactMap(\.ownerAppPath).first { FileManager.default.fileExists(atPath: $0) },
            items: sorted
        )
    }

    private static func groupName(id: String, first: ServiceItem) -> String {
        if id == "docker:standalone" { return "Docker 独立容器" }
        if id.hasPrefix("docker:") { return "Docker · \(id.dropFirst("docker:".count))" }
        if let vendor = first.vendorName { return vendor }
        if let organization = first.signing?.organization { return organization }
        return first.name
    }

    private static func groupSummary(id: String, items: [ServiceItem], preferred: ServiceItem) -> String {
        if id.hasPrefix("docker:") {
            let running = items.filter { $0.state == .running }.count
            return "\(items.count) 个 Docker 容器，\(running) 个正在运行。Docker Desktop 运行时会按各容器的重启策略自动拉起它们。"
        }
        return preferred.summary ?? ""
    }

    static func purposeRank(_ purpose: PurposeCategory) -> Int {
        PurposeCategory.allCases.firstIndex(of: purpose) ?? .max
    }
}
