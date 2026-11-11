import Foundation
import XCTest
@testable import AgentScopeCore

final class VendorGroupingTests: XCTestCase {
    func testToDeskComponentsCollapseIntoOneRowAcrossMechanisms() {
        let items = [
            item("launchagent:global:com.youqu.todesk.desktop", .launchAgent, vendor: "ToDesk", purpose: .remoteControl, state: .running),
            item("launchagent:global:com.youqu.todesk.client.startup", .launchAgent, vendor: "ToDesk", purpose: .remoteControl),
            item("launchdaemon:global:com.youqu.todesk.service", .launchDaemon, vendor: "ToDesk", purpose: .remoteControl, state: .running),
            item("launchdaemon:global:com.youqu.todesk.UninstallerHelper", .launchDaemon, vendor: "ToDesk", purpose: .remoteControl),
            item("launchdaemon:global:com.youqu.todesk.UninstallerWatcher", .launchDaemon, vendor: "ToDesk", purpose: .remoteControl),
            item("privilegedhelper:com.youqu.todesk.x", .privilegedHelper, vendor: "ToDesk", purpose: .remoteControl),
            item("launchagent:user:com.me.tunnel", .launchAgent, vendor: nil, purpose: .userScript)
        ]

        let groups = VendorGrouping.groups(from: items)

        XCTAssertEqual(groups.map(\.name), ["ToDesk", "com.me.tunnel"])
        let todesk = groups[0]
        XCTAssertEqual(todesk.items.count, 6)
        XCTAssertEqual(todesk.runningCount, 2)
        XCTAssertEqual(todesk.composition, "2 个LaunchAgent · 3 个LaunchDaemon · 1 个特权助手")
        XCTAssertEqual(todesk.purpose, .remoteControl)
    }

    func testDockerContainersGroupByComposeProject() {
        var web = item("docker:container:1", .docker, vendor: nil, purpose: .devTools, state: .running)
        web.project = ProjectIdentity(id: "compose:shop", displayName: "shop", rootPath: nil, kind: .dockerCompose, confidence: 1, evidence: [])
        var db = item("docker:container:2", .docker, vendor: nil, purpose: .devTools)
        db.project = web.project
        let loose = item("docker:container:3", .docker, vendor: nil, purpose: .devTools)

        let groups = VendorGrouping.groups(from: [web, db, loose])

        XCTAssertEqual(Set(groups.map(\.name)), ["Docker · shop", "Docker 独立容器"])
        XCTAssertEqual(groups.first { $0.name == "Docker · shop" }?.summary.hasPrefix("2 个 Docker 容器，1 个正在运行"), true)
    }

    func testLeftoverAndAttentionFlags() {
        var orphan = item("privilegedhelper:com.west2online.ClashX.ProxyConfigHelper", .privilegedHelper, vendor: "ClashX", purpose: .proxyVPN, state: .stale)
        orphan.ownerAppStatus = .missing
        orphan.assessment = ReviewAssessment(status: .possiblyStale, confidence: 0.85, evidence: [])
        var healthy = item("launchdaemon:global:party.mihomo.helper", .launchDaemon, vendor: "Mihomo Party", purpose: .proxyVPN, state: .running)
        healthy.assessment = ReviewAssessment(status: .retain, confidence: 0.9, evidence: [])

        let groups = VendorGrouping.groups(from: [orphan, healthy])

        XCTAssertEqual(groups.first { $0.name == "ClashX" }?.isLeftover, true)
        XCTAssertEqual(groups.first { $0.name == "ClashX" }?.needsAttention, true)
        XCTAssertEqual(groups.first { $0.name == "Mihomo Party" }?.needsAttention, false)
    }

