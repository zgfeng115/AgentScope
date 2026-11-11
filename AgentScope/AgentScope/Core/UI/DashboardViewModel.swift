import Combine
import Foundation

@MainActor
public final class DashboardViewModel: ObservableObject {
    @Published public private(set) var items: [ServiceItem] = []
    @Published public private(set) var warnings: [String] = []
    @Published public private(set) var loadState: DashboardLoadState = .idle
    @Published public var sourceFilter: SourceFilter = .all
    @Published public var purposeFilter: PurposeCategory?
    @Published public var searchText = ""
    @Published public var sort: ServiceSort = .name
    @Published public var selectedServiceID: String?
    @Published public private(set) var operatingServiceID: String?
    @Published public private(set) var analyzingServiceID: String?
    @Published public private(set) var aiConfiguration: AIModelConfiguration
    @Published public private(set) var aiKeyConfigured: Bool
    @Published public private(set) var analysisResults: [String: AnalysisRecord] = [:]
    @Published public var actionError: String?
    @Published public private(set) var deepScanInProgress = false
    @Published public private(set) var lastDeepScanAt: Date?
    @Published public var deepScanError: String?
    @Published public private(set) var batchExplainProgress: (done: Int, total: Int)?
    @Published public var batchExplainMessage: String?
    private var batchCancelRequested = false
    @Published public internal(set) var uninstallInProgress = false
    @Published public var uninstallMessage: String?
    @Published public internal(set) var logLastRuns: [String: LogLastRun] = [:]
    @Published public internal(set) var logQueryInProgress: String?

    private let inventory: any ServiceInventoryProviding
    private let controller: (any ServiceControlling)?
    private let historyProvider: any OperationHistoryProviding
    private var analysisProvider: (any AnalysisProvider)?
    private let deepScanner: (any DeepScanning)?
    private let analysisStore: (any AnalysisResultStoring)?
    private let aiConfigurationStore: any AIConfigurationStoring
    private let apiKeyStore: any ProviderKeyStoring
    let uninstaller: (any Uninstalling)?
    let operationRecorder: (any OperationRecording)?
    let backgroundTaskStore: BackgroundTaskStore?
    let logQuery: (any LaunchdLogQuerying)?

    public init(
        inventory: any ServiceInventoryProviding,
        controller: (any ServiceControlling)?,
        historyProvider: any OperationHistoryProviding,
        analysisProvider: (any AnalysisProvider)? = nil,
        analysisStore: (any AnalysisResultStoring)? = nil,
        aiConfigurationStore: any AIConfigurationStoring = UserDefaultsAIConfigurationStore(),
        apiKeyStore: any ProviderKeyStoring = KeychainProviderKeyStore(),
        deepScanner: (any DeepScanning)? = nil,
        uninstaller: (any Uninstalling)? = nil,
        operationRecorder: (any OperationRecording)? = nil,
        backgroundTaskStore: BackgroundTaskStore? = nil,
        logQuery: (any LaunchdLogQuerying)? = nil
    ) {
        self.uninstaller = uninstaller
        self.operationRecorder = operationRecorder
        self.backgroundTaskStore = backgroundTaskStore
        self.logQuery = logQuery
        self.deepScanner = deepScanner
        self.lastDeepScanAt = deepScanner?.lastScanDate
        self.inventory = inventory
        self.controller = controller
        self.historyProvider = historyProvider
        self.analysisProvider = analysisProvider
        self.analysisStore = analysisStore
        self.aiConfigurationStore = aiConfigurationStore
        self.apiKeyStore = apiKeyStore
        self.aiConfiguration = aiConfigurationStore.load()
        let loadedKey: String?
        do {
            loadedKey = try apiKeyStore.load(provider: aiConfigurationStore.load().providerID)
        } catch {
            loadedKey = nil
        }
        self.aiKeyConfigured = loadedKey?.isEmpty == false
    }

