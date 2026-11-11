import Darwin
@preconcurrency import CoreServices
import Foundation

public struct LoginItemRecord: Equatable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let bundleIdentifier: String?

    public init(name: String, path: String, bundleIdentifier: String? = nil) {
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
    }
}

public protocol LoginItemReading: Sendable {
    func read() throws -> [LoginItemRecord]
}

public enum LoginItemReaderError: LocalizedError, Equatable, Sendable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        }
    }
}

public struct SharedFileListLoginItemReader: LoginItemReading {
    public init() {}

    public func read() throws -> [LoginItemRecord] {
        try Self.records(from: Self.nativeResolvedURLs())
    }

    private static func nativeResolvedURLs() throws -> [URL] {
        let loginItemsListType = kLSSharedFileListSessionLoginItems.takeUnretainedValue()
        guard let listReference = LSSharedFileListCreate(nil, loginItemsListType, nil) else {
            throw LoginItemReaderError.unavailable("could not create the user login-items shared list")
        }
        let list = listReference.takeRetainedValue()

        var snapshotSeed: UInt32 = 0
        guard let snapshotReference = LSSharedFileListCopySnapshot(list, &snapshotSeed) else {
            throw LoginItemReaderError.unavailable("could not obtain a user login-items shared-list snapshot")
        }
        let snapshot = snapshotReference.takeRetainedValue()

        let itemCount = CFArrayGetCount(snapshot)
        guard itemCount > 0 else { return [] }

        var resolvedRecordCount = 0
        var resolvedURLs: [URL] = []
        for index in 0..<itemCount {
            let itemPointer = CFArrayGetValueAtIndex(snapshot, index)
            let item = unsafeBitCast(itemPointer, to: LSSharedFileListItem.self)
            var resolvedURLReference: Unmanaged<CFURL>?
            let status = LSSharedFileListItemResolve(item, 0, &resolvedURLReference, nil)
            guard status == noErr, let resolvedURLReference else {
                resolvedURLReference?.release()
                continue
            }
            resolvedRecordCount += 1

            resolvedURLs.append(resolvedURLReference.takeRetainedValue() as URL)
        }

        guard resolvedRecordCount > 0 else {
            throw LoginItemReaderError.unavailable("no user login-item records could be resolved from the shared list")
        }
        return resolvedURLs
    }

    static func records(from resolvedURLs: [URL]) throws -> [LoginItemRecord] {
        let records: [LoginItemRecord] = resolvedURLs.compactMap { resolvedURL in
            let standardizedURL = resolvedURL.standardizedFileURL
            guard standardizedURL.isFileURL else { return nil }
            let bundle = Bundle(url: standardizedURL)
            return record(
                resolvedURL: standardizedURL,
                displayName: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                bundleName: bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                bundleIdentifier: bundle?.bundleIdentifier
            )
        }

        guard resolvedURLs.isEmpty || !records.isEmpty else {
            throw LoginItemReaderError.unavailable("all resolved user login-item records had invalid paths")
        }
        return records
    }

