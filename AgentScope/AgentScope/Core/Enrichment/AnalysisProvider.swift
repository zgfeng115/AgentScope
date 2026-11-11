import Foundation
import Security

public enum AnalysisMode: String, Codable, Hashable, Sendable {
    case local
    case cloud
}

public struct AIModelConfiguration: Codable, Hashable, Sendable {
    public var providerID: String
    public var enabled: Bool
    public var baseURL: URL
    public var model: String
    public var timeout: TimeInterval

    public init(
        providerID: String = AIProviderPreset.custom.rawValue,
        enabled: Bool = false,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        model: String = "",
        timeout: TimeInterval = 60
    ) {
        self.providerID = providerID
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }

    /// Settings saved before 0.3 have no provider; they were OpenAI-compatible, i.e. "custom".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID) ?? AIProviderPreset.custom.rawValue
        enabled = try container.decode(Bool.self, forKey: .enabled)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        model = try container.decode(String.self, forKey: .model)
        timeout = try container.decode(TimeInterval.self, forKey: .timeout)
    }

    public var preset: AIProviderPreset { AIProviderPreset.preset(for: providerID) }

    public var isConfigured: Bool {
        enabled && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public protocol AIConfigurationStoring {
    func load() -> AIModelConfiguration
    func save(_ configuration: AIModelConfiguration)
}

public struct UserDefaultsAIConfigurationStore: AIConfigurationStoring {
    private let defaults: UserDefaults
    private let key = "AgentScope.aiModelConfiguration"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AIModelConfiguration {
        guard let data = defaults.data(forKey: key),
              let configuration = try? JSONDecoder().decode(AIModelConfiguration.self, from: data) else {
            return AIModelConfiguration()
        }
        return configuration
    }

    public func save(_ configuration: AIModelConfiguration) {
        defaults.set(try? JSONEncoder().encode(configuration), forKey: key)
    }
}

public protocol APIKeyStoring: ProviderKeyStoring {
    func load() throws -> String?
    func save(_ key: String) throws
    func remove() throws
}

public struct KeychainAPIKeyStore: APIKeyStoring {
    private let service: String
    private let account: String

    public init(service: String = "com.agentscope.ai", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    public func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    public func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

public struct KeychainError: LocalizedError, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var errorDescription: String? {
        "Keychain 操作失败（\(status)）。"
    }
}

public struct AnalysisOptions: Codable, Hashable, Sendable {
    public let mode: AnalysisMode
    public let allowCloud: Bool
    public let redactSecrets: Bool

    public init(mode: AnalysisMode = .local, allowCloud: Bool = false, redactSecrets: Bool = true) {
        self.mode = mode
        self.allowCloud = allowCloud
        self.redactSecrets = redactSecrets
    }
}

public struct AnalysisResult: Codable, Hashable, Sendable {
    public let summary: String
    public let dependencies: [String]
    public let risks: [String]
    public let projectUsefulness: String
    public let confidence: Double
    public let evidence: [String]
    public let rawResponse: String?

    public init(
        summary: String,
        dependencies: [String],
        risks: [String],
        projectUsefulness: String,
        confidence: Double,
        evidence: [String],
        rawResponse: String? = nil
    ) {
        self.summary = summary
        self.dependencies = dependencies
        self.risks = risks
        self.projectUsefulness = projectUsefulness
        self.confidence = confidence
        self.evidence = evidence
        self.rawResponse = rawResponse
    }
}

public protocol AnalysisProvider: Sendable {
    func analyze(_ item: ServiceItem, options: AnalysisOptions) async throws -> AnalysisResult
}

public protocol AnalysisResultStoring: Sendable {
    func saveLatestAnalysis(_ record: AnalysisRecord) throws
    func fetchLatestAnalysis(serviceID: String) throws -> AnalysisRecord?
}

public enum AnalysisProviderError: LocalizedError, Equatable, Sendable {
    case cloudNotEnabled
    case cloudProviderUnavailable
    case invalidConfiguration(String)
    case requestFailed(String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .cloudNotEnabled:
            return "云端分析未启用；请在设置中显式允许后再使用。"
        case .cloudProviderUnavailable:
            return "云端分析提供商尚未配置。"
        case .invalidConfiguration(let message):
            return message
        case .requestFailed(let message):
            return "AI 请求失败：\(message)"
        case .invalidResponse(let message):
            return "AI 返回内容无法解析：\(message)"
        }
    }
}

public struct RuleAnalysisProvider: AnalysisProvider {
    private let reviewEngine: ServiceReviewEngine

    public init(reviewEngine: ServiceReviewEngine = ServiceReviewEngine()) {
        self.reviewEngine = reviewEngine
    }

    public func analyze(_ item: ServiceItem, options: AnalysisOptions = AnalysisOptions()) async throws -> AnalysisResult {
        guard options.mode == .local || options.allowCloud else {
            throw AnalysisProviderError.cloudNotEnabled
        }
        if options.mode == .cloud {
            throw AnalysisProviderError.cloudProviderUnavailable
        }

        let assessment = item.assessment ?? reviewEngine.assess(item)
        let detail = item.executionEvidence?.detail.map(AnalysisRedactor.redact) ?? "无额外执行详情"
        let risks = assessment.status == .retain ? [] : assessment.evidence
        return AnalysisResult(
            summary: summary(for: assessment.status),
            dependencies: [item.programPath, item.configurationPath].compactMap { $0 },
            risks: risks,
            projectUsefulness: item.project == nil ? "尚未归属到明确项目" : "已归属到 \(item.project!.displayName)",
            confidence: assessment.confidence,
            evidence: assessment.evidence + [detail],
            rawResponse: nil
        )
    }

    private func summary(for status: ReviewStatus) -> String {
        "规则判断：\(status.displayName)"
    }
}

public struct AnalysisPayloadBuilder: Sendable {
    private let configurationLimit = 32 * 1024
    private let sourceLimit = 64 * 1024

    public init() {}

    public func make(for item: ServiceItem) throws -> String {
        var sections: [String] = []
        sections.append("条目元数据：\n\(metadata(for: item))")
        if let detail = item.executionEvidence?.detail {
            sections.append("执行证据：\n\(AnalysisRedactor.redact(detail))")
        }
        if let configurationPath = item.configurationPath,
           let content = readText(at: configurationPath, limit: configurationLimit) {
            sections.append("配置内容（\(configurationPath)）：\n\(AnalysisRedactor.redact(content))")
        }
        if let programPath = item.programPath,
           programPath != item.configurationPath,
           isLikelyTextSource(programPath),
           let content = readText(at: programPath, limit: sourceLimit) {
            sections.append("目标源码（\(programPath)）：\n\(AnalysisRedactor.redact(content))")
        }
        return sections.joined(separator: "\n\n")
    }

    private func metadata(for item: ServiceItem) -> String {
        let triggers = item.triggers?.map(\.summary).joined(separator: ", ") ?? "无"
        let evidence = item.assessment?.evidence.joined(separator: "; ") ?? "无"
        return """
        名称：\(item.name)
        来源：\(item.sourceType.displayName)
        作用域：\(item.scope.displayName)
        状态：\(item.state.displayName)
        配置路径：\(item.configurationPath ?? "未知")
        程序路径：\(item.programPath ?? "未知")
        参数：\(item.arguments.joined(separator: " "))
        触发方式：\(triggers)
        规则判断：\(item.assessment?.status.displayName ?? "未知")
        规则证据：\(evidence)
        """
    }

    private func readText(at path: String, limit: Int) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count > 0 else { return nil }
        return String(decoding: data.prefix(limit), as: UTF8.self)
    }

    private func isLikelyTextSource(_ path: String) -> Bool {
        let extensions = ["bash", "go", "js", "json", "jsx", "py", "rb", "rs", "sh", "swift", "ts", "tsx", "zsh"]
        return extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

public struct OpenAICompatibleAnalysisProvider: ConfigurableAIProvider {
    private let configuration: AIModelConfiguration
    private let apiKey: String
    private let payloadBuilder: AnalysisPayloadBuilder

    public init(
        configuration: AIModelConfiguration,
        apiKey: String,
        payloadBuilder: AnalysisPayloadBuilder = AnalysisPayloadBuilder()
    ) {
        self.configuration = configuration
        self.apiKey = apiKey
        self.payloadBuilder = payloadBuilder
    }

    public func analyze(_ item: ServiceItem, options: AnalysisOptions = AnalysisOptions(mode: .cloud, allowCloud: true)) async throws -> AnalysisResult {
        try validate()
        guard options.mode == .cloud, options.allowCloud else {
            throw AnalysisProviderError.cloudNotEnabled
        }
        let payload = try payloadBuilder.make(for: item)
        return AnalysisResult.fromModelContent(try await complete(system: AnalysisPrompt.system, user: payload))
    }

    public func testConnection() async throws -> TimeInterval {
        try validate()
        let request = try makeRequest(system: "Reply with OK.", user: "ping")
        return try await AIHTTP.timed { _ = try await AIHTTP.send(request, apiKey: apiKey) }
    }

    func makeRequest(system: String, user: String) throws -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
            model: configuration.model,
            messages: [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)]
        ))
        return request
    }

    private func complete(system: String, user: String) async throws -> String {
        let data = try await AIHTTP.send(try makeRequest(system: system, user: user), apiKey: apiKey)
        guard let envelope = try? JSONDecoder().decode(ChatCompletionResponse.self, from: data) else {
            throw AnalysisProviderError.invalidResponse("不是有效的 Chat Completions 响应。")
        }
        guard let content = envelope.choices.first?.message.content, !content.isEmpty else {
            throw AnalysisProviderError.invalidResponse("响应中没有 assistant 内容。")
        }
        return content
    }

    private func validate() throws {
        guard configuration.isConfigured else {
            throw AnalysisProviderError.invalidConfiguration("请先在 AI 设置中启用接口并填写模型名称。")
        }
        guard !configuration.preset.requiresKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnalysisProviderError.invalidConfiguration("请先在 AI 设置中填写 API Key。")
        }
    }
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [ChatChoice]
}

private struct ChatChoice: Decodable {
    let message: ChatMessage
}

public enum AnalysisRedactor {
    public static func redact(_ text: String) -> String {
        let patterns = [
            "(?i)(token|password|passwd|api[_-]?key|secret)\\s*[:=]\\s*([^\\s]+)",
            "(?i)(authorization)\\s*:\\s*([^\\s]+)"
        ]
        return patterns.reduce(text) { value, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression.stringByReplacingMatches(
                in: value,
                range: range,
                withTemplate: "$1=[REDACTED]"
            )
        }
    }
}
