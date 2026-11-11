import Foundation
import XCTest
@testable import AgentScopeCore

final class AIProvidersTests: XCTestCase {
    func testLegacyConfigurationDecodesAsCustomProvider() throws {
        let legacy = #"{"enabled":true,"baseURL":"https:\/\/api.openai.com\/v1","model":"gpt","timeout":60}"#
        let configuration = try JSONDecoder().decode(AIModelConfiguration.self, from: Data(legacy.utf8))
        XCTAssertEqual(configuration.providerID, "custom")
        XCTAssertEqual(configuration.preset, .custom)
        XCTAssertTrue(configuration.preset.requiresKey)
    }

    func testFactoryRoutesClaudeToNativeMessagesAPI() throws {
        let configuration = AIModelConfiguration(
            providerID: AIProviderPreset.claude.rawValue, enabled: true,
            baseURL: AIProviderPreset.claude.defaultBaseURL, model: "claude-opus-5-5"
        )
        XCTAssertTrue(AIProviderFactory.make(configuration: configuration, apiKey: "k") is AnthropicAnalysisProvider)

        let request = try AnthropicAnalysisProvider(configuration: configuration, apiKey: "sk-ant-test")
            .makeRequest(system: "sys", user: "hello", maxTokens: 512)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["max_tokens"] as? Int, 512)
        XCTAssertEqual(body["system"] as? String, "sys")
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")

