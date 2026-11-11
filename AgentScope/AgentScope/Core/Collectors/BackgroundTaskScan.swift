import Foundation

/// One record of macOS Background Task Management ("允许在后台" in System Settings), from `sfltool dumpbtm`.
public struct BackgroundTaskRecord: Codable, Hashable, Sendable {
    public var name: String?
    public var developerName: String?
    public var teamID: String?
    public var type: String
    public var identifier: String?
    public var url: String?
    public var executablePath: String?
    public var bundleIdentifier: String?
    public var enabled: Bool
    public var allowed: Bool

    /// "16.com.docker.helper" -> "com.docker.helper"
    public var plainIdentifier: String? {
        guard let identifier else { return nil }
        let parts = identifier.split(separator: ".", maxSplits: 1)
        if parts.count == 2, Int(parts[0]) != nil { return String(parts[1]) }
        return identifier
    }

    /// The launchd plist behind a legacy record. BTM writes per-user paths as `/Users/<uid>/…`.
    public func plistPath(homeDirectory: String = NSHomeDirectory(), userID: UInt32 = getuid()) -> String? {
        guard let url, url.hasSuffix(".plist"), url.hasPrefix("/") else { return nil }
        let uidPrefix = "/Users/\(userID)/"
        return url.hasPrefix(uidPrefix) ? homeDirectory + "/" + url.dropFirst(uidPrefix.count) : url
    }

    public var path: String? {
        if let executablePath { return executablePath }
        guard let url, let parsed = URL(string: url), parsed.isFileURL else { return nil }
        return parsed.path.hasSuffix("/") && parsed.path.count > 1 ? String(parsed.path.dropLast()) : parsed.path
    }
}

public struct BackgroundTaskSnapshot: Codable, Sendable {
    public let scannedAt: Date
    public let records: [BackgroundTaskRecord]

    public init(scannedAt: Date, records: [BackgroundTaskRecord]) {
        self.scannedAt = scannedAt
        self.records = records
    }
}

public enum BackgroundTaskParser {
    /// Record types that represent something that starts on its own; "developer"/"app" container rows are skipped.
    static let startupTypes = ["login item", "agent", "daemon", "legacy"]

    public static func parse(_ output: String) -> [BackgroundTaskRecord] {
        var records: [BackgroundTaskRecord] = []
        var fields: [String: String] = [:]

        func flush() {
            defer { fields = [:] }
            guard let typeField = fields["Type"] else { return }
            let type = typeField.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces) ?? typeField
            guard startupTypes.contains(where: { type.lowercased().contains($0) }) else { return }
            let disposition = (fields["Disposition"] ?? "").lowercased()
            records.append(BackgroundTaskRecord(
                name: fields["Name"].flatMap(nonEmpty),
                developerName: fields["Developer Name"].flatMap(nonEmpty),
                teamID: fields["Team Identifier"].flatMap(nonEmpty),
                type: type,
                identifier: fields["Identifier"].flatMap(nonEmpty),
                url: fields["URL"].flatMap(nonEmpty),
                executablePath: fields["Executable Path"].flatMap(nonEmpty),
                bundleIdentifier: fields["Bundle Identifier"].flatMap(nonEmpty),
                enabled: disposition.contains("enabled") && !disposition.contains("disabled"),
                allowed: disposition.contains("allowed") && !disposition.contains("disallowed")
            ))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#"), line.hasSuffix(":"), rawLine.hasPrefix(" #") || rawLine.hasPrefix("#") {
                flush()
                continue
            }
            if line.hasPrefix("====") || line.hasPrefix("Records for") {
                flush()
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, fields[key] == nil else { continue }
            fields[key] = value
        }
        flush()
        return records
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "(null)" ? nil : trimmed
    }
}

public enum BackgroundTaskMerger {
    /// Records that match an existing item annotate it; the rest become `.backgroundTask` items.
    public static func merge(_ records: [BackgroundTaskRecord], into items: [ServiceItem]) -> [ServiceItem] {
        var merged = items
        var added: Set<String> = []
        var allowedIndexes: Set<Int> = []
        var blockedIndexes: Set<Int> = []
        for record in records where !isApple(record) && !isRemoved(record) {
            let note = Evidence(
                title: "系统设置「允许在后台」",
                detail: record.allowed && record.enabled ? "已允许在后台运行" : "已在系统设置中关闭",
                severity: record.allowed && record.enabled ? .info : .warning
            )
            let index = merged.firstIndex { matchesIdentifier(record, $0) }
                ?? merged.firstIndex { matchesPath(record, $0) }
            if let index {
                if record.allowed && record.enabled {
                    allowedIndexes.insert(index)
                } else {
                    blockedIndexes.insert(index)
                }
                if !merged[index].evidence.contains(note) {
                    merged[index].evidence.append(note)
                }
                continue
            }
            let id = "btm:\(record.plainIdentifier ?? record.path ?? record.name ?? UUID().uuidString)"
            guard added.insert(id).inserted else { continue }
            merged.append(ServiceItem(
                id: id,
                name: record.name ?? record.plainIdentifier ?? "后台活动项",
                sourceType: .backgroundTask,
                scope: record.type.lowercased().contains("daemon") ? .global : .user,
                label: record.plainIdentifier,
                programPath: record.path,
                state: record.allowed && record.enabled ? .enabled : .disabled,
                disabled: !(record.allowed && record.enabled),
                validity: record.path.map { FileManager.default.fileExists(atPath: $0) ? .healthy : .missingTarget } ?? .unknown,
                signing: record.teamID.map {
                    SigningInfo(signature: .developerID, teamID: $0, organization: record.developerName, signedPath: record.path ?? "")
                },
                bundleIdentifier: record.bundleIdentifier,
                evidence: [note, Evidence(title: "后台活动类型", detail: record.type, severity: .info)]
            ))
        }
        // Switched off in System Settings means launchd will not load it, whatever its plist says.
        for index in blockedIndexes.subtracting(allowedIndexes) where merged[index].state != .running {
            merged[index].state = .disabled
            merged[index].disabled = true
        }
        return merged
    }

