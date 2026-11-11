import Darwin
import Foundation

public enum LaunchdDomain: Equatable, Sendable {
    case gui
    case system
}

public struct LaunchdSource: Sendable {
    public let directoryURL: URL
    public let scope: Scope
    public let domain: LaunchdDomain

    public init(directoryURL: URL, scope: Scope, domain: LaunchdDomain) {
        self.directoryURL = directoryURL
        self.scope = scope
        self.domain = domain
    }

    public static func defaultSources(userID: UInt32 = getuid()) -> [LaunchdSource] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        _ = userID
        return [
            LaunchdSource(
                directoryURL: home.appending(path: "Library/LaunchAgents"),
                scope: .user,
                domain: .gui
            ),
            LaunchdSource(
                directoryURL: URL(fileURLWithPath: "/Library/LaunchAgents"),
                scope: .global,
                domain: .gui
            ),
            LaunchdSource(
                directoryURL: URL(fileURLWithPath: "/Library/LaunchDaemons"),
                scope: .global,
                domain: .system
            )
        ]
    }
}

public struct LaunchdCollector: Collector {
    private let sources: [LaunchdSource]
    private let commandRunner: any CommandExecuting
    private let validityChecker: ValidityChecker
    private let signatureInspector: SignatureInspector
    private let inspectSignatures: Bool
    private let userID: UInt32

    public init(
        sources: [LaunchdSource]? = nil,
        commandRunner: any CommandExecuting = CommandRunner(),
        validityChecker: ValidityChecker = ValidityChecker(),
        inspectSignatures: Bool = false,
        userID: UInt32 = getuid()
    ) {
        self.sources = sources ?? LaunchdSource.defaultSources(userID: userID)
        self.commandRunner = commandRunner
        self.validityChecker = validityChecker
        self.signatureInspector = SignatureInspector(commandRunner: commandRunner)
        self.inspectSignatures = inspectSignatures
        self.userID = userID
    }

    public func collect() async -> CollectorResult {
        var items: [ServiceItem] = []
        var warnings: [String] = []

        for source in sources {
            let result = await collect(source: source)
            items.append(contentsOf: result.items)
            warnings.append(contentsOf: result.warnings)
        }

        var itemsByID: [String: ServiceItem] = [:]
        for item in items where itemsByID[item.id] == nil {
            itemsByID[item.id] = item
        }

        return CollectorResult(
            items: itemsByID.values.sorted { $0.id < $1.id },
            warnings: warnings
        )
    }