    public var visibleItems: [ServiceItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return items
            .filter { item in
                matchesSourceFilter(item)
                    && (purposeFilter == nil || item.purpose == purposeFilter)
                    && matchesSearch(item, query: query)
            }
            .sorted { lhs, rhs in
                let leftKey: String
                let rightKey: String
                switch sort {
                case .name:
                    leftKey = lhs.name
                    rightKey = rhs.name
                case .source:
                    leftKey = lhs.sourceType.rawValue
                    rightKey = rhs.sourceType.rawValue
                case .state:
                    leftKey = lhs.state.rawValue
                    rightKey = rhs.state.rawValue
                }

                let comparison = leftKey.localizedStandardCompare(rightKey)
                if comparison == .orderedSame {
                    if leftKey == rightKey {
                        return lhs.id < rhs.id
                    }
                    return leftKey < rightKey
                }
                return comparison == .orderedAscending
            }
    }

    public var sidebarSelection: SidebarItem? {
        get { purposeFilter.map(SidebarItem.purpose) ?? .source(sourceFilter) }
        set {
            switch newValue {
            case .purpose(let purpose):
                sourceFilter = .all
                purposeFilter = purpose
            case .source(let filter):
                purposeFilter = nil
                sourceFilter = filter
            case nil:
                break
            }
        }
    }

    public var showsVendorGroups: Bool {
        purposeFilter != nil || sourceFilter.showsVendorGroups
    }

    public var visibleVendorGroups: [VendorGroup] {
        VendorGrouping.groups(from: visibleItems)
    }

    /// Purposes present in the inventory, in display order, with their app/vendor group counts.
    public var purposeCounts: [(purpose: PurposeCategory, count: Int)] {
        let groups = VendorGrouping.groups(from: items)
        let counts = Dictionary(grouping: groups, by: \.purpose).mapValues(\.count)
        return PurposeCategory.allCases.compactMap { purpose in
            counts[purpose].map { (purpose, $0) }
        }
    }

    public var startupOverviewWarnings: [String] {
        warnings.filter(Self.isStartupOverviewScopedWarning)
    }

    public var globalWarnings: [String] {
        warnings.filter { !Self.isStartupOverviewScopedWarning($0) }
    }

    public func refresh() async {
        loadState = .loading
        let result = await inventory.collect()
        items = result.items.map(applyingStoredAIExplanation)
        warnings = result.warnings

        if let selectedServiceID, !items.contains(where: { $0.id == selectedServiceID }) {
            self.selectedServiceID = nil
        }

        loadState = result.warnings.isEmpty ? .loaded : .partiallyFailed
    }

    /// Items whose explanation only comes from generic rules — candidates for AI explanation.
    public var unexplainedItems: [ServiceItem] {
        items.filter { $0.summarySource == .rule }
    }

    public var canExplainWithAI: Bool {
        analysisProvider != nil && analysisStore != nil
    }

    /// Explains every rule-only item with the configured model, one at a time; results are cached in the store.
    public func explainUnidentifiedWithAI() async {
        guard canExplainWithAI, batchExplainProgress == nil else {
            if !canExplainWithAI {
                actionError = "AI 尚未配置。请先打开右上角设置，启用接口并填写模型和 API Key。"
            }
            return
        }
        let candidates = unexplainedItems
        guard !candidates.isEmpty else { return }
        batchCancelRequested = false
        batchExplainProgress = (0, candidates.count)
        defer { batchExplainProgress = nil }
        var failures = 0
        for (index, item) in candidates.enumerated() {
            if batchCancelRequested {
                batchExplainMessage = "已停止，完成 \(index) / \(candidates.count) 项。"
                return
            }
            do {
                try await analyzeAndStore(item)
            } catch {
                failures += 1
            }
            batchExplainProgress = (index + 1, candidates.count)
        }
        if failures > 0 {
            batchExplainMessage = "AI 解释完成，其中 \(failures) 项失败，可稍后重试。"
        }
    }

    public func cancelBatchExplain() {
        batchCancelRequested = true
    }

