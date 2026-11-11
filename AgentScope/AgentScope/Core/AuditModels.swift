import Foundation

public enum AuditCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case all
    case projects
    case automaticStartup
    case scheduledTasks
    case loginItems
    case shellStartup
    case ecosystems
    case system
    case attention
}

public enum ProjectKind: String, Codable, Hashable, Sendable {
    case gitRepository
    case appBundle
    case homebrewFormula
    case dockerCompose
    case shellReference
    case unknown
}

public struct ProjectIdentity: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let rootPath: String?
    public let kind: ProjectKind
    public let confidence: Double
    public let evidence: [String]

    public init(
        id: String,
        displayName: String,
        rootPath: String?,
        kind: ProjectKind,
        confidence: Double,
        evidence: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.kind = kind
        self.confidence = confidence
        self.evidence = evidence
    }
}

public enum TriggerKind: String, Codable, Hashable, Sendable {
    case runAtLoad
    case keepAlive
    case startInterval
    case calendar
    case cron
    case periodic
    case loginItem
    case shellStartup
    case homebrew
    case docker
    case tmux
    case watchPaths
}

public struct TriggerInfo: Codable, Hashable, Sendable {
    public let kind: TriggerKind
    public let summary: String
    public let expression: String?
    public let nextRunAt: Date?

    public init(
        kind: TriggerKind,
        summary: String,
        expression: String? = nil,
        nextRunAt: Date? = nil
    ) {
        self.kind = kind
        self.summary = summary
        self.expression = expression
        self.nextRunAt = nextRunAt
    }
}

public enum EvidencePrecision: String, Codable, Hashable, Sendable {
    case exact
    case approximate
    case unknown
}

public struct ExecutionEvidence: Codable, Hashable, Sendable {
    public let lastExecutionAt: Date?
    public let precision: EvidencePrecision
    public let lastExitCode: Int32?
    public let consecutiveFailures: Int
    public let source: String
    public let detail: String?
    /// `runs = N` from `launchctl print`: how many times launchd started it since it was loaded.
    public let runCount: Int?

    public init(
        lastExecutionAt: Date?,
        precision: EvidencePrecision,
        lastExitCode: Int32?,
        consecutiveFailures: Int,
        source: String,
        detail: String? = nil,
        runCount: Int? = nil
    ) {
        self.runCount = runCount
        self.lastExecutionAt = lastExecutionAt
        self.precision = precision
        self.lastExitCode = lastExitCode
        self.consecutiveFailures = consecutiveFailures
        self.source = source
        self.detail = detail
    }
}

public enum ReviewStatus: String, Codable, Hashable, Sendable {
    case retain
    case possiblyStale
    case invalid
    case abnormal
    case unclear
}

extension ReviewStatus {
    public var displayName: String {
        switch self {
        case .retain: return "建议保留"
        case .possiblyStale: return "可能已过时"
        case .invalid: return "配置无效"
        case .abnormal: return "执行异常"
        case .unclear: return "需要人工确认"
        }
    }
}

public struct ReviewAssessment: Codable, Hashable, Sendable {
    public let status: ReviewStatus
    public let confidence: Double
    public let evidence: [String]

    public init(status: ReviewStatus, confidence: Double, evidence: [String]) {
        self.status = status
        self.confidence = confidence
        self.evidence = evidence
    }
}

public struct ProjectGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let project: ProjectIdentity
    public let items: [ServiceItem]

    public init(project: ProjectIdentity, items: [ServiceItem]) {
        self.id = project.id
        self.project = project
        self.items = items
    }
}

public struct AnalysisRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let serviceID: String
    public let analyzedAt: Date
    public let model: String
    public let summary: String
    public let dependencies: [String]
    public let risks: [String]
    public let projectUsefulness: String
    public let confidence: Double
    public let evidence: [String]
    public let rawResponse: String?

    public init(
        id: UUID = UUID(),
        serviceID: String,
        analyzedAt: Date,
        model: String,
        summary: String,
        dependencies: [String],
        risks: [String],
        projectUsefulness: String,
        confidence: Double,
        evidence: [String],
        rawResponse: String? = nil
    ) {
        self.id = id
        self.serviceID = serviceID
        self.analyzedAt = analyzedAt
        self.model = model
        self.summary = summary
        self.dependencies = dependencies
        self.risks = risks
        self.projectUsefulness = projectUsefulness
        self.confidence = confidence
        self.evidence = evidence
        self.rawResponse = rawResponse
    }
}
