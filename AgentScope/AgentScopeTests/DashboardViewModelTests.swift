import Foundation
import XCTest
@testable import AgentScopeCore

@MainActor
final class DashboardViewModelTests: XCTestCase {
    func testFilteringBySourceAndSearch() async {
        let launchAgent = makeItem(
            id: "launchagent:user:worker",
            name: "Python Worker",
            sourceType: .launchAgent,
            scope: .user
        )
        let process = makeItem(
            id: "process:42",
            name: "python3",
            sourceType: .process,
            scope: .user
        )
        let system = makeItem(
            id: "system:launchd",
            name: "launchd",
            sourceType: .process,
            scope: .system,
            state: .systemReadonly
        )
        let viewModel = makeViewModel(items: [launchAgent, process, system])

        await viewModel.refresh()
        viewModel.sourceFilter = .launchAgents
        viewModel.searchText = "worker"

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [launchAgent.id])
    }

    func testSystemItemHasNoMutationActions() async {
        let system = makeItem(
            id: "system:launchd",
            name: "launchd",
            sourceType: .process,
            scope: .system,
            state: .systemReadonly
        )
        let viewModel = makeViewModel(items: [system])

        await viewModel.refresh()

        XCTAssertTrue(viewModel.availableActions(for: system).isEmpty)
    }

    func testRefreshPreservesSelectionWhenItemRemains() async {
        let item = makeItem(id: "launchagent:user:worker", name: "Worker", sourceType: .launchAgent, scope: .user)
        let viewModel = makeViewModel(items: [item])

        await viewModel.refresh()
        viewModel.selectedServiceID = item.id
        await viewModel.refresh()

        XCTAssertEqual(viewModel.selectedServiceID, item.id)
    }

    func testRefreshClearsSelectionWhenItemDisappears() async {
        let item = makeItem(id: "launchagent:user:worker", name: "Worker", sourceType: .launchAgent, scope: .user)
        let inventory = SequenceInventory(results: [
            InventoryResult(items: [item], warnings: []),
            InventoryResult(items: [], warnings: [])
        ])
        let viewModel = DashboardViewModel(
            inventory: inventory,
            controller: nil,
            historyProvider: FixedHistoryProvider(records: [])
        )

        await viewModel.refresh()
        viewModel.selectedServiceID = item.id
        await viewModel.refresh()

        XCTAssertNil(viewModel.selectedServiceID)
    }

    func testPartialCollectorFailureIsVisible() async {
        let item = makeItem(id: "launchagent:user:worker", name: "Worker", sourceType: .launchAgent, scope: .user)
        let viewModel = makeViewModel(items: [item], warnings: ["process scan failed"])

        await viewModel.refresh()

        XCTAssertEqual(viewModel.loadState, .partiallyFailed)
        XCTAssertEqual(viewModel.warnings, ["process scan failed"])
    }

    func testStartupOverviewWarningsStayScopedWithoutHidingOtherFailures() async {
        let viewModel = makeViewModel(
            items: [],
            warnings: [
                "Login Items unavailable: denied",
                "Embedded Login Items unavailable: unreadable app",
                "Unable to read user crontab: denied"
            ]
        )

        await viewModel.refresh()

        XCTAssertEqual(
            viewModel.startupOverviewWarnings,
            ["Login Items unavailable: denied", "Embedded Login Items unavailable: unreadable app"]
        )
        XCTAssertEqual(viewModel.globalWarnings, ["Unable to read user crontab: denied"])
    }

    func testSystemActionDoesNotCallController() async {
        let system = makeItem(
            id: "system:launchd",
            name: "launchd",
            sourceType: .process,
            scope: .system,
            state: .systemReadonly
        )
        let controller = RecordingController()
        let viewModel = DashboardViewModel(
            inventory: FixedInventory(result: InventoryResult(items: [system], warnings: [])),
            controller: controller,
            historyProvider: FixedHistoryProvider(records: [])
        )

        await viewModel.perform(.stop, on: system)

        let actions = await controller.actions
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNotNil(viewModel.actionError)
    }

    func testAuditFiltersAndProjectGroups() async {
        let project = ProjectIdentity(
            id: "git:/Users/test/demo",
            displayName: "demo",
            rootPath: "/Users/test/demo",
            kind: .gitRepository,
            confidence: 0.9,
            evidence: ["fixture"]
        )
        let startup = ServiceItem(
            id: "launchagent:user:worker",
            name: "worker",
            sourceType: .launchAgent,
            scope: .user,
            project: project
        )
        let cron = ServiceItem(
            id: "cron:user:daily",
            name: "daily",
            sourceType: .cron,
            scope: .user,
            project: project
        )
        let viewModel = makeViewModel(items: [startup, cron])

        await viewModel.refresh()
        viewModel.sourceFilter = .scheduledTasks
        XCTAssertEqual(viewModel.visibleItems.map(\.id), [cron.id])
        XCTAssertEqual(viewModel.projectGroups.count, 1)
        XCTAssertEqual(viewModel.projectGroups.first?.items.count, 2)
        XCTAssertEqual(viewModel.count(for: .projects), 1)
    }

    func testManualAIAnalysisStoresLatestResult() async {
        let item = makeItem(
            id: "cron:user:daily",
            name: "daily",
            sourceType: .cron,
            scope: .user
        )
        let store = InMemoryAnalysisStore()
        let result = AnalysisResult(
            summary: "需要确认",
            dependencies: ["/usr/bin/python3"],
            risks: ["未找到项目归属"],
            projectUsefulness: "可能属于 demo",
            confidence: 0.7,
            evidence: ["来自测试提供商"]
        )
        let viewModel = DashboardViewModel(
            inventory: FixedInventory(result: InventoryResult(items: [item], warnings: [])),
            controller: nil,
            historyProvider: FixedHistoryProvider(records: []),
            analysisProvider: StubAnalysisProvider(result: result),
            analysisStore: store,
            aiConfigurationStore: FixedAIConfigurationStore(configuration: AIModelConfiguration(model: "test-model")),
            apiKeyStore: FixedAPIKeyStore(key: "test-key")
        )

        await viewModel.analyze(item)

        XCTAssertEqual(viewModel.analysis(for: item.id)?.summary, "需要确认")
        XCTAssertEqual(try store.fetchLatestAnalysis(serviceID: item.id)?.model, "test-model")
    }

    func testSystemReadonlyFilterExcludesUserLevelReadonlyRecords() async {
        let loginItem = makeItem(
            id: "loginitem:user:helper",
            name: "Helper",
            sourceType: .loginItem,
            scope: .user,
            state: .systemReadonly
        )
        let systemItem = makeItem(
            id: "launchdaemon:system:helper",
            name: "System Helper",
            sourceType: .launchDaemon,
            scope: .system,
            state: .systemReadonly
        )
        let viewModel = makeViewModel(items: [loginItem, systemItem])

        await viewModel.refresh()
        viewModel.sourceFilter = .systemReadonly

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [systemItem.id])
    }

    func testLoginItemsWithSameBundleIdentifierFormPartiallyEnabledGroup() async {
        let enabled = makeItem(
            id: "loginitem:user:example-main",
            name: "Example",
            sourceType: .loginItem,
            scope: .user,
            state: .enabled,
            label: "com.example.app",
            programPath: "/Applications/Example.app"
        )
        let disabled = makeItem(
            id: "loginitem:user:example-helper",
            name: "Example Helper",
            sourceType: .loginItem,
            scope: .user,
            state: .disabled,
            label: "com.example.app",
            programPath: "/Applications/Example.app/Contents/Library/LoginItems/Helper.app"
        )
        let viewModel = makeViewModel(items: [disabled, enabled])

        await viewModel.refresh()

        let group = viewModel.visibleLoginItemGroups.only
        XCTAssertEqual(group?.id, "bundle:com.example.app")
        XCTAssertEqual(group?.bundleIdentifier, "com.example.app")
        XCTAssertEqual(group?.items.map(\.id), [enabled.id, disabled.id])
        XCTAssertEqual(group?.enabledState, .partiallyEnabled)
    }

    func testNestedLoginItemHelperUsesHostApplicationIdentity() async {
        let host = makeItem(
            id: "loginitem:user:host",
            name: "Host",
            sourceType: .loginItem,
            scope: .user,
            label: "com.example.host",
            programPath: "/Applications/Host.app"
        )
        let helper = makeItem(
            id: "loginitem:user:helper",
            name: "Helper",
            sourceType: .loginItem,
            scope: .user,
            label: "com.example.helper",
            programPath: "/Applications/Host.app/Contents/Library/LoginItems/Helper.app"
        )
        let viewModel = makeViewModel(items: [helper, host])

        await viewModel.refresh()

        let group = viewModel.visibleLoginItemGroups.only
        XCTAssertEqual(group?.id, "bundle:com.example.host")
        XCTAssertEqual(group?.applicationPath, "/Applications/Host.app")
        XCTAssertEqual(group?.bundleIdentifier, "com.example.host")
        XCTAssertEqual(group?.items.map(\.id), [helper.id, host.id])
    }

    func testEmbeddedHelpersWithoutHostRecordGroupByHostApplicationPath() async {
        let first = makeItem(
            id: "embedded:first",
            name: "First Helper",
            sourceType: .embeddedLoginItem,
            scope: .system,
            state: .discovered,
            label: "com.example.host.first-helper",
            programPath: "/Applications/Host.app/Contents/Library/LoginItems/First.app"
        )
        let second = makeItem(
            id: "embedded:second",
            name: "Second Helper",
            sourceType: .embeddedLoginItem,
            scope: .system,
            state: .discovered,
            label: "com.example.host.second-helper",
            programPath: "/Applications/Host.app/Contents/Library/LoginItems/Second.app"
        )
        let viewModel = makeViewModel(items: [second, first])

        await viewModel.refresh()

        let group = viewModel.visibleLoginItemGroups.only
        XCTAssertEqual(group?.id, "path:/Applications/Host.app")
        XCTAssertEqual(group?.applicationPath, "/Applications/Host.app")
        XCTAssertEqual(group?.applicationName, "Host")
        XCTAssertNil(group?.bundleIdentifier)
        XCTAssertEqual(group?.items.map(\.id), [first.id, second.id])
    }

    func testLoginItemCountUsesApplicationGroupsWithoutChangingOtherCounts() async {
        let first = makeItem(
            id: "loginitem:user:example-main",
            name: "Example",
            sourceType: .loginItem,
            scope: .user,
            label: "com.example.app"
        )
        let second = makeItem(
            id: "loginitem:user:example-helper",
            name: "Helper",
            sourceType: .loginItem,
            scope: .user,
            label: "com.example.app"
        )
        let startup = makeItem(id: "launchagent:user:worker", name: "Worker", sourceType: .launchAgent, scope: .user)
        let viewModel = makeViewModel(items: [first, second, startup])

        await viewModel.refresh()

        XCTAssertEqual(viewModel.count(for: .loginItems), 2)
        XCTAssertEqual(viewModel.count(for: .automaticStartup), 1)
    }

    func testStartupOverviewGroupsLegacyLaunchAgentAndEmbeddedHelperByHostApplication() async {
        let legacyLoginItem = makeItem(
            id: "loginitem:user:host",
            name: "Host",
            sourceType: .loginItem,
            scope: .user,
            label: "com.example.host",
            programPath: "/Applications/Host.app"
        )
        let launchAgent = makeItem(
            id: "launchagent:user:host",
            name: "Host Agent",
            sourceType: .launchAgent,
            scope: .user,
            label: "com.example.host",
            configurationPath: "/Users/test/Library/LaunchAgents/com.example.host.plist"
        )
        let embeddedHelper = makeItem(
            id: "embeddedLoginItem:/Applications/Host.app:/Applications/Host.app/Contents/Library/LoginItems/Helper.app",
            name: "Helper",
            sourceType: .embeddedLoginItem,
            scope: .user,
            label: "com.example.host.helper",
            programPath: "/Applications/Host.app/Contents/Library/LoginItems/Helper.app"
        )
        let unrelatedLaunchAgent = makeItem(
            id: "launchagent:user:other",
            name: "Other Agent",
            sourceType: .launchAgent,
            scope: .user,
            label: "com.example.other"
        )
        let viewModel = makeViewModel(items: [
            embeddedHelper,
            unrelatedLaunchAgent,
            launchAgent,
            legacyLoginItem
        ])

        await viewModel.refresh()
        viewModel.sourceFilter = .loginItems

        XCTAssertEqual(
            viewModel.visibleItems.map(\.id),
            [embeddedHelper.id, legacyLoginItem.id, launchAgent.id, unrelatedLaunchAgent.id]
        )
        XCTAssertEqual(viewModel.visibleLoginItemGroups.map(\.id), ["bundle:com.example.host", "bundle:com.example.other"])
        XCTAssertEqual(
            viewModel.visibleLoginItemGroups.first?.items.map(\.sourceType),
            [.embeddedLoginItem, .loginItem, .launchAgent]
        )
        XCTAssertEqual(viewModel.count(for: .loginItems), 2)
        XCTAssertEqual(viewModel.count(for: .automaticStartup), 2)
    }

    func testLoginItemGroupSearchMatchesGroupAndChildFields() async {
        let project = ProjectIdentity(
            id: "git:/Users/test/client-project",
            displayName: "Client Project",
            rootPath: "/Users/test/client-project",
            kind: .gitRepository,
            confidence: 1,
            evidence: []
        )
        let item = ServiceItem(
            id: "loginitem:user:example",
            name: "Example Helper",
            sourceType: .loginItem,
            scope: .user,
            label: "com.example.app",
            programPath: "/Applications/Example.app",
            project: project
        )
        let viewModel = makeViewModel(items: [item])

        await viewModel.refresh()

        for query in ["example", "com.example", "client project", "/Users/test/client-project", "helper"] {
            viewModel.searchText = query
            XCTAssertEqual(viewModel.visibleLoginItemGroups.map(\.id), ["bundle:com.example.app"], "query: \(query)")
        }
    }

    func testLoginItemsFromDifferentApplicationsDoNotMerge() async {
        let alpha = makeItem(
            id: "loginitem:user:alpha",
            name: "Alpha",
            sourceType: .loginItem,
            scope: .user,
            programPath: "/Applications/Alpha.app"
        )
        let beta = makeItem(
            id: "loginitem:user:beta",
            name: "Beta",
            sourceType: .loginItem,
            scope: .user,
            programPath: "/Applications/Beta.app"
        )
        let viewModel = makeViewModel(items: [beta, alpha])

        await viewModel.refresh()

        XCTAssertEqual(viewModel.visibleLoginItemGroups.map(\.id), ["path:/Applications/Alpha.app", "path:/Applications/Beta.app"])
    }

    func testLoginItemsWithoutBundleIdentifierUseNormalizedApplicationPath() async {
        let main = makeItem(
            id: "loginitem:user:example-main",
            name: "Example",
            sourceType: .loginItem,
            scope: .user,
            programPath: " /Applications/Example.app/// "
        )
        let helper = makeItem(
            id: "loginitem:user:example-helper",
            name: "Helper",
            sourceType: .loginItem,
            scope: .user,
            configurationPath: "/Applications/Example.app/Contents/Library/LoginItems/helper"
        )
        let viewModel = makeViewModel(items: [helper, main])

        await viewModel.refresh()

        let group = viewModel.visibleLoginItemGroups.only
        XCTAssertEqual(group?.id, "path:/Applications/Example.app")
        XCTAssertEqual(group?.applicationPath, "/Applications/Example.app")
        XCTAssertEqual(group?.items.map(\.id), [main.id, helper.id])
    }

    func testLoginItemGroupWithNoEnabledOrDisabledChildrenIsUnknown() async {
        let invalid = makeItem(
            id: "loginitem:user:unknown",
            name: "Unknown",
            sourceType: .loginItem,
            scope: .user,
            state: .failed
        )
        let viewModel = makeViewModel(items: [invalid])

        await viewModel.refresh()

        XCTAssertEqual(viewModel.visibleLoginItemGroups.only?.enabledState, .unknown)
    }

    func testKnownEnabledStateSurvivesDiscoveredStoppedAndFailedChildren() async {
        let states: [ServiceState] = [.enabled, .discovered, .stopped, .failed]
        let items = states.enumerated().map { index, state in
            makeItem(
                id: "loginitem:mixed:\(index)",
                name: "Mixed \(index)",
                sourceType: index == 1 ? .embeddedLoginItem : .loginItem,
                scope: .user,
                state: state,
                label: "com.example.mixed"
            )
        }
        let viewModel = makeViewModel(items: items)

        await viewModel.refresh()

        let group = viewModel.visibleLoginItemGroups.only
        XCTAssertEqual(group?.enabledState, .enabled)
        XCTAssertEqual(group?.stateSummary, "已发现、已启用、已停止、失败")
    }

    func testRunningLoginItemsAreEnabledAndMixedWithDisabledArePartiallyEnabled() async {
        let running = makeItem(
            id: "loginitem:user:running",
            name: "Running",
            sourceType: .loginItem,
            scope: .user,
            state: .running,
            label: "com.example.running"
        )
        let disabled = makeItem(
            id: "loginitem:user:disabled",
            name: "Disabled",
            sourceType: .loginItem,
            scope: .user,
            state: .disabled,
            label: "com.example.mixed"
        )
        let mixedRunning = makeItem(
            id: "loginitem:user:mixed-running",
            name: "Mixed Running",
            sourceType: .loginItem,
            scope: .user,
            state: .running,
            label: "com.example.mixed"
        )
        let viewModel = makeViewModel(items: [running, disabled, mixedRunning])

        await viewModel.refresh()

        XCTAssertEqual(
            viewModel.visibleLoginItemGroups.first(where: { $0.id == "bundle:com.example.running" })?.enabledState,
            .enabled
        )
        XCTAssertEqual(
            viewModel.visibleLoginItemGroups.first(where: { $0.id == "bundle:com.example.mixed" })?.enabledState,
            .partiallyEnabled
        )
    }

    func testDuplicateDisplayNamesUseIDsAsDeterministicSortTieBreakers() async {
        let firstProject = ProjectIdentity(
            id: "project:a",
            displayName: "Duplicate Project",
            rootPath: "/Projects/a",
            kind: .gitRepository,
            confidence: 1,
            evidence: []
        )
        let secondProject = ProjectIdentity(
            id: "project:b",
            displayName: "Duplicate Project",
            rootPath: "/Projects/b",
            kind: .gitRepository,
            confidence: 1,
            evidence: []
        )
        let items = [
            ServiceItem(id: "visible:b", name: "Duplicate", sourceType: .process, scope: .user),
            ServiceItem(id: "visible:a", name: "Duplicate", sourceType: .process, scope: .user),
            ServiceItem(id: "project-b:child:b", name: "Duplicate Child", sourceType: .process, scope: .user, project: secondProject),
            ServiceItem(id: "project-b:child:a", name: "Duplicate Child", sourceType: .process, scope: .user, project: secondProject),
            ServiceItem(id: "project-a:child:b", name: "Duplicate Child", sourceType: .process, scope: .user, project: firstProject),
            ServiceItem(id: "project-a:child:a", name: "Duplicate Child", sourceType: .process, scope: .user, project: firstProject),
            ServiceItem(id: "loginitem:user:b", name: "Duplicate Login Item", sourceType: .loginItem, scope: .user),
            ServiceItem(id: "loginitem:user:a", name: "Duplicate Login Item", sourceType: .loginItem, scope: .user)
        ]
        let viewModel = makeViewModel(items: items)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.visibleItems.map(\.id), [
            "visible:a", "visible:b", "project-a:child:a", "project-a:child:b",
            "project-b:child:a", "project-b:child:b", "loginitem:user:a", "loginitem:user:b"
        ])
        XCTAssertEqual(viewModel.projectGroups.map(\.id), ["project:a", "project:b"])
        XCTAssertEqual(viewModel.projectGroups[0].items.map(\.id), ["project-a:child:a", "project-a:child:b"])
        XCTAssertEqual(viewModel.projectGroups[1].items.map(\.id), ["project-b:child:a", "project-b:child:b"])
        XCTAssertEqual(viewModel.visibleLoginItemGroups.map(\.id), ["item:loginitem:user:a", "item:loginitem:user:b"])
    }

    func testStartupOverviewSortControlsGroupOrderStably() async {
        let legacy = makeItem(
            id: "legacy",
            name: "Legacy",
            sourceType: .loginItem,
            scope: .user,
            state: .disabled,
            programPath: "/Applications/Legacy.app"
        )
        let agent = makeItem(
            id: "agent",
            name: "Agent",
            sourceType: .launchAgent,
            scope: .user,
            state: .enabled
        )
        let embedded = makeItem(
            id: "embedded",
            name: "Embedded Helper",
            sourceType: .embeddedLoginItem,
            scope: .system,
            state: .failed,
            programPath: "/Applications/Embedded.app/Contents/Library/LoginItems/Helper.app"
        )
        let viewModel = makeViewModel(items: [legacy, agent, embedded])

        await viewModel.refresh()

        viewModel.sort = .name
        XCTAssertEqual(viewModel.visibleLoginItemGroups.map(\.applicationName), ["Agent", "Embedded", "Legacy"])

        viewModel.sort = .source
        XCTAssertEqual(viewModel.visibleLoginItemGroups.map(\.applicationName), ["Legacy", "Agent", "Embedded"])

        viewModel.sort = .state
        XCTAssertEqual(viewModel.visibleLoginItemGroups.map(\.applicationName), ["Agent", "Legacy", "Embedded"])
    }

    func testStartupOverviewSortControlsChildrenWithStableIDTieBreakers() async {
        let host = makeItem(
            id: "host",
            name: "Zulu",
            sourceType: .loginItem,
            scope: .user,
            state: .enabled,
            label: "com.example.host",
            programPath: "/Applications/Host.app"
        )
        let agent = makeItem(
            id: "agent",
            name: "Middle",
            sourceType: .launchAgent,
            scope: .user,
            state: .disabled,
            label: "com.example.host"
        )
        let helperB = makeItem(
            id: "helper:b",
            name: "Alpha",
            sourceType: .embeddedLoginItem,
            scope: .system,
            state: .discovered,
            label: "com.example.helper.b",
            programPath: "/Applications/Host.app/Contents/Library/LoginItems/B.app"
        )
        let helperA = makeItem(
            id: "helper:a",
            name: "Alpha",
            sourceType: .embeddedLoginItem,
            scope: .system,
            state: .discovered,
            label: "com.example.helper.a",
            programPath: "/Applications/Host.app/Contents/Library/LoginItems/A.app"
        )
        let viewModel = makeViewModel(items: [helperB, agent, host, helperA])

        await viewModel.refresh()

        viewModel.sort = .name
        XCTAssertEqual(viewModel.visibleLoginItemGroups.only?.items.map(\.id), [helperA.id, helperB.id, agent.id, host.id])

        viewModel.sort = .source
        XCTAssertEqual(viewModel.visibleLoginItemGroups.only?.items.map(\.id), [host.id, agent.id, helperA.id, helperB.id])

        viewModel.sort = .state
        XCTAssertEqual(viewModel.visibleLoginItemGroups.only?.items.map(\.id), [host.id, helperA.id, helperB.id, agent.id])
    }

    private func makeViewModel(items: [ServiceItem], warnings: [String] = []) -> DashboardViewModel {
        DashboardViewModel(
            inventory: FixedInventory(result: InventoryResult(items: items, warnings: warnings)),
            controller: nil,
            historyProvider: FixedHistoryProvider(records: [])
        )
    }

    private func makeItem(
        id: String,
        name: String,
        sourceType: SourceType,
        scope: Scope,
        state: ServiceState = .stopped,
        label: String? = nil,
        configurationPath: String? = nil,
        programPath: String? = nil
    ) -> ServiceItem {
        ServiceItem(
            id: id,
            name: name,
            sourceType: sourceType,
            scope: scope,
            label: label,
            configurationPath: configurationPath,
            programPath: programPath,
            state: state
        )
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private struct FixedInventory: ServiceInventoryProviding {
    let result: InventoryResult

    func collect() async -> InventoryResult {
        result
    }
}

private actor SequenceInventory: ServiceInventoryProviding {
    private var results: [InventoryResult]

    init(results: [InventoryResult]) {
        self.results = results
    }

    func collect() async -> InventoryResult {
        if results.count > 1 {
            return results.removeFirst()
        }
        return results.first ?? InventoryResult(items: [], warnings: [])
    }
}

private actor RecordingController: ServiceControlling {
    var actions: [OperationAction] = []

    func start(_ item: ServiceItem) async throws {
        actions.append(.start)
    }

    func stop(_ item: ServiceItem) async throws {
        actions.append(.stop)
    }

    func restart(_ item: ServiceItem) async throws {
        actions.append(.restart)
    }

    func setEnabled(_ enabled: Bool, for item: ServiceItem) async throws {
        actions.append(enabled ? .enable : .disable)
    }

    func testRun(_ item: ServiceItem) async throws {
        actions.append(.testRun)
    }
}

private struct FixedHistoryProvider: OperationHistoryProviding {
    let records: [OperationRecord]

    func fetchOperationRecords(serviceID: String?) throws -> [OperationRecord] {
        records
    }
}

private struct StubAnalysisProvider: AnalysisProvider {
    let result: AnalysisResult

    func analyze(_ item: ServiceItem, options: AnalysisOptions) async throws -> AnalysisResult {
        result
    }
}

private final class InMemoryAnalysisStore: @unchecked Sendable, AnalysisResultStoring {
    private var records: [String: AnalysisRecord] = [:]

    func saveLatestAnalysis(_ record: AnalysisRecord) throws {
        records[record.serviceID] = record
    }

    func fetchLatestAnalysis(serviceID: String) throws -> AnalysisRecord? {
        records[serviceID]
    }
}

private struct FixedAIConfigurationStore: AIConfigurationStoring {
    let configuration: AIModelConfiguration

    func load() -> AIModelConfiguration { configuration }
    func save(_ configuration: AIModelConfiguration) {}
}

private struct FixedAPIKeyStore: APIKeyStoring {
    let key: String?

    func load() throws -> String? { key }
    func save(_ key: String) throws {}
    func remove() throws {}
}