    static func matchesIdentifier(_ record: BackgroundTaskRecord, _ item: ServiceItem) -> Bool {
        let identifiers = [record.plainIdentifier, record.bundleIdentifier].compactMap { $0?.lowercased() }
        let itemIdentifiers = [item.label, item.bundleIdentifier].compactMap { $0?.lowercased() }
        return identifiers.contains(where: itemIdentifiers.contains)
    }

    /// Shared system binaries (`/bin/bash`, `/usr/bin/ssh`, `/usr/bin/open`) identify nothing on their own.
    static func matchesPath(_ record: BackgroundTaskRecord, _ item: ServiceItem) -> Bool {
        guard let path = record.path,
              !["/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/"].contains(where: path.hasPrefix)
        else { return false }
        return [item.programPath, item.ownerAppPath, item.configurationPath].contains(path)
    }

    /// The plist was deleted after the scan (e.g. uninstalled here), so the cached record is stale.
    static func isRemoved(_ record: BackgroundTaskRecord) -> Bool {
        guard let plist = record.plistPath() else { return false }
        return !UninstallPlanner.pathExists(plist)
    }

    static func isApple(_ record: BackgroundTaskRecord) -> Bool {
        if record.plainIdentifier?.lowercased().hasPrefix("com.apple.") == true { return true }
        if record.bundleIdentifier?.lowercased().hasPrefix("com.apple.") == true { return true }
        return record.path?.hasPrefix("/System/") == true
    }
}

/// Holds the last deep-scan result, persisted so later launches can show it without re-prompting.
public final class BackgroundTaskStore: @unchecked Sendable {
    private let fileURL: URL?
    private let lock = NSLock()
    private var snapshot: BackgroundTaskSnapshot?

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            snapshot = try? JSONDecoder().decode(BackgroundTaskSnapshot.self, from: data)
        }
    }

    public var current: BackgroundTaskSnapshot? {
        lock.withLock { snapshot }
    }

    /// Drops records for uninstalled items so a stale deep scan cannot bring them back.
    public func remove(labels: Set<String>, paths: Set<String>) throws {
        guard let snapshot = current else { return }
        let kept = snapshot.records.filter { record in
            !(record.plainIdentifier.map(labels.contains) ?? false)
                && !(record.path.map(paths.contains) ?? false)
                && !(record.plistPath().map(paths.contains) ?? false)
        }
        guard kept.count != snapshot.records.count else { return }
        try save(BackgroundTaskSnapshot(scannedAt: snapshot.scannedAt, records: kept))
    }

    public func save(_ newSnapshot: BackgroundTaskSnapshot) throws {
        lock.withLock { snapshot = newSnapshot }
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(newSnapshot).write(to: fileURL, options: .atomic)
    }
}

public protocol DeepScanning: Sendable {
    var lastScanDate: Date? { get }
    func deepScan() async throws
}

/// Runs `sfltool dumpbtm` only when the user asks; macOS shows its own administrator prompt.
public struct BackgroundTaskDeepScanner: DeepScanning {
    private let store: BackgroundTaskStore
    private let commandRunner: any CommandExecuting

    public init(store: BackgroundTaskStore, commandRunner: any CommandExecuting = CommandRunner()) {
        self.store = store
        self.commandRunner = commandRunner
    }

    public var lastScanDate: Date? {
        store.current?.scannedAt
    }

    public func deepScan() async throws {
        let result: CommandResult
        do {
            result = try await commandRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/sfltool"),
                arguments: ["dumpbtm"],
                timeout: 120,
                environment: nil
            )
        } catch CommandRunnerError.timedOut {
            throw DeepScanError.timedOut
        } catch CommandRunnerError.nonZeroExit(let failed) {
            throw DeepScanError.failed(failed.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let records = BackgroundTaskParser.parse(result.stdout)
        guard !records.isEmpty else { throw DeepScanError.empty }
        try store.save(BackgroundTaskSnapshot(scannedAt: Date(), records: records))
    }
}

public enum DeepScanError: LocalizedError, Equatable {
    case timedOut
    case failed(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .timedOut: return "深度扫描超时（未在 2 分钟内完成授权或读取）。"
        case .failed(let message): return message.isEmpty ? "深度扫描被取消或未获授权。" : "深度扫描失败：\(message)"
        case .empty: return "深度扫描没有读到任何后台活动记录（可能未授权）。"
        }
    }
}