    static func record(
        resolvedURL: URL,
        displayName: String?,
        bundleName: String? = nil,
        bundleIdentifier: String?
    ) -> LoginItemRecord? {
        guard resolvedURL.isFileURL else { return nil }

        let path = resolvedURL.standardizedFileURL.path
        guard !path.isEmpty, path != "/" else { return nil }

        let resolvedName = nonEmptyTrimmed(displayName)
            ?? nonEmptyTrimmed(bundleName)
            ?? resolvedURL.lastPathComponent
        guard !resolvedName.isEmpty else { return nil }

        return LoginItemRecord(
            name: resolvedName,
            path: path,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct LoginItemCollector: Collector {
    private let reader: any LoginItemReading
    private let userID: UInt32

    public init(
        reader: any LoginItemReading = SharedFileListLoginItemReader(),
        userID: UInt32 = getuid()
    ) {
        self.reader = reader
        self.userID = userID
    }

    public func collect() async -> CollectorResult {
        let records: [LoginItemRecord]
        do {
            records = try reader.read()
        } catch {
            return CollectorResult(items: [], warnings: ["Login Items unavailable: \(error.localizedDescription)"])
        }

        return CollectorResult(items: deduplicatedRecords(records).map { record in
            let normalizedPath = record.path
            return ServiceItem(
                id: "loginitem:user:\(normalizedPath)",
                name: record.name,
                sourceType: .loginItem,
                scope: .user,
                label: record.bundleIdentifier,
                configurationPath: normalizedPath,
                programPath: normalizedPath,
                state: .enabled,
                lastRunPrecision: .unknown,
                disabled: false,
                validity: .healthy,
                signature: .unknown,
                triggers: [TriggerInfo(kind: .loginItem, summary: "用户登录时启动")],
                executionEvidence: ExecutionEvidence(
                    lastExecutionAt: nil,
                    precision: .unknown,
                    lastExitCode: nil,
                    consecutiveFailures: 0,
                    source: "LSSharedFileList",
                    detail: "传统用户登录项只读记录"
                )
            )
        }, warnings: [])
    }

    private func deduplicatedRecords(_ records: [LoginItemRecord]) -> [LoginItemRecord] {
        var unique: [String: LoginItemRecord] = [:]
        for record in records {
            guard let path = normalizedPath(for: record.path) else { continue }
            if unique[path] == nil {
                unique[path] = LoginItemRecord(
                    name: record.name,
                    path: path,
                    bundleIdentifier: record.bundleIdentifier
                )
            }
        }
        return unique.values.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private func normalizedPath(for path: String) -> String? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty, trimmedPath.hasPrefix("/") else { return nil }

        var normalizedPath = URL(fileURLWithPath: trimmedPath).standardizedFileURL.path
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        return normalizedPath.isEmpty ? nil : normalizedPath
    }
}

public struct EmbeddedLoginItemCollector: Collector {
    private let applicationRoots: [URL]
    private let fileManagerBox: FileManagerBox

    public init(fileManager: FileManager = .default) {
        self.init(applicationRoots: Self.defaultApplicationRoots(), fileManager: fileManager)
    }

    public init(applicationRoots: [URL], fileManager: FileManager = .default) {
        self.applicationRoots = applicationRoots.map(Self.canonicalURL)
        self.fileManagerBox = FileManagerBox(fileManager)
    }

    public func collect() async -> CollectorResult {
        var discovered: [EmbeddedLoginItemKey: ServiceItem] = [:]

        for applicationRoot in applicationRoots {
            let scope = Self.scope(forApplicationRoot: applicationRoot)
            for hostApp in appBundles(in: applicationRoot) {
                for helperApp in embeddedLoginItemBundles(in: hostApp, applicationRoot: applicationRoot) {
                    let key = EmbeddedLoginItemKey(hostPath: hostApp.path, helperPath: helperApp.path)
                    guard discovered[key] == nil else { continue }
                    discovered[key] = serviceItem(hostApp: hostApp, helperApp: helperApp, scope: scope)
                }
            }
        }

        let items = discovered.values.sorted {
            let lhsHostPath = $0.project?.rootPath ?? ""
            let rhsHostPath = $1.project?.rootPath ?? ""
            if lhsHostPath != rhsHostPath {
                return lhsHostPath.localizedCaseInsensitiveCompare(rhsHostPath) == .orderedAscending
            }
            return ($0.programPath ?? "").localizedCaseInsensitiveCompare($1.programPath ?? "") == .orderedAscending
        }
        return CollectorResult(items: items, warnings: [])
    }

    /// Apps directly in the root or inside category folders (e.g. /Applications/Social/QQ.app), never inside bundles.
    private func appBundles(in applicationRoot: URL, maxDepth: Int = 3) -> [URL] {
        var bundles: [URL] = []
        var pending: [(URL, Int)] = [(applicationRoot, 0)]
        while let (directory, depth) = pending.popLast() {
            for url in directoryContents(of: directory) {
                let canonicalURL = Self.canonicalURL(url)
                guard isWithinApplicationRoot(canonicalURL, applicationRoot: applicationRoot),
                      isDirectory(canonicalURL) else { continue }
                let fileExtension = canonicalURL.pathExtension.lowercased()
                if fileExtension == "app" {
                    bundles.append(canonicalURL)
                } else if fileExtension.isEmpty, depth + 1 < maxDepth, canonicalURL.lastPathComponent != "Contents" {
                    pending.append((canonicalURL, depth + 1))
                }
            }
        }
        return bundles.sorted { $0.path < $1.path }
    }

    private func embeddedLoginItemBundles(in hostApp: URL, applicationRoot: URL) -> [URL] {
        let loginItemsDirectory = hostApp.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        return directoryContents(of: loginItemsDirectory).compactMap { url in
            let canonicalURL = Self.canonicalURL(url)
            guard canonicalURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                  isWithinApplicationRoot(canonicalURL, applicationRoot: applicationRoot),
                  isDirectory(canonicalURL) else {
                return nil
            }
            return canonicalURL
        }
    }

    private func directoryContents(of directory: URL) -> [URL] {
        (try? fileManagerBox.value.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.map { $0.standardizedFileURL } ?? []
    }

    private func isWithinApplicationRoot(_ url: URL, applicationRoot: URL) -> Bool {
        let rootPath = applicationRoot.path
        let candidatePath = url.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManagerBox.value.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func serviceItem(hostApp: URL, helperApp: URL, scope: Scope) -> ServiceItem {
        let helperBundle = Bundle(url: helperApp)
        let helperName = nonEmptyTrimmed(helperBundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? nonEmptyTrimmed(helperBundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? helperApp.deletingPathExtension().lastPathComponent
        let hostName = hostApp.deletingPathExtension().lastPathComponent
        let helperPath = helperApp.path
        let hostPath = hostApp.path

        return ServiceItem(
            id: "embeddedLoginItem:\(hostPath):\(helperPath)",
            name: helperName,
            sourceType: .embeddedLoginItem,
            scope: scope,
            label: nonEmptyTrimmed(helperBundle?.object(forInfoDictionaryKey: "CFBundleIdentifier") as? String),
            configurationPath: helperPath,
            programPath: helperPath,
            state: .discovered,
            lastRunPrecision: .unknown,
            disabled: false,
            validity: .unknown,
            signature: .unknown,
            attribution: Attribution(
                kind: "appBundle",
                confidence: 1.0,
                evidence: ["Host app: \(hostPath)", "Read-only embedded login-item discovery"]
            ),
            evidence: [
                Evidence(title: "Host App Bundle", detail: hostPath, severity: .info),
                Evidence(title: "Embedded LoginItems", detail: "\(hostPath)/Contents/Library/LoginItems", severity: .info)
            ],
            project: ProjectIdentity(
                id: "appBundle:\(hostPath)",
                displayName: hostName,
                rootPath: hostPath,
                kind: .appBundle,
                confidence: 1.0,
                evidence: ["Embedded helper: \(helperPath)"]
            ),
            triggers: [TriggerInfo(kind: .loginItem, summary: "用户登录时启动 / 应用后台启动")],
            executionEvidence: ExecutionEvidence(
                lastExecutionAt: nil,
                precision: .unknown,
                lastExitCode: nil,
                consecutiveFailures: 0,
                source: "App Bundle LoginItems",
                detail: "\(hostPath)/Contents/Library/LoginItems"
            )
        )
    }

    private func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func defaultApplicationRoots() -> [URL] {
        [
            "/Applications",
            "/Library/CoreServices",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true).path
        ].map(URL.init(fileURLWithPath:))
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    static func scope(forApplicationRoot root: URL) -> Scope {
        let path = canonicalURL(root).path
        if path.hasPrefix("/System/") { return .system }
        let machineApplicationRootPaths = ["/Applications", "/Library/CoreServices"]
            .map { canonicalURL(URL(fileURLWithPath: $0)).path }
        return machineApplicationRootPaths.contains(path) ? .global : .user
    }
}

private final class FileManagerBox: @unchecked Sendable {
    let value: FileManager

    init(_ value: FileManager) {
        self.value = value
    }
}

private struct EmbeddedLoginItemKey: Hashable {
    let hostPath: String
    let helperPath: String
}

public struct HomebrewCollector: Collector {
    private let sourceText: String?
    private let commandRunner: any CommandExecuting
    private let executableURL: URL?

    public init(
        sourceText: String? = nil,
        commandRunner: any CommandExecuting = CommandRunner(),
        executableURL: URL? = nil
    ) {
        self.sourceText = sourceText
        self.commandRunner = commandRunner
        self.executableURL = executableURL
    }

    public func collect() async -> CollectorResult {
        let text: String
        if let sourceText {
            text = sourceText
        } else {
            guard let executable = executableURL ?? Self.defaultExecutable() else {
                return CollectorResult(items: [], warnings: ["Homebrew executable not found"])
            }
            do {
                text = try await commandRunner.run(
                    executable: executable,
                    arguments: ["services", "list", "--json"],
                    timeout: 5,
                    environment: nil
                ).stdout
            } catch {
                return CollectorResult(items: [], warnings: ["Unable to read Homebrew services: \(error.localizedDescription)"])
            }
        }

        guard let data = text.data(using: .utf8),
              let rawRecords = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return CollectorResult(items: [], warnings: ["Invalid Homebrew services JSON"])
        }

        let items = rawRecords.compactMap { record -> ServiceItem? in
            guard let name = record["name"] as? String else { return nil }
            let running = (record["running"] as? Bool) ?? false
            let loaded = (record["loaded"] as? Bool) ?? false
            let status = record["status"] as? String
            let file = record["file"] as? String
            let exitCode = (record["exit_code"] as? NSNumber)?.int32Value
            let state: ServiceState = running ? .running : (loaded ? .enabled : .stopped)
            return ServiceItem(
                id: "homebrew:user:\(name)",
                name: name,
                sourceType: .homebrew,
                scope: .user,
                label: name,
                configurationPath: file,
                programPath: nil,
                state: state,
                lastRunPrecision: .unknown,
                lastExitCode: exitCode,
                disabled: false,
                validity: file == nil ? .unknown : .healthy,
                signature: .unknown,
                triggers: [TriggerInfo(kind: .homebrew, summary: "Homebrew services 管理")],
                executionEvidence: ExecutionEvidence(
                    lastExecutionAt: nil,
                    precision: .unknown,
                    lastExitCode: exitCode,
                    consecutiveFailures: (exitCode ?? 0) == 0 ? 0 : 1,
                    source: "brew services",
                    detail: status
                )
            )
        }
        return CollectorResult(items: items, warnings: [])
    }

    private static func defaultExecutable() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

public struct DockerCollector: Collector {
    private let sourceText: String?
    private let commandRunner: any CommandExecuting
    private let executableURL: URL?

    public init(
        sourceText: String? = nil,
        commandRunner: any CommandExecuting = CommandRunner(),
        executableURL: URL? = nil
    ) {
        self.sourceText = sourceText
        self.commandRunner = commandRunner
        self.executableURL = executableURL
    }

    public func collect() async -> CollectorResult {
        let text: String
        if let sourceText {
            text = sourceText
        } else {
            guard let executable = executableURL ?? Self.defaultExecutable() else {
                return CollectorResult(items: [], warnings: ["Docker executable not found"])
            }
            do {
                text = try await commandRunner.run(
                    executable: executable,
                    arguments: ["ps", "-a", "--format", "{{json .}}"],
                    timeout: 8,
                    environment: nil
                ).stdout
            } catch {
                return CollectorResult(items: [], warnings: ["Unable to read Docker containers: \(error.localizedDescription)"])
            }
        }

        var items: [ServiceItem] = []
        var warnings: [String] = []
        for line in text.components(separatedBy: .newlines) where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let data = line.data(using: .utf8),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = record["ID"] as? String else {
                warnings.append("Invalid Docker container JSON line")
                continue
            }
            let name = (record["Names"] as? String) ?? id
            let status = (record["Status"] as? String) ?? ""
            let labels = parseLabels(record["Labels"] as? String)
            let projectName = labels["com.docker.compose.project"]
            let workingDirectory = labels["com.docker.compose.project.working_dir"]
            let project = projectName.map {
                ProjectIdentity(
                    id: "docker-compose:\($0)",
                    displayName: $0,
                    rootPath: workingDirectory,
                    kind: .dockerCompose,
                    confidence: workingDirectory == nil ? 0.8 : 1.0,
                    evidence: ["Docker Compose label: com.docker.compose.project"]
                )
            }
            items.append(ServiceItem(
                id: "docker:container:\(id)",
                name: name,
                sourceType: .docker,
                scope: .user,
                label: name,
                configurationPath: workingDirectory,
                programPath: nil,
                arguments: [],
                state: status.lowercased().hasPrefix("up") ? .running : .stopped,
                lastRunPrecision: .unknown,
                disabled: false,
                validity: .unknown,
                signature: .unknown,
                project: project,
                triggers: [TriggerInfo(kind: .docker, summary: "Docker 容器启动")],
                executionEvidence: ExecutionEvidence(
                    lastExecutionAt: nil,
                    precision: .unknown,
                    lastExitCode: nil,
                    consecutiveFailures: 0,
                    source: "docker ps",
                    detail: status
                )
            ))
        }
        return CollectorResult(items: items, warnings: warnings)
    }

    private static func defaultExecutable() -> URL? {
        let candidates = [
            "/Applications/Developer Tools/Docker.app/Contents/Resources/bin/docker",
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker"
        ]
        return candidates.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func parseLabels(_ text: String?) -> [String: String] {
        guard let text else { return [:] }
        return text.split(separator: ",").reduce(into: [:]) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return }
            result[pair[0]] = pair[1]
        }
    }
}

public struct TmuxCollector: Collector {
    private let sourceText: String?
    private let commandRunner: any CommandExecuting
    private let executableURL: URL?

    public init(
        sourceText: String? = nil,
        commandRunner: any CommandExecuting = CommandRunner(),
        executableURL: URL? = nil
    ) {
        self.sourceText = sourceText
        self.commandRunner = commandRunner
        self.executableURL = executableURL
    }

    public func collect() async -> CollectorResult {
        let text: String
        if let sourceText {
            text = sourceText
        } else {
            guard let executable = executableURL ?? Self.defaultExecutable() else {
                return CollectorResult(items: [], warnings: ["tmux executable not found"])
            }
            do {
                text = try await commandRunner.run(
                    executable: executable,
                    arguments: ["list-sessions"],
                    timeout: 3,
                    environment: nil
                ).stdout
            } catch let error as CommandRunnerError {
                if case .nonZeroExit(let result) = error, Self.isNoSessionError(result) {
                    return CollectorResult(items: [], warnings: [])
                }
                return CollectorResult(items: [], warnings: ["Unable to read tmux sessions: \(error.localizedDescription)"])
            } catch {
                return CollectorResult(items: [], warnings: ["Unable to read tmux sessions: \(error.localizedDescription)"])
            }
        }

        let items = text.components(separatedBy: .newlines).compactMap { line -> ServiceItem? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.lowercased().contains("no server") else { return nil }
            let name = trimmed.split(separator: ":", maxSplits: 1).first.map(String.init) ?? trimmed
            return ServiceItem(
                id: "tmux:session:\(name)",
                name: name,
                sourceType: .tmux,
                scope: .user,
                label: name,
                programPath: Self.defaultExecutable()?.path,
                state: .running,
                lastRunPrecision: .unknown,
                disabled: false,
                validity: .unknown,
                signature: .unknown,
                triggers: [TriggerInfo(kind: .tmux, summary: "tmux 会话")],
                executionEvidence: ExecutionEvidence(
                    lastExecutionAt: nil,
                    precision: .unknown,
                    lastExitCode: 0,
                    consecutiveFailures: 0,
                    source: "tmux list-sessions",
                    detail: trimmed
                )
            )
        }
        return CollectorResult(items: items, warnings: [])
    }

    private static func defaultExecutable() -> URL? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func isNoSessionError(_ result: CommandResult) -> Bool {
        let output = "\(result.stdout)\n\(result.stderr)".lowercased()
        if output.contains("no server") {
            return true
        }
        return output.contains("error connecting") && output.contains("no such file or directory")
    }
}