    /// What the confirmation dialog tells the user before anything is uploaded.
    public var batchExplainDisclosure: String {
        let candidates = unexplainedItems
        let scripts = candidates.filter { $0.purpose == .userScript }.count
        let host = aiConfiguration.baseURL.host ?? aiConfiguration.baseURL.absoluteString
        var text = "将把 \(candidates.count) 个项目的配置与脚本片段发送到 \(host)（模型 \(aiConfiguration.model)）。"
        if scripts > 0 {
            text += "其中 \(scripts) 个是你的自建脚本。"
        }
        return text + "发送前会隐藏 Token、密码、私钥等敏感内容；可随时停止。"
    }

    private func applyingStoredAIExplanation(_ item: ServiceItem) -> ServiceItem {
        guard item.summarySource != .knowledgeBase,
              let analysisStore,
              let record = try? analysisStore.fetchLatestAnalysis(serviceID: item.id) else {
            return item
        }
        analysisResults[item.id] = record
        var explained = item
        explained.summary = record.summary
        explained.summarySource = .ai
        return explained
    }

    public var supportsDeepScan: Bool {
        deepScanner != nil
    }

    /// Reads System Settings' "Allow in the Background" list; macOS asks for an administrator password.
    public func runDeepScan() async {
        guard let deepScanner, !deepScanInProgress else { return }
        deepScanInProgress = true
        defer { deepScanInProgress = false }
        do {
            try await deepScanner.deepScan()
            lastDeepScanAt = deepScanner.lastScanDate
            await refresh()
        } catch {
            deepScanError = message(for: error)
        }
    }

    public func availableActions(for item: ServiceItem) -> [OperationAction] {
        guard item.scope == .user, item.sourceType == .launchAgent else {
            return []
        }

        return [.start, .stop, .restart, .enable, .disable, .testRun]
    }

    public func history(for serviceID: String) throws -> [OperationRecord] {
        try historyProvider.fetchOperationRecords(serviceID: serviceID)
    }

    public func analysis(for serviceID: String) -> AnalysisRecord? {
        analysisResults[serviceID]
    }

    public func loadLatestAnalysis(for serviceID: String) {
        guard let analysisStore else { return }
        do {
            if let record = try analysisStore.fetchLatestAnalysis(serviceID: serviceID) {
                analysisResults[serviceID] = record.reparsedIfNeeded()
            }
        } catch {
            actionError = "读取 AI 分析结果失败：\(message(for: error))"
        }
    }

    public func saveAIConfiguration(_ configuration: AIModelConfiguration, apiKey: String?) throws {
        aiConfigurationStore.save(configuration)
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            try apiKeyStore.save(trimmed, provider: configuration.providerID)
        }
        aiConfiguration = configuration

