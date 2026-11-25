import Foundation
import os

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
    private let signingTimeout: TimeInterval

    public static let signingTimeoutWarning = "代码签名读取超时（可能网络或系统证书服务异常），本次部分项目的签名未读取。"
    private static let logger = Logger(subsystem: "com.example.AgentScope", category: "inventory")

    public init(
        collectors: [any Collector],
        projectAttributor: ProjectAttributor = ProjectAttributor(),
        reviewEngine: ServiceReviewEngine = ServiceReviewEngine(),
        signatureReader: (any CodeSignatureReading)? = SecurityCodeSignatureReader(),
        appleFilter: AppleItemFilter = AppleItemFilter(),
        processScanner: ResidentProcessScanner? = nil,
        explainer: ItemExplainer? = ItemExplainer(),
        backgroundTaskStore: BackgroundTaskStore? = nil,
        signingTimeout: TimeInterval = 3
    ) {
        self.signingTimeout = signingTimeout
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
        self.signingTimeout = 3
        _ = processProvider
        _ = currentUserID
        _ = processIdentifier
    }

    public func collect() async -> InventoryResult {
        var collected: [ServiceItem] = []
        var seenIDs: Set<String> = []
        var warnings: [String] = []
        for collector in collectors {
            let name = String(describing: type(of: collector))
            let startedAt = Date()
            Self.logger.info("collector \(name, privacy: .public) start")
            let result = await collector.collect()
            Self.logger.info("collector \(name, privacy: .public) done in \(Date().timeIntervalSince(startedAt), privacy: .public)s, \(result.items.count, privacy: .public) items")
            warnings.append(contentsOf: result.warnings)
            for item in result.items where seenIDs.insert(item.id).inserted {
                collected.append(item)
            }
        }
        if let snapshot = backgroundTaskStore?.current {
            collected = BackgroundTaskMerger.merge(snapshot.records, into: collected)
        }
        if let processScanner {
            Self.logger.info("process link start")
            collected = await processScanner.link(collected)
            Self.logger.info("process link done")
        }

        var items: [ServiceItem] = []
        var signingAvailable = signatureReader != nil
        let signingStartedAt = Date()
        Self.logger.info("signing start")
        for item in collected {
            var enriched = item
            if enriched.signing == nil,
               signingAvailable,
               let signatureReader,
               let path = AppleItemFilter.signingTargetPath(for: enriched),
               let signing = await Self.read(path, with: signatureReader, timeout: signingTimeout, onTimeout: {
                   signingAvailable = false
                   warnings.append(Self.signingTimeoutWarning)
                   Self.logger.error("signing timed out after \(signingTimeout, privacy: .public)s; skipping the rest")
               }) {
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
        Self.logger.info("signing done in \(Date().timeIntervalSince(signingStartedAt), privacy: .public)s")
        return InventoryResult(
            items: items.sorted { $0.id < $1.id },
            warnings: warnings
        )
    }
}

/// Serial, so a read stuck in trustd blocks one thread rather than one per refresh.
private let signingQueue = DispatchQueue(label: "com.example.AgentScope.signing", qos: .userInitiated)

extension ProductionServiceInventory {
    private enum SigningOutcome: Sendable {
        case finished(SigningInfo?)
        case timedOut
    }

    /// Security.framework calls are synchronous and can block on trustd; never let one stall the scan.
    private static func read(
        _ path: String,
        with reader: any CodeSignatureReading,
        timeout: TimeInterval,
        onTimeout: () -> Void
    ) async -> SigningInfo? {
        let outcome: SigningOutcome = await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            signingQueue.async {
                let info = reader.read(path: path)
                if once.claim() { continuation.resume(returning: .finished(info)) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: .timedOut) }
            }
        }
        switch outcome {
        case .finished(let info):
            return info
        case .timedOut:
            onTimeout()
            return nil
        }
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
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
