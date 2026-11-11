import Foundation

public enum AIWireProtocol: String, Codable, Hashable, Sendable {
    case openAICompatible
    case anthropic
}

/// Built-in AI services. Model names are suggestions; every field stays editable.
public enum AIProviderPreset: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case claude
    case openAI
    case deepSeek
    case gemini
    case qwen
    case kimi
    case zhipu
    case openRouter
    case ollama
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude（Anthropic）"
        case .openAI: return "ChatGPT（OpenAI）"
        case .deepSeek: return "DeepSeek"
        case .gemini: return "Gemini（Google）"
        case .qwen: return "通义千问（阿里云）"
        case .kimi: return "Kimi（月之暗面）"
        case .zhipu: return "智谱 GLM"
        case .openRouter: return "OpenRouter"
        case .ollama: return "Ollama（本地）"
        case .custom: return "自定义（OpenAI 兼容）"
        }
    }

    public var defaultBaseURL: URL {
        let text: String
        switch self {
        case .claude: text = "https://api.anthropic.com/v1"
        case .openAI, .custom: text = "https://api.openai.com/v1"
        case .deepSeek: text = "https://api.deepseek.com/v1"
        case .gemini: text = "https://generativelanguage.googleapis.com/v1beta/openai"
        case .qwen: text = "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .kimi: text = "https://api.moonshot.cn/v1"
        case .zhipu: text = "https://open.bigmodel.cn/api/paas/v4"
        case .openRouter: text = "https://openrouter.ai/api/v1"
        case .ollama: text = "http://localhost:11434/v1"
        }
        return URL(string: text)!
    }

    public var defaultModel: String {
        switch self {
        case .claude: return "claude-opus-5-5"
        case .openAI: return "gpt-5"
        case .deepSeek: return "deepseek-chat"
        case .gemini: return "gemini-2.5-flash"
        case .qwen: return "qwen-plus"
        case .kimi: return "kimi-k2-turbo-preview"
        case .zhipu: return "glm-4.6"
        case .openRouter: return "anthropic/claude-opus-5-5"
        case .ollama: return "qwen3"
        case .custom: return ""
        }
    }

    public var wireProtocol: AIWireProtocol { self == .claude ? .anthropic : .openAICompatible }

    public var requiresKey: Bool { self != .ollama }

    public static func preset(for id: String) -> AIProviderPreset {
        AIProviderPreset(rawValue: id) ?? .custom
    }
}

// MARK: - Keys per provider

/// Keys are stored per provider so switching presets never sends one vendor's key to another host.
public protocol ProviderKeyStoring: Sendable {
    func load(provider: String) throws -> String?
    func save(_ key: String, provider: String) throws
    func remove(provider: String) throws
}

/// Single-key stores (older code, tests) ignore the provider.
extension ProviderKeyStoring where Self: APIKeyStoring {
    public func load(provider: String) throws -> String? { try load() }
    public func save(_ key: String, provider: String) throws { try save(key) }
    public func remove(provider: String) throws { try remove() }
}

public struct KeychainProviderKeyStore: ProviderKeyStoring {
    private let service: String

    public init(service: String = "com.agentscope.ai") {
        self.service = service
    }

    private func store(_ provider: String) -> KeychainAPIKeyStore {
        KeychainAPIKeyStore(service: service, account: "api-key.\(provider)")
    }

    public func load(provider: String) throws -> String? { try store(provider).load() }
    public func save(_ key: String, provider: String) throws { try store(provider).save(key) }
    public func remove(provider: String) throws { try store(provider).remove() }

    /// Moves the pre-0.3 single `api-key` entry under `provider`, then deletes it.
    public func migrateLegacyKey(to provider: String) {
        let legacy = KeychainAPIKeyStore(service: service, account: "api-key")
        guard let key = try? legacy.load(), !key.isEmpty else { return }
        if (try? load(provider: provider)) ?? nil == nil {
            guard (try? save(key, provider: provider)) != nil else { return }
        }
        try? legacy.remove()
    }
}

// MARK: - Providers

public protocol AIConnectionTesting: Sendable {
    /// Sends a minimal request. Returns the round-trip time; throws a redacted error.
    func testConnection() async throws -> TimeInterval
}

public typealias ConfigurableAIProvider = AnalysisProvider & AIConnectionTesting

public enum AIProviderFactory {
    public static func make(configuration: AIModelConfiguration, apiKey: String?) -> any ConfigurableAIProvider {
        let key = apiKey ?? ""
        switch AIProviderPreset.preset(for: configuration.providerID).wireProtocol {
        case .anthropic:
            return AnthropicAnalysisProvider(configuration: configuration, apiKey: key)
        case .openAICompatible:
            return OpenAICompatibleAnalysisProvider(configuration: configuration, apiKey: key)
        }
    }
}

