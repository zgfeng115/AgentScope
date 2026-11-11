import XCTest
@testable import AgentScopeCore

final class AnalysisProviderTests: XCTestCase {
    func testAIModelConfigurationDefaultsToDisabledOpenAICompatibleSettings() {
        let configuration = AIModelConfiguration()

        XCTAssertFalse(configuration.enabled)
        XCTAssertEqual(configuration.baseURL.absoluteString, "https://api.openai.com/v1")
        XCTAssertEqual(configuration.model, "")
        XCTAssertEqual(configuration.timeout, 60)
    }

    func testAnalysisPayloadRedactsSecretsAndIncludesLimitedSourceContent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AgentScopeAnalysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configurationURL = directory.appending(path: "service.sh")
        try "TOKEN=secret-value\nnohup /usr/bin/true &\n".write(
            to: configurationURL,
            atomically: true,
            encoding: .utf8
        )

        let item = ServiceItem(
            id: "shellstartup:user:service.sh:1",
            name: "true",
            sourceType: .shellStartup,
            scope: .user,
            configurationPath: configurationURL.path,
            programPath: "/usr/bin/true",
            triggers: [TriggerInfo(kind: .shellStartup, summary: "Shell 启动")],
            assessment: ReviewAssessment(status: .unclear, confidence: 0.45, evidence: ["需要确认"])
        )

        let payload = try AnalysisPayloadBuilder().make(for: item)

        XCTAssertTrue(payload.contains("service.sh"))
        XCTAssertTrue(payload.contains("[REDACTED]"))
        XCTAssertFalse(payload.contains("secret-value"))
        XCTAssertTrue(payload.contains("nohup /usr/bin/true"))
    }

    func testLocalStoreReplacesLatestAnalysisForSameService() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AgentScopeAnalysisStore-\(UUID().uuidString)")
        let store = try LocalStore(directoryURL: directory)
        let first = AnalysisRecord(
            serviceID: "launchagent:user:demo",
            analyzedAt: Date(timeIntervalSince1970: 100),
            model: "model-a",
            summary: "first",
            dependencies: [],
            risks: ["old"],
            projectUsefulness: "unknown",
            confidence: 0.4,
            evidence: []
        )
        let second = AnalysisRecord(
            serviceID: first.serviceID,
            analyzedAt: Date(timeIntervalSince1970: 200),
            model: "model-b",
            summary: "second",
            dependencies: [],
            risks: ["new"],
            projectUsefulness: "useful",
            confidence: 0.9,
            evidence: []
        )

        try store.saveLatestAnalysis(first)
        try store.saveLatestAnalysis(second)

        let stored = try XCTUnwrap(store.fetchLatestAnalysis(serviceID: first.serviceID))
        XCTAssertEqual(stored.summary, "second")
        XCTAssertEqual(stored.model, "model-b")
        XCTAssertEqual(stored.risks, ["new"])
    }

    func testLocalRuleAnalysisWorksWithoutCloudPermission() async throws {
        let item = ServiceItem(
            id: "cron:user:test",
            name: "test",
            sourceType: .cron,
            scope: .user,
            programPath: "/usr/bin/true",
            assessment: ReviewAssessment(status: .retain, confidence: 0.8, evidence: ["valid"])
        )

        let result = try await RuleAnalysisProvider().analyze(item, options: AnalysisOptions())

        XCTAssertEqual(result.confidence, 0.8)
        XCTAssertTrue(result.summary.contains("保留"))
    }

    func testCloudModeRequiresExplicitPermission() async {
        let item = ServiceItem(id: "item", name: "item", sourceType: .unknown, scope: .user)
        do {
            _ = try await RuleAnalysisProvider().analyze(
                item,
                options: AnalysisOptions(mode: .cloud, allowCloud: false)
            )
            XCTFail("Expected cloud permission error")
        } catch AnalysisProviderError.cloudNotEnabled {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRedactorRemovesCommonSecretForms() {
        let text = "TOKEN=abc123 password: hunter2 api_key=secret"
        let redacted = AnalysisRedactor.redact(text)
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertTrue(redacted.contains("[REDACTED]"))
    }

    func testOpenAIProviderRejectsMissingModelBeforeSendingRequest() async {
        let provider = OpenAICompatibleAnalysisProvider(
            configuration: AIModelConfiguration(enabled: true, model: ""),
            apiKey: "test-key"
        )
        let item = ServiceItem(id: "item", name: "item", sourceType: .cron, scope: .user)

        do {
            _ = try await provider.analyze(item)
            XCTFail("Expected invalid configuration")
        } catch AnalysisProviderError.invalidConfiguration {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
