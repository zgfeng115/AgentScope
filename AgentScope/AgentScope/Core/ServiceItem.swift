import Foundation

public struct ServiceItem: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var sourceType: SourceType
    public var scope: Scope
    public var label: String?
    public var configurationPath: String?
    public var programPath: String?
    public var arguments: [String]
    public var state: ServiceState
    public var pid: Int32?
    public var startedAt: Date?
    public var lastRunAt: Date?
    public var lastRunPrecision: RunTimePrecision
    public var lastExitCode: Int32?
    public var disabled: Bool
    public var validity: ValidityStatus
    public var signature: SignatureClass
    public var signing: SigningInfo?
    public var bundleIdentifier: String?
    public var vendorName: String?
    public var ownerAppPath: String?
    public var ownerAppStatus: OwnerAppStatus?
    public var purpose: PurposeCategory?
    public var summary: String?
    public var summarySource: SummarySource?
    public var attribution: Attribution?
    public var evidence: [Evidence]
    public var project: ProjectIdentity?
    public var triggers: [TriggerInfo]?
    public var executionEvidence: ExecutionEvidence?
    public var assessment: ReviewAssessment?

    public init(
        id: String,
        name: String,
        sourceType: SourceType,
        scope: Scope,
        label: String? = nil,
        configurationPath: String? = nil,
        programPath: String? = nil,
        arguments: [String] = [],
        state: ServiceState = .discovered,
        pid: Int32? = nil,
        startedAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastRunPrecision: RunTimePrecision = .unknown,
        lastExitCode: Int32? = nil,
        disabled: Bool = false,
        validity: ValidityStatus = .unknown,
        signature: SignatureClass = .unknown,
        signing: SigningInfo? = nil,
        bundleIdentifier: String? = nil,
        vendorName: String? = nil,
        ownerAppPath: String? = nil,
        ownerAppStatus: OwnerAppStatus? = nil,
        purpose: PurposeCategory? = nil,
        summary: String? = nil,
        summarySource: SummarySource? = nil,
        attribution: Attribution? = nil,
        evidence: [Evidence] = [],
        project: ProjectIdentity? = nil,
        triggers: [TriggerInfo]? = nil,
        executionEvidence: ExecutionEvidence? = nil,
        assessment: ReviewAssessment? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceType = sourceType
        self.scope = scope
        self.label = label
        self.configurationPath = configurationPath
        self.programPath = programPath
        self.arguments = arguments
        self.state = state
        self.pid = pid
        self.startedAt = startedAt
        self.lastRunAt = lastRunAt
        self.lastRunPrecision = lastRunPrecision
        self.lastExitCode = lastExitCode
        self.disabled = disabled
        self.validity = validity
        self.signature = signature
        self.signing = signing
        self.bundleIdentifier = bundleIdentifier
        self.vendorName = vendorName
        self.ownerAppPath = ownerAppPath
        self.ownerAppStatus = ownerAppStatus
        self.purpose = purpose
        self.summary = summary
        self.summarySource = summarySource
        self.attribution = attribution
        self.evidence = evidence
        self.project = project
        self.triggers = triggers
        self.executionEvidence = executionEvidence
        self.assessment = assessment
    }
}
