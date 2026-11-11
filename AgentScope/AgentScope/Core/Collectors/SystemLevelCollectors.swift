import Foundation

// MARK: - Privileged helper tools

/// Lists `/Library/PrivilegedHelperTools`. Helpers already run by a LaunchDaemon are represented by that daemon
/// and skipped here; helpers that no daemon references are orphans left behind by uninstalled apps.
public struct PrivilegedHelperCollector: Collector {
    private let helperDirectory: URL
    private let daemonDirectory: URL

    public init(
        helperDirectory: URL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools"),
        daemonDirectory: URL = URL(fileURLWithPath: "/Library/LaunchDaemons")
    ) {
        self.helperDirectory = helperDirectory
        self.daemonDirectory = daemonDirectory
    }

    public func collect() async -> CollectorResult {
        let fileManager = FileManager.default
        guard let helpers = try? fileManager.contentsOfDirectory(
            at: helperDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return CollectorResult(items: [], warnings: [])
        }
        let daemons = daemonReferences()

        let items = helpers.sorted { $0.path < $1.path }.compactMap { helper -> ServiceItem? in
            let name = helper.lastPathComponent
            if daemons.programs.contains(helper.resolvingSymlinksInPath().path) { return nil }
            let label = daemons.labels.contains(name) ? name : nil
            let evidence = label == nil
                ? Evidence(
                    title: "孤儿特权助手",
                    detail: "没有任何 LaunchDaemon 配置引用它，launchd 不会启动它；可能是安装器用过的一次性助手，或主程序卸载后的残留。",
                    severity: .warning
                )
                : Evidence(
                    title: "由 LaunchDaemon 管理",
                    detail: "同名 LaunchDaemon \(name) 存在，但其启动程序不是这个文件。",
                    severity: .info
                )
            return ServiceItem(
                id: "privilegedhelper:\(name)",
                name: name,
                sourceType: .privilegedHelper,
                scope: .global,
                label: name,
                programPath: helper.path,
                state: label == nil ? .stale : .discovered,
                validity: .healthy,
                evidence: [evidence]
            )
        }
        return CollectorResult(items: items, warnings: [])
    }

    private func daemonReferences() -> (labels: Set<String>, programs: Set<String>) {
        guard let plists = try? FileManager.default.contentsOfDirectory(
            at: daemonDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return ([], [])
        }
        var labels: Set<String> = []
        var programs: Set<String> = []
        for url in plists where url.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                continue
            }
            labels.insert((plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent)
            let program = (plist["Program"] as? String) ?? (plist["ProgramArguments"] as? [String])?.first
            if let program {
                programs.insert(URL(fileURLWithPath: program).resolvingSymlinksInPath().path)
            }
        }
        return (labels, programs)
    }
}

// MARK: - System extensions

public struct SystemExtensionRecord: Equatable, Sendable {
    public let teamID: String?
    public let bundleIdentifier: String
    public let version: String?
    public let name: String
    public let category: String?
    public let state: String
    public let enabled: Bool
    public let active: Bool
}

/// Parses `systemextensionsctl list` (works without root) into one item per bundle identifier.
public struct SystemExtensionCollector: Collector {
    private let commandRunner: any CommandExecuting

    public init(commandRunner: any CommandExecuting = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func collect() async -> CollectorResult {
        guard let result = try? await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/systemextensionsctl"),
            arguments: ["list"],
            timeout: 5,
            environment: nil
        ) else {
            return CollectorResult(items: [], warnings: ["系统扩展列表不可用（systemextensionsctl 执行失败）"])
        }
        return CollectorResult(items: Self.items(from: Self.parse(result.stdout)), warnings: [])
    }

    static func parse(_ output: String) -> [SystemExtensionRecord] {
        var category: String?
        var records: [SystemExtensionRecord] = []
        for rawLine in output.split(separator: "\n") {
            let line = String(rawLine)
            if line.hasPrefix("---") {
                category = line.split(separator: " ").dropFirst().first.map(String.init)
                continue
            }
            let columns = line.components(separatedBy: "\t")
            guard columns.count >= 6, !columns[0].hasPrefix("enabled") else { continue }
            let bundleColumn = columns[3].trimmingCharacters(in: .whitespaces)
            let bundleIdentifier = bundleColumn.components(separatedBy: " (").first ?? bundleColumn
            guard !bundleIdentifier.isEmpty else { continue }
            let version = bundleColumn.range(of: " (").map {
                String(bundleColumn[$0.upperBound...].dropLast())
            }
            let teamID = columns[2].trimmingCharacters(in: .whitespaces)
            records.append(SystemExtensionRecord(
                teamID: teamID.isEmpty || teamID == "-" ? nil : teamID,
                bundleIdentifier: bundleIdentifier,
                version: version,
                name: columns[4].trimmingCharacters(in: .whitespaces),
                category: category,
                state: columns[5].trimmingCharacters(in: CharacterSet(charactersIn: "[] ")),
                enabled: columns[0].contains("*"),
                active: columns[1].contains("*")
            ))
        }
        return records
    }

