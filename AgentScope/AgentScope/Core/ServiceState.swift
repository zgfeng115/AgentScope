public enum ServiceState: String, Codable, Hashable, Sendable {
    case discovered
    case enabled
    case running
    case stopped
    case disabled
    case failed
    case stale
    case permissionDenied
    case systemReadonly
}

public enum RunTimePrecision: String, Codable, Hashable, Sendable {
    case exact
    case approximate
    case unknown
}

public enum ValidityStatus: String, Codable, Hashable, Sendable {
    case healthy
    case missingTarget
    case missingInterpreter
    case invalidConfiguration
    case unknown
}

public enum EvidenceSeverity: String, Codable, Hashable, Sendable {
    case info
    case warning
    case critical
}

public struct Evidence: Codable, Hashable, Sendable {
    public var title: String
    public var detail: String
    public var severity: EvidenceSeverity

    public init(title: String, detail: String, severity: EvidenceSeverity) {
        self.title = title
        self.detail = detail
        self.severity = severity
    }
}

public struct Attribution: Codable, Hashable, Sendable {
    public var kind: String
    public var confidence: Double
    public var evidence: [String]

    public init(kind: String, confidence: Double, evidence: [String]) {
        self.kind = kind
        self.confidence = confidence
        self.evidence = evidence
    }
}