enum AIHTTP {
    static func send(_ request: URLRequest, apiKey: String, session: URLSession = .shared) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AnalysisProviderError.requestFailed("服务器响应无效。")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(decoding: data.prefix(600), as: UTF8.self)
                throw AnalysisProviderError.requestFailed("HTTP \(http.statusCode)：\(redact(body, apiKey: apiKey))")
            }
            return data
        } catch let error as AnalysisProviderError {
            throw error
        } catch {
            throw AnalysisProviderError.requestFailed(redact(error.localizedDescription, apiKey: apiKey))
        }
    }

    /// Error bodies sometimes echo the key back; never let it reach the UI or logs.
    static func redact(_ text: String, apiKey: String) -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutKey = trimmed.count >= 6 ? text.replacingOccurrences(of: trimmed, with: "[REDACTED]") : text
        return AnalysisRedactor.redact(withoutKey)
    }

    static func timed(_ work: () async throws -> Void) async throws -> TimeInterval {
        let start = Date()
        try await work()
        return Date().timeIntervalSince(start)
    }
}

/// Claude through the native Messages API (Swift has no official Anthropic SDK, so raw HTTP).
public struct AnthropicAnalysisProvider: ConfigurableAIProvider {
    static let apiVersion = "2026-10-21"

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
        guard options.mode == .cloud, options.allowCloud else { throw AnalysisProviderError.cloudNotEnabled }
        let payload = try payloadBuilder.make(for: item)
        let text = try await complete(system: AnalysisPrompt.system, user: payload, maxTokens: 16_000)
        return AnalysisResult.fromModelContent(text)
    }

    /// Any 2xx counts: the key, model and endpoint are fine even if a tiny reply has no text block.
    public func testConnection() async throws -> TimeInterval {
        try validate()
        let request = try makeRequest(system: "Reply with OK.", user: "ping", maxTokens: 1024)
        return try await AIHTTP.timed { _ = try await AIHTTP.send(request, apiKey: apiKey) }
    }

    func makeRequest(system: String, user: String, maxTokens: Int) throws -> URLRequest {
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        let fallbacks = usesServerSideFallbacks
        if fallbacks {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONEncoder().encode(MessagesRequest(
            model: configuration.model,
            maxTokens: maxTokens,
            system: system,
            messages: [MessagesRequest.Message(role: "user", content: user)],
            fallbacks: fallbacks ? "default" : nil
        ))
        return request
    }

    static let fallbackBeta = "server-side-fallback-2026-07-01"

    /// On a safety refusal the API re-runs the request on Anthropic's recommended fallback model.
    /// Only on the first-party endpoint: proxies and other platforms may reject the field.
    var usesServerSideFallbacks: Bool {
        configuration.baseURL.host == "api.anthropic.com" && configuration.model.hasPrefix("claude-")
    }

    private func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        let data = try await AIHTTP.send(try makeRequest(system: system, user: user, maxTokens: maxTokens), apiKey: apiKey)
        return try Self.text(from: data)
    }

    static func text(from data: Data) throws -> String {
        guard let response = try? JSONDecoder().decode(MessagesResponse.self, from: data) else {
            throw AnalysisProviderError.invalidResponse("不是有效的 Claude Messages 响应。")
        }
        if response.stopReason == "refusal" {
            throw AnalysisProviderError.invalidResponse("Claude 拒绝了这次请求（refusal）。")
        }
        let text = response.content.filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw AnalysisProviderError.invalidResponse("响应中没有文本内容。") }
        return text
    }

    private func validate() throws {
        guard configuration.isConfigured else {
            throw AnalysisProviderError.invalidConfiguration("请先在 AI 设置中启用接口并填写模型名称。")
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnalysisProviderError.invalidConfiguration("请先在 AI 设置中填写 API Key。")
        }
    }
}

struct MessagesRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]
    let fallbacks: String?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case fallbacks
    }
}

struct MessagesResponse: Decodable {
    struct Block: Decodable {
        let type: String
        let text: String?
    }

    let content: [Block]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}

enum AnalysisPrompt {
    static let system = """
    你是 AgentScope 的本地后台服务审计助手。只根据提供的证据分析，不把结论当作安全裁决。
    所有字段一律用简体中文书写；路径、命令、标识符、域名保持原样，不要翻译。即使证据是英文，也用中文回答。
    只返回一个 JSON 对象，不要 Markdown、不要代码块、不要额外说明。字段与类型：
    {
      "summary": "字符串，1 到 3 句，说明它是什么、怎么运行",
      "dependencies": ["字符串数组，每条一句，最多 6 条"],
      "risks": ["字符串数组，每条一句，最多 6 条"],
      "projectUsefulness": "字符串，1 到 2 句，对项目是否有用",
      "confidence": 0.8,
      "evidence": ["字符串数组，每条一句，引用具体证据，最多 6 条"]
    }
    confidence 必须是 0 到 1 之间的数字，不要写文字。
    """
}

