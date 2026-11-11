import Foundation

public struct ProcessRecord: Codable, Hashable, Sendable {
    public let pid: Int32
    public let parentPID: Int32?
    public let userID: UInt32
    public let name: String
    public let executablePath: String?
    public let launchDate: Date?
    public let isSystemProcess: Bool

    public init(
        pid: Int32,
        parentPID: Int32?,
        userID: UInt32,
        name: String,
        executablePath: String?,
        launchDate: Date?,
        isSystemProcess: Bool
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.name = name
        self.executablePath = executablePath
        self.launchDate = launchDate
        self.isSystemProcess = isSystemProcess
    }
}

public protocol ProcessRecordProviding: Sendable {
    func records() async -> [ProcessRecord]
}

public struct SystemProcessRecordProvider: ProcessRecordProviding {
    private let commandRunner: any CommandExecuting

    public init(commandRunner: any CommandExecuting = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func records() async -> [ProcessRecord] {
        guard let result = try? await commandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,ppid=,uid=,comm="],
            timeout: 5,
            environment: nil
        ) else {
            return []
        }

        return result.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let columns = line.split(maxSplits: 3, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
                guard columns.count == 4,
                      let pid = Int32(columns[0]),
                      let parentPID = Int32(columns[1]),
                      let userID = UInt32(columns[2]) else {
                    return nil
                }
                let executablePath = String(columns[3])
                return ProcessRecord(
                    pid: pid,
                    parentPID: parentPID,
                    userID: userID,
                    name: URL(fileURLWithPath: executablePath).lastPathComponent,
                    executablePath: executablePath,
                    launchDate: nil,
                    isSystemProcess: userID == 0 || executablePath.hasPrefix("/System/")
                )
            }
    }
}

public struct ProcessCollector: Collector {
    private let provider: any ProcessRecordProviding
    private let persistentItems: [ServiceItem]
    private let currentUserID: UInt32
    private let processIdentifier: Int32
    private let includeSystemProcesses: Bool

    public init(
        provider: any ProcessRecordProviding = SystemProcessRecordProvider(),
        persistentItems: [ServiceItem] = [],
        currentUserID: UInt32,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        includeSystemProcesses: Bool = false
    ) {
        self.provider = provider
        self.persistentItems = persistentItems
        self.currentUserID = currentUserID
        self.processIdentifier = processIdentifier
        self.includeSystemProcesses = includeSystemProcesses
    }

    public func collect() async -> CollectorResult {
        let records = await provider.records()
        let items = records.compactMap { record -> ServiceItem? in
            guard record.pid != processIdentifier, record.name != "AgentScope" else { return nil }

            let belongsToSystem = record.isSystemProcess || record.userID != currentUserID
            if belongsToSystem && !includeSystemProcesses { return nil }

            if !belongsToSystem && matchesPersistentItem(record) { return nil }

            let isReadOnly = belongsToSystem
            let hasLaunchDate = record.launchDate != nil
            let targetExists = record.executablePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            let evidence = isReadOnly
                ? [Evidence(title: "System process", detail: "Displayed read-only.", severity: .info)]
                : [Evidence(title: "No persistent launch source found", detail: "The process is currently running without a matched LaunchAgent.", severity: .info)]

            return ServiceItem(
                id: "process:\(record.pid)",
                name: record.name,
                sourceType: .process,
                scope: isReadOnly ? .system : .user,
                programPath: record.executablePath,
                state: isReadOnly ? .systemReadonly : .running,
                pid: record.pid,
                startedAt: record.launchDate,
                lastRunAt: record.launchDate,
                lastRunPrecision: hasLaunchDate ? .exact : .unknown,
                validity: targetExists ? .healthy : .unknown,
                evidence: evidence
            )
        }

        return CollectorResult(items: items.sorted { $0.id < $1.id }, warnings: [])
    }

    private func matchesPersistentItem(_ record: ProcessRecord) -> Bool {
        persistentItems.contains { item in
            if let executablePath = record.executablePath, executablePath == item.programPath {
                return true
            }
            return item.label == record.name || item.name == record.name
        }
    }
}