    private func collect(source: LaunchdSource) async -> CollectorResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.directoryURL.path) else {
            return CollectorResult(
                items: [],
                warnings: ["Launchd directory not found: \(source.directoryURL.path)"]
            )
        }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: source.directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "plist" }
            .sorted { $0.path < $1.path }
        } catch {
            return CollectorResult(
                items: [],
                warnings: ["Unable to scan \(source.directoryURL.path): \(error.localizedDescription)"]
            )
        }

        var items: [ServiceItem] = []
        var warnings: [String] = []
        let overrides = await disabledOverrides(domain: source.domain)
        for url in urls {
            do {
                let plist = try readPlist(at: url)
                let fallbackLabel = url.deletingPathExtension().lastPathComponent
                let label = normalizedLabel(plist["Label"] as? String, fallback: fallbackLabel)
                let programArguments = (plist["ProgramArguments"] as? [String]) ?? []
                let explicitProgram = plist["Program"] as? String
                let programPath = explicitProgram ?? programArguments.first
                let arguments = programArguments.first == programPath
                    ? Array(programArguments.dropFirst())
                    : programArguments
                let validity = validityChecker.check(
                    configurationURL: url,
                    programPath: programPath,
                    arguments: arguments
                )
                let snapshot = await launchctlSnapshot(for: label, domain: source.domain)
                let disabled = overrides[label] ?? ((plist["Disabled"] as? Bool) ?? false)
                let signature = inspectSignatures && programPath != nil
                    ? await signatureInspector.inspect(path: programPath!)
                    : .unknown
                let sourceType: SourceType = source.domain == .system ? .launchDaemon : .launchAgent
                let isPeriodic = plist["StartInterval"] != nil || plist["StartCalendarInterval"] != nil
                let lastRun = isPeriodic && snapshot?.isRunning != true ? Self.logFileModificationDate(plist) : nil

                let idPrefix = sourceType == .launchDaemon ? "launchdaemon" : "launchagent"
                items.append(ServiceItem(
                    id: "\(idPrefix):\(source.scope.rawValue):\(label)",
                    name: label,
                    sourceType: sourceType,
                    scope: source.scope,
                    label: label,
                    configurationPath: url.path,
                    programPath: programPath,
                    arguments: arguments,
                    state: state(disabled: disabled, snapshot: snapshot),
                    pid: snapshot?.pid,
                    lastRunAt: lastRun,
                    lastRunPrecision: lastRun == nil ? .unknown : .approximate,
                    lastExitCode: snapshot?.lastExitCode,
                    disabled: disabled,
                    validity: validity,
                    signature: signature,
                    triggers: triggers(from: plist),
                    executionEvidence: ExecutionEvidence(
                        lastExecutionAt: lastRun,
                        precision: lastRun == nil ? .unknown : .approximate,
                        lastExitCode: snapshot?.lastExitCode,
                        consecutiveFailures: (snapshot?.lastExitCode ?? 0) == 0 ? 0 : 1,
                        source: lastRun == nil ? "launchctl" : "launchctl + 日志文件修改时间",
                        detail: snapshot?.state,
                        runCount: snapshot?.runs
                    )
                ))
            } catch {
                items.append(unreadableItem(url: url, source: source, error: error))
            }
        }

        return CollectorResult(items: items, warnings: warnings)
    }

    /// A plist that cannot be read (typically a symlink left behind by an uninstalled app) is itself a finding.
    private func unreadableItem(url: URL, source: LaunchdSource, error: Error) -> ServiceItem {
        let label = url.deletingPathExtension().lastPathComponent
        let sourceType: SourceType = source.domain == .system ? .launchDaemon : .launchAgent
        let idPrefix = sourceType == .launchDaemon ? "launchdaemon" : "launchagent"
        let linkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        let detail = linkDestination.map { "配置文件是指向 \($0) 的链接，但链接目标已不存在（安装它的程序可能已卸载）" }
            ?? "配置文件无法读取：\(error.localizedDescription)"
        return ServiceItem(
            id: "\(idPrefix):\(source.scope.rawValue):\(label)",
            name: label,
            sourceType: sourceType,
            scope: source.scope,
            label: label,
            configurationPath: url.path,
            state: .stale,
            validity: linkDestination == nil ? .invalidConfiguration : .missingTarget,
            evidence: [Evidence(title: "配置文件失效", detail: detail, severity: .warning)]
        )
    }

    private func readPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw CollectorError.invalidPlistDictionary
        }
        return plist
    }

    private func normalizedLabel(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func launchctlSnapshot(for label: String, domain: LaunchdDomain) async -> LaunchctlSnapshot? {
        let target: String
        switch domain {
        case .gui:
            target = "gui/\(userID)/\(label)"
        case .system:
            target = "system/\(label)"
        }

        do {
            let result = try await commandRunner.run(
                executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["print", target],
                timeout: 2,
                environment: nil
            )
            return LaunchctlParser.parse(result.stdout)
        } catch {
            return nil
        }
    }

    private func disabledOverrides(domain: LaunchdDomain) async -> [String: Bool] {
        let target = domain == .gui ? "gui/\(userID)" : "system"
        guard let result = try? await commandRunner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["print-disabled", target],
            timeout: 2,
            environment: nil
        ) else { return [:] }
        return LaunchdCollector.parseDisabledOverrides(result.stdout)
    }

    /// Parses `"label" => disabled|enabled|true|false` lines from `launchctl print-disabled`.
    static func parseDisabledOverrides(_ output: String) -> [String: Bool] {
        var overrides: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard !label.isEmpty else { continue }
            switch value {
            case "disabled", "true": overrides[label] = true
            case "enabled", "false": overrides[label] = false
            default: continue
            }
        }
        return overrides
    }

    private func state(disabled: Bool, snapshot: LaunchctlSnapshot?) -> ServiceState {
        if disabled { return .disabled }
        guard let snapshot else { return .stopped }
        if snapshot.isRunning { return .running }
        if snapshot.state?.lowercased() == "failed" { return .failed }
        return .stopped
    }

    /// A periodic job's stdout/stderr file is rewritten on each run, so its mtime approximates the last run.
    static func logFileModificationDate(_ plist: [String: Any]) -> Date? {
        ["StandardOutPath", "StandardErrorPath"]
            .compactMap { plist[$0] as? String }
            .map { NSString(string: $0).expandingTildeInPath }
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
            .max()
    }

    private func triggers(from plist: [String: Any]) -> [TriggerInfo] {
        var result: [TriggerInfo] = []
        if (plist["RunAtLoad"] as? Bool) == true {
            result.append(TriggerInfo(kind: .runAtLoad, summary: "登录或加载时运行"))
        }
        if plist["KeepAlive"] != nil {
            result.append(TriggerInfo(kind: .keepAlive, summary: "保持服务存活"))
        }
        if let interval = plist["StartInterval"] as? NSNumber {
            result.append(TriggerInfo(
                kind: .startInterval,
                summary: "每 \(interval.intValue) 秒运行",
                expression: interval.stringValue
            ))
        }
        if plist["StartCalendarInterval"] != nil {
            let expressions = ScheduleCalculator.cronExpressions(fromLaunchd: plist["StartCalendarInterval"])
            let summary = expressions.isEmpty
                ? "按日历计划运行"
                : expressions.map { ScheduleCalculator.describe(cron: $0) }.joined(separator: "；")
            result.append(TriggerInfo(
                kind: .calendar,
                summary: summary,
                expression: expressions.isEmpty ? nil : expressions.joined(separator: ";")
            ))
        }
        let watched = ((plist["WatchPaths"] as? [String]) ?? []) + ((plist["QueueDirectories"] as? [String]) ?? [])
        if !watched.isEmpty {
            result.append(TriggerInfo(
                kind: .watchPaths,
                summary: "文件变化时运行：\(watched.joined(separator: "、"))",
                expression: watched.joined(separator: ";")
            ))
        }
        return result
    }
}

private enum CollectorError: LocalizedError {
    case invalidPlistDictionary

    var errorDescription: String? {
        switch self {
        case .invalidPlistDictionary:
            return "Invalid plist dictionary"
        }
    }
}