    static func items(from records: [SystemExtensionRecord]) -> [ServiceItem] {
        let grouped = Dictionary(grouping: records, by: \.bundleIdentifier)
        return grouped.keys.sorted().compactMap { bundleIdentifier in
            let versions = grouped[bundleIdentifier]!
            let current = versions.first { $0.active } ?? versions.first { $0.enabled } ?? versions.last!
            let pendingRemoval = versions.filter { $0.state.contains("uninstall") }.count
            var evidence = [Evidence(
                title: "系统扩展状态",
                detail: "\(current.state)\(current.category.map { "（\($0)）" } ?? "")",
                severity: .info
            )]
            if pendingRemoval > 0 {
                evidence.append(Evidence(
                    title: "旧版本待清理",
                    detail: "另有 \(pendingRemoval) 个版本等待重启后卸载。",
                    severity: .info
                ))
            }
            let state: ServiceState = current.active && current.enabled
                ? .running
                : current.state.contains("uninstall") ? .stale : .disabled
            return ServiceItem(
                id: "systemextension:\(bundleIdentifier)",
                name: current.name.isEmpty ? bundleIdentifier : current.name,
                sourceType: .systemExtension,
                scope: .global,
                label: bundleIdentifier,
                state: state,
                validity: .healthy,
                signing: current.teamID.map {
                    SigningInfo(signature: .developerID, teamID: $0, signedPath: bundleIdentifier)
                },
                bundleIdentifier: bundleIdentifier,
                evidence: evidence
            )
        }
    }
}

// MARK: - Kernel extensions

/// Third-party kexts in `/Library/Extensions`; Apple's are dropped later by `AppleItemFilter` via bundle id/signature.
public struct KernelExtensionCollector: Collector {
    private let directory: URL
    private let commandRunner: any CommandExecuting

    public init(
        directory: URL = URL(fileURLWithPath: "/Library/Extensions"),
        commandRunner: any CommandExecuting = CommandRunner()
    ) {
        self.directory = directory
        self.commandRunner = commandRunner
    }

    public func collect() async -> CollectorResult {
        guard let bundles = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return CollectorResult(items: [], warnings: [])
        }
        let loaded = await loadedBundleIdentifiers()

        let items = bundles
            .filter { $0.pathExtension == "kext" }
            .sorted { $0.path < $1.path }
            .map { bundle -> ServiceItem in
                let info = Bundle(url: bundle)?.infoDictionary ?? [:]
                let bundleIdentifier = info["CFBundleIdentifier"] as? String
                let name = (info["CFBundleName"] as? String) ?? bundle.deletingPathExtension().lastPathComponent
                let isLoaded = bundleIdentifier.map { loaded?.contains($0) == true } ?? false
                let stateDetail: String
                if loaded == nil {
                    stateDetail = "无法读取已加载内核扩展列表"
                } else {
                    stateDetail = isLoaded ? "当前已加载到内核" : "未加载（Apple 芯片默认不加载第三方内核扩展，多为旧驱动残留）"
                }
                return ServiceItem(
                    id: "kext:\(bundle.lastPathComponent)",
                    name: name,
                    sourceType: .kernelExtension,
                    scope: .global,
                    label: bundleIdentifier,
                    programPath: bundle.path,
                    state: loaded == nil ? .discovered : (isLoaded ? .running : .stopped),
                    validity: .healthy,
                    bundleIdentifier: bundleIdentifier,
                    evidence: [Evidence(title: "加载状态", detail: stateDetail, severity: .info)]
                )
            }
        return CollectorResult(items: items, warnings: [])
    }

    private func loadedBundleIdentifiers() async -> Set<String>? {
        guard let result = try? await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/kmutil"),
            arguments: ["showloaded", "--list-only"],
            timeout: 10,
            environment: nil
        ) else {
            return nil
        }
        return Self.parseLoaded(result.stdout)
    }

    /// Each kmutil row contains the bundle identifier as the token followed by "(version)".
    static func parseLoaded(_ output: String) -> Set<String> {
        var identifiers: Set<String> = []
        for line in output.split(separator: "\n") {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            for (index, token) in tokens.enumerated() where token.hasPrefix("(") && index > 0 {
                identifiers.insert(String(tokens[index - 1]))
                break
            }
        }
        return identifiers
    }
}