    @MainActor
    func testViewModelPurposeFilterAndSidebarSelection() async {
        let items = [
            item("a", .launchDaemon, vendor: "ToDesk", purpose: .remoteControl),
            item("b", .launchAgent, vendor: "ToDesk", purpose: .remoteControl),
            item("c", .launchDaemon, vendor: "Docker Desktop", purpose: .devTools)
        ]
        let viewModel = DashboardViewModel(
            inventory: FixedInventory(items: items),
            controller: nil,
            historyProvider: EmptyHistoryProvider(),
            aiConfigurationStore: VendorTestAIConfigurationStore(),
            apiKeyStore: VendorTestAPIKeyStore()
        )
        await viewModel.refresh()

        XCTAssertEqual(viewModel.purposeCounts.map(\.purpose), [.remoteControl, .devTools])
        XCTAssertEqual(viewModel.purposeCounts.map(\.count), [1, 1])

        viewModel.sidebarSelection = .purpose(.remoteControl)
        XCTAssertTrue(viewModel.showsVendorGroups)
        XCTAssertEqual(viewModel.visibleVendorGroups.map(\.name), ["ToDesk"])

        viewModel.sidebarSelection = .source(.automaticStartup)
        XCTAssertNil(viewModel.purposeFilter)
        XCTAssertFalse(viewModel.showsVendorGroups)
        XCTAssertEqual(viewModel.visibleItems.count, 3)

        viewModel.sidebarSelection = .source(.all)
        viewModel.searchText = "远程"
        XCTAssertEqual(viewModel.visibleVendorGroups.map(\.name), ["ToDesk"])
    }

    @MainActor
    func testBatchAIExplanationOnlyTouchesRuleItemsAndSurvivesRefresh() async {
        var ruleItem = item("launchagent:user:com.unknown.agent", .launchAgent, vendor: nil, purpose: .unknown)
        ruleItem.summarySource = .rule
        var known = item("launchdaemon:global:todesk", .launchDaemon, vendor: "ToDesk", purpose: .remoteControl)
        known.summarySource = .knowledgeBase
        let store = MemoryAnalysisStore()
        let viewModel = DashboardViewModel(
            inventory: FixedInventory(items: [ruleItem, known]),
            controller: nil,
            historyProvider: EmptyHistoryProvider(),
            analysisProvider: EchoAnalysisProvider(),
            analysisStore: store,
            aiConfigurationStore: VendorTestAIConfigurationStore(),
            apiKeyStore: VendorTestAPIKeyStore()
        )
        await viewModel.refresh()
        XCTAssertEqual(viewModel.unexplainedItems.map(\.id), [ruleItem.id])

        await viewModel.explainUnidentifiedWithAI()

        XCTAssertNil(viewModel.batchExplainProgress)
        XCTAssertTrue(viewModel.unexplainedItems.isEmpty)
        XCTAssertEqual(viewModel.items.first { $0.id == ruleItem.id }?.summary, "AI: com.unknown.agent")
        XCTAssertEqual(viewModel.items.first { $0.id == known.id }?.summarySource, .knowledgeBase)

        await viewModel.refresh()
        XCTAssertEqual(viewModel.items.first { $0.id == ruleItem.id }?.summarySource, .ai)
    }

    private func item(
        _ id: String,
        _ source: SourceType,
        vendor: String?,
        purpose: PurposeCategory,
        state: ServiceState = .stopped
    ) -> ServiceItem {
        ServiceItem(
            id: id,
            name: id.components(separatedBy: ":").last ?? id,
            sourceType: source,
            scope: .global,
            state: state,
            vendorName: vendor,
            purpose: purpose,
            summary: vendor.map { "\($0) \(purpose.displayName)说明" } ?? "自建脚本"
        )
    }
}

private struct FixedInventory: ServiceInventoryProviding {
    let items: [ServiceItem]

    func collect() async -> InventoryResult {
        InventoryResult(items: items, warnings: [])
    }
}

private struct EmptyHistoryProvider: OperationHistoryProviding {
    func fetchOperationRecords(serviceID: String?) throws -> [OperationRecord] { [] }
}

private struct VendorTestAIConfigurationStore: AIConfigurationStoring {
    func load() -> AIModelConfiguration { AIModelConfiguration() }
    func save(_ configuration: AIModelConfiguration) {}
}

private struct VendorTestAPIKeyStore: APIKeyStoring {
    func load() throws -> String? { nil }
    func save(_ key: String) throws {}
    func remove() throws {}
}

private struct EchoAnalysisProvider: AnalysisProvider {
    func analyze(_ item: ServiceItem, options: AnalysisOptions) async throws -> AnalysisResult {
        AnalysisResult(summary: "AI: \(item.name)", dependencies: [], risks: [], projectUsefulness: "", confidence: 0.7, evidence: [], rawResponse: nil)
    }
}

private final class MemoryAnalysisStore: @unchecked Sendable, AnalysisResultStoring {
    private var records: [String: AnalysisRecord] = [:]

    func saveLatestAnalysis(_ record: AnalysisRecord) throws {
        records[record.serviceID] = record
    }

    func fetchLatestAnalysis(serviceID: String) throws -> AnalysisRecord? {
        records[serviceID]
    }
}