        let storedKey = storedAIKey(provider: configuration.providerID)
        aiKeyConfigured = storedKey?.isEmpty == false
        let usable = configuration.isConfigured && (aiKeyConfigured || !configuration.preset.requiresKey)
        analysisProvider = usable ? AIProviderFactory.make(configuration: configuration, apiKey: storedKey) : nil
    }

    public func removeAIKey(provider: String? = nil) throws {
        let target = provider ?? aiConfiguration.providerID
        try apiKeyStore.remove(provider: target)
        guard target == aiConfiguration.providerID else { return }
        aiKeyConfigured = false
        if aiConfiguration.preset.requiresKey {
            analysisProvider = nil
        }
    }

    public func hasStoredAIKey(provider: String) -> Bool {
        storedAIKey(provider: provider)?.isEmpty == false
    }

    /// Tests unsaved form values. An empty key falls back to the one stored for that provider.
    public func testAIConnection(_ configuration: AIModelConfiguration, apiKey: String) async -> Result<TimeInterval, Error> {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.isEmpty ? storedAIKey(provider: configuration.providerID) : trimmed
        var probe = configuration
        probe.enabled = true
        do {
            return .success(try await AIProviderFactory.make(configuration: probe, apiKey: key).testConnection())
        } catch {
            return .failure(error)
        }
    }

    private func storedAIKey(provider: String) -> String? {
        (try? apiKeyStore.load(provider: provider)) ?? nil
    }

    public func analyze(_ item: ServiceItem) async {
        guard let analysisProvider else {
            actionError = "AI 尚未配置。请先打开右上角设置，启用接口并填写模型和 API Key。"
            return
        }
        guard let analysisStore else {
            actionError = "AI 分析结果存储不可用。"
            return
        }
        guard analyzingServiceID == nil else { return }

        analyzingServiceID = item.id
        actionError = nil
        defer { analyzingServiceID = nil }
        do {
            try await analyzeAndStore(item)
        } catch {
            actionError = "AI 分析失败：\(message(for: error))"
        }
    }

    private func analyzeAndStore(_ item: ServiceItem) async throws {
        guard let analysisProvider, let analysisStore else { return }
        let result = try await analysisProvider.analyze(
            item,
            options: AnalysisOptions(mode: .cloud, allowCloud: true)
        )
        let record = AnalysisRecord(
            serviceID: item.id,
            analyzedAt: Date(),
            model: aiConfiguration.model,
            summary: result.summary,
            dependencies: result.dependencies,
            risks: result.risks,
            projectUsefulness: result.projectUsefulness,
            confidence: result.confidence,
            evidence: result.evidence,
            rawResponse: result.rawResponse
        )
        try analysisStore.saveLatestAnalysis(record)
        analysisResults[item.id] = record
        if let index = items.firstIndex(where: { $0.id == item.id }), items[index].summarySource != .knowledgeBase {
            items[index].summary = record.summary
            items[index].summarySource = .ai
        }
    }

    public func perform(_ action: OperationAction, on item: ServiceItem) async {
        guard availableActions(for: item).contains(action) else {
            actionError = "该条目为只读项目，不能执行此操作。"
            return
        }
        guard let controller else {
            actionError = "服务控制器不可用。"
            return
        }
        guard operatingServiceID == nil else {
            actionError = "已有操作正在执行。"
            return
        }

        operatingServiceID = item.id
        actionError = nil
        do {
            switch action {
            case .start:
                try await controller.start(item)
            case .stop:
                try await controller.stop(item)
            case .restart:
                try await controller.restart(item)
            case .enable:
                try await controller.setEnabled(true, for: item)
            case .disable:
                try await controller.setEnabled(false, for: item)
            case .testRun:
                try await controller.testRun(item)
            case .backup, .restore, .uninstall:
                actionError = "该操作暂未提供。"
            }
        } catch {
            actionError = message(for: error)
        }

        operatingServiceID = nil
        await refresh()
    }

    private func matchesSourceFilter(_ item: ServiceItem) -> Bool {
        matchesSourceFilter(item, filter: sourceFilter)
    }

    private static func isStartupOverviewScopedWarning(_ warning: String) -> Bool {
        warning.hasPrefix("Login Items unavailable:")
            || warning.hasPrefix("Embedded Login Items unavailable:")
    }

    private func matchesSourceFilter(_ item: ServiceItem, filter: SourceFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .projects:
            return item.project != nil
        case .automaticStartup:
            return item.sourceType == .launchAgent || item.sourceType == .launchDaemon
        case .scheduledTasks:
            return item.sourceType == .cron || item.sourceType == .periodic
        case .loginItems:
            return isStartupOverviewItem(item)
        case .shellStartup:
            return item.sourceType == .shellStartup
        case .ecosystems:
            return item.sourceType == .homebrew || item.sourceType == .docker || item.sourceType == .tmux
        case .attention:
            return item.needsAttention
        case .extensions:
            return [.privilegedHelper, .systemExtension, .kernelExtension].contains(item.sourceType)
        case .launchAgents:
            return item.sourceType == .launchAgent
        case .processes:
            return item.sourceType == .process
        case .systemReadonly:
            return item.scope != .user
        }
    }

    public var projectGroups: [ProjectGroup] {
        let grouped = Dictionary(grouping: items.compactMap { item -> (ProjectIdentity, ServiceItem)? in
            guard let project = item.project else { return nil }
            return (project, item)
        }, by: { $0.0.id })
        return grouped.values.compactMap { values in
            guard let project = values.first?.0 else { return nil }
            return ProjectGroup(project: project, items: values.map(\.1).sorted(by: serviceItemNameAndIDAscending))
        }
        .sorted {
            let comparison = $0.project.displayName.localizedStandardCompare($1.project.displayName)
            if comparison == .orderedSame {
                if $0.project.displayName == $1.project.displayName {
                    return $0.project.id < $1.project.id
                }
                return $0.project.displayName < $1.project.displayName
            }
            return comparison == .orderedAscending
        }
    }

    public var visibleProjectGroups: [ProjectGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return projectGroups }

        return projectGroups.filter { group in
            let projectMatches = [
                group.project.displayName,
                group.project.rootPath,
                group.project.evidence.joined(separator: " ")
            ]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
            return projectMatches || group.items.contains { matchesSearch($0, query: query) }
        }
    }

    public var visibleLoginItemGroups: [LoginItemApplicationGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return loginItemGroups.filter { group in
            guard !query.isEmpty else { return true }
            let groupMatches = [
                group.applicationName,
                group.bundleIdentifier,
                group.project?.displayName,
                group.project?.rootPath
            ]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
            return groupMatches || group.items.contains { matchesSearch($0, query: query) }
        }
    }

    public func count(for filter: SourceFilter) -> Int {
        if filter.showsVendorGroups {
            return VendorGrouping.groups(from: items.filter { matchesSourceFilter($0, filter: filter) }).count
        }
        if filter == .projects {
            return projectGroups.count
        }
        if filter == .loginItems {
            return loginItemGroups.count
        }
        return items.filter { matchesSourceFilter($0, filter: filter) }.count
    }

    private var loginItemGroups: [LoginItemApplicationGroup] {
        let startupItems = items.filter(isStartupOverviewItem)
        let hostBundleIdentifiersByPath = hostBundleIdentifiersByApplicationPath(startupItems)
        let grouped = Dictionary(grouping: startupItems) { item in
            loginItemGroupKey(for: item, hostBundleIdentifiersByPath: hostBundleIdentifiersByPath)
        }

        return grouped
            .map { key, groupItems in
                let sortedItems = groupItems.sorted {
                    startupOverviewItemAscending($0, $1, sort: sort)
                }
                let applicationPaths = sortedItems.compactMap(applicationPath(for:))
                let applicationPath = applicationPaths.min(by: localizedAscending)
                let bundleIdentifier = sortedItems
                    .compactMap { bundleIdentifier(for: $0, hostBundleIdentifiersByPath: hostBundleIdentifiersByPath) }
                    .min(by: localizedAscending)
                let project = sortedItems.compactMap(\.project).min { $0.id < $1.id }
                let applicationName = applicationName(
                    applicationPath: applicationPath,
                    project: project,
                    items: sortedItems,
                    bundleIdentifier: bundleIdentifier
                )

                return LoginItemApplicationGroup(
                    id: key.id,
                    applicationName: applicationName,
                    applicationPath: applicationPath,
                    bundleIdentifier: bundleIdentifier,
                    project: project,
                    enabledState: enabledState(for: sortedItems),
                    items: sortedItems
                )
            }
            .sorted { lhs, rhs in
                startupOverviewGroupAscending(lhs, rhs, sort: sort)
            }
    }

    private func loginItemGroupKey(
        for item: ServiceItem,
        hostBundleIdentifiersByPath: [String: String]
    ) -> LoginItemGroupKey {
        if isNestedLoginItem(item), let applicationPath = applicationPath(for: item) {
            if let bundleIdentifier = hostBundleIdentifiersByPath[applicationPath]
                ?? bundleIdentifierFromApplication(at: applicationPath)
            {
                return LoginItemGroupKey(id: "bundle:\(bundleIdentifier)")
            }
            return LoginItemGroupKey(id: "path:\(applicationPath)")
        }
        if let bundleIdentifier = nonEmptyTrimmed(item.label) {
            return LoginItemGroupKey(id: "bundle:\(bundleIdentifier)")
        }
        if let applicationPath = applicationPath(for: item) {
            return LoginItemGroupKey(id: "path:\(applicationPath)")
        }
        return LoginItemGroupKey(id: "item:\(item.id)")
    }

    private func isStartupOverviewItem(_ item: ServiceItem) -> Bool {
        switch item.sourceType {
        case .loginItem, .launchAgent, .embeddedLoginItem:
            return true
        default:
            return false
        }
    }

    private func bundleIdentifier(
        for item: ServiceItem,
        hostBundleIdentifiersByPath: [String: String]
    ) -> String? {
        guard isNestedLoginItem(item), let applicationPath = applicationPath(for: item) else {
            return nonEmptyTrimmed(item.label)
        }
        return hostBundleIdentifiersByPath[applicationPath]
            ?? bundleIdentifierFromApplication(at: applicationPath)
    }

    private func hostBundleIdentifiersByApplicationPath(_ items: [ServiceItem]) -> [String: String] {
        var identifiers: [String: String] = [:]
        for item in items where !isNestedLoginItem(item) {
            guard let applicationPath = applicationPath(for: item) else { continue }
            let bundleIdentifier = nonEmptyTrimmed(item.label)
                ?? bundleIdentifierFromApplication(at: applicationPath)
            guard let bundleIdentifier else { continue }
            if let existing = identifiers[applicationPath] {
                identifiers[applicationPath] = localizedAscending(existing, bundleIdentifier) ? existing : bundleIdentifier
            } else {
                identifiers[applicationPath] = bundleIdentifier
            }
        }
        return identifiers
    }

    private func bundleIdentifierFromApplication(at applicationPath: String) -> String? {
        Bundle(url: URL(fileURLWithPath: applicationPath))?.bundleIdentifier
    }

    private func isNestedLoginItem(_ item: ServiceItem) -> Bool {
        [item.programPath, item.configurationPath]
            .compactMap { $0 }
            .contains { path in
                hostApplicationPath(from: URL(fileURLWithPath: path).standardizedFileURL) != nil
            }
    }

    private func applicationPath(for item: ServiceItem) -> String? {
        for path in [item.programPath, item.configurationPath] {
            guard let path = nonEmptyTrimmed(path) else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if let hostApplicationPath = hostApplicationPath(from: url) {
                return hostApplicationPath
            }
            var candidate = url
            while candidate.path != "/" {
                if candidate.pathExtension.lowercased() == "app" {
                    return candidate.path
                }
                candidate.deleteLastPathComponent()
            }
        }
        return nil
    }

    private func hostApplicationPath(from url: URL) -> String? {
        let components = url.pathComponents
        guard components.count >= 5 else { return nil }

        for index in 1..<(components.count - 3) {
            guard URL(fileURLWithPath: components[index]).pathExtension.lowercased() == "app",
                  components[index + 1] == "Contents",
                  components[index + 2] == "Library",
                  components[index + 3] == "LoginItems"
            else { continue }
            return "/" + components[1...index].joined(separator: "/")
        }
        return nil
    }

    private func applicationName(
        applicationPath: String?,
        project: ProjectIdentity?,
        items: [ServiceItem],
        bundleIdentifier: String?
    ) -> String {
        if let applicationPath {
            return URL(fileURLWithPath: applicationPath).deletingPathExtension().lastPathComponent
        }
        if let project {
            return project.displayName
        }
        if let item = items.first {
            return item.name
        }
        return bundleIdentifier ?? "未知应用"
    }

    private func enabledState(for items: [ServiceItem]) -> LoginItemEnabledState {
        let states = Set(items.map(\.state))
        let hasEnabled = states.contains(.enabled) || states.contains(.running)
        let hasDisabled = states.contains(.disabled) || items.contains(where: \.disabled)
        switch (hasEnabled, hasDisabled) {
        case (true, false): return .enabled
        case (false, true): return .disabled
        case (true, true): return .partiallyEnabled
        case (false, false): return .unknown
        }
    }

    private func startupOverviewItemAscending(
        _ lhs: ServiceItem,
        _ rhs: ServiceItem,
        sort: ServiceSort
    ) -> Bool {
        let primaryComparison: ComparisonResult
        switch sort {
        case .name:
            primaryComparison = lhs.name.localizedStandardCompare(rhs.name)
        case .source:
            primaryComparison = compare(
                startupOverviewSourceSortRank(lhs.sourceType),
                startupOverviewSourceSortRank(rhs.sourceType)
            )
        case .state:
            primaryComparison = compare(
                startupOverviewStateSortRank(lhs.state),
                startupOverviewStateSortRank(rhs.state)
            )
        }
        if primaryComparison != .orderedSame {
            return primaryComparison == .orderedAscending
        }

        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func startupOverviewGroupAscending(
        _ lhs: LoginItemApplicationGroup,
        _ rhs: LoginItemApplicationGroup,
        sort: ServiceSort
    ) -> Bool {
        let primaryComparison: ComparisonResult
        switch sort {
        case .name:
            primaryComparison = lhs.applicationName.localizedStandardCompare(rhs.applicationName)
        case .source:
            primaryComparison = compare(
                lhs.items.map { startupOverviewSourceSortRank($0.sourceType) }.min() ?? Int.max,
                rhs.items.map { startupOverviewSourceSortRank($0.sourceType) }.min() ?? Int.max
            )
        case .state:
            primaryComparison = compare(
                startupOverviewEnabledStateSortRank(lhs.enabledState),
                startupOverviewEnabledStateSortRank(rhs.enabledState)
            )
        }
        if primaryComparison != .orderedSame {
            return primaryComparison == .orderedAscending
        }

        let nameComparison = lhs.applicationName.localizedStandardCompare(rhs.applicationName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func startupOverviewSourceSortRank(_ sourceType: SourceType) -> Int {
        switch sourceType {
        case .loginItem: return 0
        case .launchAgent: return 1
        case .embeddedLoginItem: return 2
        default: return 3
        }
    }

    private func startupOverviewStateSortRank(_ state: ServiceState) -> Int {
        switch state {
        case .running: return 0
        case .enabled: return 1
        case .discovered: return 2
        case .stopped: return 3
        case .disabled: return 4
        case .failed: return 5
        case .stale: return 6
        case .permissionDenied: return 7
        case .systemReadonly: return 8
        }
    }

    private func startupOverviewEnabledStateSortRank(_ state: LoginItemEnabledState) -> Int {
        switch state {
        case .enabled: return 0
        case .partiallyEnabled: return 1
        case .disabled: return 2
        case .unknown: return 3
        }
    }

    private func compare(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func serviceItemNameAndIDAscending(_ lhs: ServiceItem, _ rhs: ServiceItem) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison == .orderedSame {
            if lhs.name == rhs.name {
                return lhs.id < rhs.id
            }
            return lhs.name < rhs.name
        }
        return comparison == .orderedAscending
    }

    private func localizedAscending(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedStandardCompare(rhs)
        if comparison == .orderedSame {
            return lhs < rhs
        }
        return comparison == .orderedAscending
    }

    private func matchesSearch(_ item: ServiceItem, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return [
            item.name,
            item.label,
            item.vendorName,
            item.summary,
            item.purpose?.displayName,
            item.signing?.organization,
            item.programPath,
            item.configurationPath,
            item.project?.displayName,
            item.project?.rootPath,
            item.assessment?.evidence.joined(separator: " "),
            item.triggers?.map(\.summary).joined(separator: " ")
        ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }

    private func message(for error: Error) -> String {
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

private struct LoginItemGroupKey: Hashable {
    let id: String
}