        var proxied = configuration
        proxied.baseURL = URL(string: "https://proxy.example.com/v1")!
        let viaProxy = try AnthropicAnalysisProvider(configuration: proxied, apiKey: "k")
            .makeRequest(system: "s", user: "u", maxTokens: 10)
        let proxyBody = try XCTUnwrap(JSONSerialization.jsonObject(with: viaProxy.httpBody!) as? [String: Any])
        XCTAssertNil(proxyBody["fallbacks"])
        XCTAssertNil(viaProxy.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testLegacyKeychainEntryMigratesToProvider() throws {
        let service = "com.agentscope.test.\(UUID().uuidString)"
        let legacy = KeychainAPIKeyStore(service: service, account: "api-key")
        let store = KeychainProviderKeyStore(service: service)
        defer {
            try? legacy.remove()
            try? store.remove(provider: "deepSeek")
        }
        try legacy.save("legacy-value")

        store.migrateLegacyKey(to: "deepSeek")

        XCTAssertEqual(try store.load(provider: "deepSeek"), "legacy-value")
        XCTAssertNil(try legacy.load())
        XCTAssertNil(try store.load(provider: "claude"))
    }

    func testOllamaNeedsNoKeyAndSendsNoAuthorization() throws {
        let configuration = AIModelConfiguration(
            providerID: AIProviderPreset.ollama.rawValue, enabled: true,
            baseURL: AIProviderPreset.ollama.defaultBaseURL, model: "qwen3"
        )
        let request = try OpenAICompatibleAnalysisProvider(configuration: configuration, apiKey: "")
            .makeRequest(system: "s", user: "u")
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testClaudeResponseParsingAndRefusal() throws {
        let ok = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"OK"}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(try AnthropicAnalysisProvider.text(from: Data(ok.utf8)), "OK")
        let refused = #"{"content":[],"stop_reason":"refusal"}"#
        XCTAssertThrowsError(try AnthropicAnalysisProvider.text(from: Data(refused.utf8)))
    }

    func testErrorTextNeverContainsTheKey() {
        let key = "sk-live-1234567890abcdef"
        let text = AIHTTP.redact(#"{"error":"invalid x-api-key sk-live-1234567890abcdef"}"#, apiKey: key)
        XCTAssertFalse(text.contains(key))
    }

    func testFencedJSONIsParsedAsStructuredResult() {
        let content = "```json\n{\"summary\":\"s\",\"dependencies\":[],\"risks\":[],\"projectUsefulness\":\"p\",\"confidence\":0.5,\"evidence\":[]}\n```"
        XCTAssertEqual(AnalysisResult.fromModelContent(content).summary, "s")
    }

    /// The real DeepSeek reply that used to be shown as raw JSON: confidence came back as text.
    func testConfidenceAsTextNoLongerBreaksParsing() {
        let content = #"{"summary":"该条目是用户级 cron 任务，每天 17:22 执行 acme.sh。","dependencies":["cron 用户级调度","bash"],"risks":["命令输出被丢弃到 /dev/null","可能读取私钥"],"projectUsefulness":"高：标准证书续期任务。","confidence":"中高（约 0.8）","evidence":["cron 触发方式：每天 17:22"]}"#
        let result = AnalysisResult.fromModelContent(content)
        XCTAssertEqual(result.summary, "该条目是用户级 cron 任务，每天 17:22 执行 acme.sh。")
        XCTAssertEqual(result.confidence, 0.8, accuracy: 0.001)
        XCTAssertEqual(result.risks.count, 2)
        XCTAssertFalse(result.isUnstructured)
    }

    func testListsAsStringsAndPercentConfidence() {
        let content = #"{"summary":"s","dependencies":"- ssh\n- 网络","risks":"1. 隧道常驻；2、凭据依赖","projectUsefulness":["运维","便利"],"confidence":82,"evidence":[]}"#
        let result = AnalysisResult.fromModelContent(content)
        XCTAssertEqual(result.dependencies, ["ssh", "网络"])
        XCTAssertEqual(result.risks, ["隧道常驻", "凭据依赖"])
        XCTAssertEqual(result.projectUsefulness, "运维；便利")
        XCTAssertEqual(result.confidence, 0.82, accuracy: 0.001)
        XCTAssertEqual(LenientAnalysis.confidence(fromText: "高"), 0.85)
        XCTAssertEqual(LenientAnalysis.confidence(fromText: "medium"), 0.6)
        XCTAssertEqual(LenientAnalysis.confidence(fromText: "Medium-High"), 0.75)
    }

    func testProseStaysUnstructured() {
        let result = AnalysisResult.fromModelContent("A user-scoped LaunchAgent named x.")
        XCTAssertTrue(result.isUnstructured)
        XCTAssertEqual(result.summary, "A user-scoped LaunchAgent named x.")
    }

    func testPromptDemandsChineseAndPayloadUsesChineseStatus() throws {
        XCTAssertTrue(AnalysisPrompt.system.contains("简体中文"))
        var item = ServiceItem(id: "launchAgent:x", name: "x", sourceType: .launchAgent, scope: .user, label: "x")
        item.assessment = ReviewAssessment(status: .retain, confidence: 0.9, evidence: [])
        let payload = try AnalysisPayloadBuilder().make(for: item)
        XCTAssertTrue(payload.contains("规则判断：建议保留"))
        XCTAssertFalse(payload.contains("retain"))
    }

    func testStoredRawJSONSummaryIsReparsed() {
        let raw = #"{"summary":"中文摘要","dependencies":[],"risks":["r"],"projectUsefulness":"p","confidence":"0.7","evidence":[]}"#
        let broken = AnalysisRecord(
            serviceID: "a", analyzedAt: Date(), model: "m", summary: raw, dependencies: [], risks: [],
            projectUsefulness: "模型未返回结构化项目用途判断", confidence: 0,
            evidence: [AnalysisResult.unstructuredMarker], rawResponse: raw
        )
        let fixed = broken.reparsedIfNeeded()
        XCTAssertEqual(fixed.summary, "中文摘要")
        XCTAssertEqual(fixed.risks, ["r"])
        XCTAssertEqual(fixed.confidence, 0.7, accuracy: 0.001)
    }

    @MainActor
    func testKeysAreKeptPerProvider() throws {
        let keys = InMemoryProviderKeys()
        let viewModel = DashboardViewModel(
            inventory: EmptyInventory(),
            controller: nil,
            historyProvider: EmptyHistory(),
            aiConfigurationStore: MemoryAIConfigurationStore(),
            apiKeyStore: keys
        )
        let claude = AIModelConfiguration(
            providerID: "claude", enabled: true, baseURL: AIProviderPreset.claude.defaultBaseURL, model: "claude-opus-5-5"
        )
        let claudeValue = "claude-key"
        try viewModel.saveAIConfiguration(claude, apiKey: claudeValue)
        XCTAssertTrue(viewModel.aiKeyConfigured)
        XCTAssertTrue(viewModel.hasStoredAIKey(provider: "claude"))
        XCTAssertFalse(viewModel.hasStoredAIKey(provider: "deepSeek"))

        let deepSeek = AIModelConfiguration(
            providerID: "deepSeek", enabled: true, baseURL: AIProviderPreset.deepSeek.defaultBaseURL, model: "deepseek-chat"
        )
        try viewModel.saveAIConfiguration(deepSeek, apiKey: "")
        XCTAssertFalse(viewModel.aiKeyConfigured)
        XCTAssertFalse(viewModel.canExplainWithAI)
        XCTAssertEqual(keys.values["claude"], "claude-key")
        XCTAssertNil(keys.values["deepSeek"])
    }
}

private final class InMemoryProviderKeys: ProviderKeyStoring, @unchecked Sendable {
    var values: [String: String] = [:]
    func load(provider: String) throws -> String? { values[provider] }
    func save(_ key: String, provider: String) throws { values[provider] = key }
    func remove(provider: String) throws { values[provider] = nil }
}

private final class MemoryAIConfigurationStore: AIConfigurationStoring {
    var configuration = AIModelConfiguration()
    func load() -> AIModelConfiguration { configuration }
    func save(_ configuration: AIModelConfiguration) { self.configuration = configuration }
}

private struct EmptyInventory: ServiceInventoryProviding {
    func collect() async -> InventoryResult { InventoryResult(items: [], warnings: []) }
}

private struct EmptyHistory: OperationHistoryProviding {
    func fetchOperationRecords(serviceID: String?) throws -> [OperationRecord] { [] }
}

/// Env-gated: re-parses exported real analysis payloads (set TEST_RUNNER_AGENTSCOPE_ANALYSIS_DIR).
final class LiveAnalysisReparseTest: XCTestCase {
    func testStoredRecordsBecomeStructured() throws {
        guard let dir = ProcessInfo.processInfo.environment["AGENTSCOPE_ANALYSIS_DIR"] else { throw XCTSkip("no dir") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        for name in try FileManager.default.contentsOfDirectory(atPath: dir) where name.hasSuffix(".json") {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appending(path: name))
            guard let record = try? decoder.decode(AnalysisRecord.self, from: data) else { print("LIVEREPARSE \(name) undecodable"); continue }
            let fixed = record.reparsedIfNeeded()
            print("LIVEREPARSE \(name) unstructured=\(fixed.evidence == [AnalysisResult.unstructuredMarker]) conf=\(fixed.confidence) risks=\(fixed.risks.count) summary=\(fixed.summary.prefix(40))")
        }
    }
}
