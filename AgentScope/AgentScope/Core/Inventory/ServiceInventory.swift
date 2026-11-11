import Foundation

public struct InventoryResult: Sendable {
    public let items: [ServiceItem]
    public let warnings: [String]

    public init(items: [ServiceItem], warnings: [String]) {
        self.items = items
        self.warnings = warnings
    }
}

public protocol ServiceInventoryProviding: Sendable {
    func collect() async -> InventoryResult
}

public struct ServiceInventory: Sendable {
    private let collectors: [any Collector]

    public init(collectors: [any Collector]) {
        self.collectors = collectors
    }

    public func collect() async -> InventoryResult {
        var itemsByID: [String: ServiceItem] = [:]
        var warnings: [String] = []

        for collector in collectors {
            let result = await collector.collect()
            warnings.append(contentsOf: result.warnings)

            for item in result.items where itemsByID[item.id] == nil {
                itemsByID[item.id] = item
            }
        }

        return InventoryResult(
            items: itemsByID.values.sorted { $0.id < $1.id },
            warnings: warnings
        )
    }
}

extension ServiceInventory: ServiceInventoryProviding {}

public struct ProductionServiceInventory: ServiceInventoryProviding {
    private let collectors: [any Collector]
    private let projectAttributor: ProjectAttributor
    private let reviewEngine: ServiceReviewEngine
    private let signatureReader: (any CodeSignatureReading)?
    private let appleFilter: AppleItemFilter
    private let processScanner: ResidentProcessScanner?
    private let explainer: ItemExplainer?
    private let backgroundTaskStore: BackgroundTaskStore?

    public init(
        collectors: [any Collector],
        projectAttributor: ProjectAttributor = ProjectAttributor(),
        reviewEngine: ServiceReviewEngine = ServiceReviewEngine(),
        signatureReader: (any CodeSignatureReading)? = SecurityCodeSignatureReader(),
        appleFilter: AppleItemFilter = AppleItemFilter(),
        processScanner: ResidentProcessScanner? = nil,
        explainer: ItemExplainer? = ItemExplainer(),
        backgroundTaskStore: BackgroundTaskStore? = nil
    ) {
        self.collectors = collectors
        self.projectAttributor = projectAttributor
        self.reviewEngine = reviewEngine
        self.signatureReader = signatureReader
        self.appleFilter = appleFilter
        self.processScanner = processScanner
        self.explainer = explainer
        self.backgroundTaskStore = backgroundTaskStore
    }

    public init(
        launchAgentCollector: any Collector,
        processProvider: any ProcessRecordProviding = SystemProcessRecordProvider(),
        currentUserID: UInt32,
        processIdentifier: Int32
    ) {
        self.collectors = [launchAgentCollector]
        self.projectAttributor = ProjectAttributor()
        self.reviewEngine = ServiceReviewEngine()
        self.signatureReader = SecurityCodeSignatureReader()
        self.appleFilter = AppleItemFilter()
        self.processScanner = nil
        self.explainer = ItemExplainer()
        self.backgroundTaskStore = nil
        _ = processProvider
        _ = currentUserID
        _ = processIdentifier
    }

    public func collect() async -> InventoryResult {
        var collected: [ServiceItem] = []
        var seenIDs: Set<String> = []
        var warnings: [String] = []
        for collector in collectors {
            let result = await collector.collect()
            warnings.append(contentsOf: result.warnings)
            for item in result.items where seenIDs.insert(item.id).inserted {
                collected.append(item)
            }
        }
        if let snapshot = backgroundTaskStore?.current {
            collected = BackgroundTaskMerger.merge(snapshot.records, into: collected)
        }
        if let processScanner {
            collected = await processScanner.link(collected)
        }

        var items: [ServiceItem] = []
        for item in collected {
            var enriched = item
            if enriched.signing == nil,
               let signatureReader,
               let path = AppleItemFilter.signingTargetPath(for: enriched),
               let signing = signatureReader.read(path: path) {
                enriched.signing = signing
                if enriched.signature == .unknown {
                    enriched.signature = signing.signature
                }
            }
            guard !appleFilter.isAppleItem(enriched) else { continue }
            enriched.project = projectAttributor.project(for: item)
            if let explainer {
                enriched = explainer.explain(enriched)
            }
            enriched = ScheduleCalculator.annotate(enriched)
            enriched.assessment = reviewEngine.assess(enriched)
            items.append(enriched)
        }
        return InventoryResult(
            items: items.sorted { $0.id < $1.id },
            warnings: warnings
        )
    }
}

public enum ProductionCollectors {
    public static func makeInventory(
        userID: UInt32,
        backgroundTaskStore: BackgroundTaskStore? = nil
    ) -> ProductionServiceInventory {
        ProductionServiceInventory(
            collectors: make(userID: userID),
            processScanner: ResidentProcessScanner(currentUserID: userID),
            backgroundTaskStore: backgroundTaskStore
        )
    }

    public static func make(userID: UInt32) -> [any Collector] {
        [
            LaunchdCollector(sources: LaunchdSource.defaultSources(userID: userID), userID: userID),
            CronCollector(),
            ShellStartupCollector(),
            LoginItemCollector(reader: SharedFileListLoginItemReader()),
            EmbeddedLoginItemCollector(),
            HomebrewCollector(),
            DockerCollector(),
            TmuxCollector(),
            PrivilegedHelperCollector(),
            SystemExtensionCollector(),
            KernelExtensionCollector(),
            PeriodicCollector(directories: PeriodicCollector.thirdPartyDirectories())
        ]
    }
}