extension AnalysisResult {
    /// Accepts a bare JSON object, JSON inside a ```json fence, or plain prose.
    /// Field types are tolerated loosely: models often send lists as one string or confidence as text.
    static func fromModelContent(_ content: String) -> AnalysisResult {
        var candidate = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = candidate.firstIndex(of: "{"), let end = candidate.lastIndex(of: "}"), start < end {
            candidate = String(candidate[start...end])
        }
        if let parsed = try? JSONDecoder().decode(LenientAnalysis.self, from: Data(candidate.utf8)),
           !parsed.summary.isEmpty || !parsed.risks.isEmpty || !parsed.dependencies.isEmpty {
            return AnalysisResult(
                summary: parsed.summary,
                dependencies: parsed.dependencies,
                risks: parsed.risks,
                projectUsefulness: parsed.projectUsefulness,
                confidence: parsed.confidence,
                evidence: parsed.evidence,
                rawResponse: content
            )
        }
        return AnalysisResult(
            summary: content,
            dependencies: [],
            risks: [],
            projectUsefulness: "模型未返回结构化项目用途判断",
            confidence: 0,
            evidence: [AnalysisResult.unstructuredMarker],
            rawResponse: content
        )
    }

    public static let unstructuredMarker = "模型返回了非结构化文本"

    public var isUnstructured: Bool { evidence == [Self.unstructuredMarker] }
}

extension AnalysisRecord {
    /// Records saved before the lenient parser kept the raw JSON as the summary; re-parse them for display.
    public func reparsedIfNeeded() -> AnalysisRecord {
        guard summary.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") || summary.contains("\"summary\""),
              let rawResponse else { return self }
        let result = AnalysisResult.fromModelContent(rawResponse)
        guard !result.isUnstructured else { return self }
        return AnalysisRecord(
            id: id, serviceID: serviceID, analyzedAt: analyzedAt, model: model,
            summary: result.summary, dependencies: result.dependencies, risks: result.risks,
            projectUsefulness: result.projectUsefulness, confidence: result.confidence,
            evidence: result.evidence, rawResponse: rawResponse
        )
    }
}

struct LenientAnalysis: Decodable {
    let summary: String
    let dependencies: [String]
    let risks: [String]
    let projectUsefulness: String
    let confidence: Double
    let evidence: [String]

    private enum CodingKeys: String, CodingKey {
        case summary, dependencies, risks, projectUsefulness, confidence, evidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = Self.text(container, .summary)
        dependencies = Self.list(container, .dependencies)
        risks = Self.list(container, .risks)
        projectUsefulness = Self.text(container, .projectUsefulness)
        evidence = Self.list(container, .evidence)
        if let number = try? container.decode(Double.self, forKey: .confidence) {
            confidence = Self.normalized(number)
        } else {
            confidence = Self.confidence(fromText: Self.text(container, .confidence))
        }
    }

    private static func text(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String {
        if let value = try? container.decode(String.self, forKey: key) {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let values = try? container.decode([String].self, forKey: key) {
            return values.joined(separator: "；")
        }
        return ""
    }

    private static func list(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> [String] {
        if let values = try? container.decode([String].self, forKey: key) {
            return values.map(cleaned).filter { !$0.isEmpty }
        }
        guard let value = try? container.decode(String.self, forKey: key) else { return [] }
        return value
            .components(separatedBy: CharacterSet(charactersIn: "\n；;"))
            .map(cleaned)
            .filter { !$0.isEmpty }
    }

    /// Strips list markers such as "- ", "• ", "1. ", "2、".
    static func cleaned(_ item: String) -> String {
        var text = item.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"^([-•*·]|\d+[.、)）])\s*"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalized(_ number: Double) -> Double {
        let value = number > 1 ? number / 100 : number
        return min(1, max(0, value))
    }

    static func confidence(fromText text: String) -> Double {
        if let range = text.range(of: #"\d+(\.\d+)?"#, options: .regularExpression),
           let number = Double(text[range]) {
            return normalized(number)
        }
        let lowered = text.lowercased()
        let levels: [(String, Double)] = [
            ("中高", 0.75), ("中低", 0.45), ("高", 0.85), ("中", 0.6), ("低", 0.35),
            ("medium-high", 0.75), ("medium-low", 0.45), ("high", 0.85), ("medium", 0.6), ("moderate", 0.6), ("low", 0.35)
        ]
        return levels.first { lowered.contains($0.0) }?.1 ?? 0
    }
}
