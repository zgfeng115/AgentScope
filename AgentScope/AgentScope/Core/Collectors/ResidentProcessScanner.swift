import AppKit
import Darwin
import Foundation

public struct RunningProcess: Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let userID: UInt32
    public let hasTerminal: Bool
    public let executablePath: String
    public let arguments: [String]

    public init(pid: Int32, parentPID: Int32, userID: UInt32, hasTerminal: Bool, executablePath: String, arguments: [String]) {
        self.pid = pid
        self.parentPID = parentPID
        self.userID = userID
        self.hasTerminal = hasTerminal
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

public protocol RunningProcessProviding: Sendable {
    func processes() async -> [RunningProcess]
    /// Bundle paths of apps the user has open in the Dock (activation policy `.regular`): foreground, not background.
    func foregroundApplicationPaths() async -> Set<String>
}

public struct SystemRunningProcessProvider: RunningProcessProviding {
    private let commandRunner: any CommandExecuting

    public init(commandRunner: any CommandExecuting = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func processes() async -> [RunningProcess] {
        async let commResult = try? commandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axww", "-o", "pid=,ppid=,uid=,tty=,comm="],
            timeout: 5,
            environment: nil
        )
        async let argsResult = try? commandRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axww", "-o", "pid=,args="],
            timeout: 5,
            environment: nil
        )
        guard let comm = await commResult else { return [] }
        let args = await argsResult
        return Self.parse(comm: comm.stdout, args: args?.stdout ?? "", resolvePath: Self.nativeExecutablePath)
    }

    public func foregroundApplicationPaths() async -> Set<String> {
        await MainActor.run {
            Set(NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL?.path })
        }
    }

    private static func nativeExecutablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static func parse(
        comm: String,
        args: String,
        resolvePath: (Int32) -> String? = { _ in nil }
    ) -> [RunningProcess] {
        var argumentsByPID: [Int32: [String]] = [:]
        for line in args.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            argumentsByPID[pid] = parts[1].split(separator: " ").map(String.init)
        }
        return comm.split(separator: "\n").compactMap { line in
            let columns = line.split(maxSplits: 4, omittingEmptySubsequences: true) { $0 == " " }
            guard columns.count == 5,
                  let pid = Int32(columns[0]),
                  let parentPID = Int32(columns[1]),
                  let userID = UInt32(columns[2]) else { return nil }
            // ps escapes non-ASCII bytes (vis(3)), so prefer the kernel's real path.
            let path = resolvePath(pid) ?? columns[4].trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { return nil }
            return RunningProcess(
                pid: pid,
                parentPID: parentPID,
                userID: userID,
                hasTerminal: columns[3] != "??",
                executablePath: path,
                arguments: Array((argumentsByPID[pid] ?? []).dropFirst())
            )
        }
    }
}

/// Links running processes to known startup items and turns the rest into "resident process" items.
/// Excluded: Apple/system binaries, other system users, foreground (Dock) apps and their helpers,
/// and interactive terminal processes that are not detached scripts.
public struct ResidentProcessScanner: Sendable {
    private static let systemPrefixes = [
        "/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/", "/Applications/Xcode",
        "/Library/Developer/", "/Library/SystemExtensions/"
    ]
    private static let interpreterNames: Set<String> = [
        "python", "python3", "node", "bun", "deno", "ruby", "perl", "java", "uv", "uvx", "php"
    ]

    private let provider: any RunningProcessProviding
    private let currentUserID: UInt32
    private let ownProcessID: Int32

    public init(
        provider: any RunningProcessProviding = SystemRunningProcessProvider(),
        currentUserID: UInt32 = getuid(),
        ownProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.provider = provider
        self.currentUserID = currentUserID
        self.ownProcessID = ownProcessID
    }

    public func link(_ items: [ServiceItem]) async -> [ServiceItem] {
        let processes = await provider.processes()
        let foreground = await provider.foregroundApplicationPaths()
        var linked = items
        var claimed: Set<Int32> = []

        let (exactIndex, looseIndex) = Self.pathIndexes(for: items)
        for process in processes {
            let exactKeys = [process.executablePath, Self.scriptPath(of: process), Self.innermostAppPath(process.executablePath)]
                .compactMap { $0 }
            if let index = exactKeys.lazy.compactMap({ exactIndex[$0] }).first {
                claimed.insert(process.pid)
                if Self.stateFollowsProcesses.contains(linked[index].sourceType), linked[index].state != .running {
                    linked[index].pid = process.pid
                    linked[index].state = .running
                }
            } else if let app = Self.outermostAppPath(process.executablePath), looseIndex[app] != nil {
                // A helper of an app we already list: not a separate resident, but no state change either.
                claimed.insert(process.pid)
            }
        }

        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: [RunningProcess]] = [:]
        for process in processes where !claimed.contains(process.pid)
            && !Self.belongsToInteractiveSession(process, byPID: byPID)
            && isResidentCandidate(process, foreground: foreground) {
            groups[Self.groupKey(for: process), default: []].append(process)
        }
        let residents = groups.keys.sorted().map { key in Self.residentItem(key: key, processes: groups[key]!) }
        return linked + residents
    }

    private func isResidentCandidate(_ process: RunningProcess, foreground: Set<String>) -> Bool {
        guard process.pid != ownProcessID, process.pid > 1 else { return false }
        guard process.userID == currentUserID || process.userID == 0 else { return false }
        let path = process.executablePath
        if let script = Self.scriptPath(of: process) {
            if Self.systemPrefixes.contains(where: script.hasPrefix) { return false }
            return !process.hasTerminal || process.parentPID == 1
        }
        if Self.systemPrefixes.contains(where: path.hasPrefix) { return false }
        if path.contains("/AgentScope.app/") { return false }
        if let app = Self.outermostAppPath(path), foreground.contains(app) { return false }
        return !process.hasTerminal
    }

    /// Children of a terminal process (test runners, dev-server workers) belong to that interactive session.
    private static func belongsToInteractiveSession(_ process: RunningProcess, byPID: [Int32: RunningProcess]) -> Bool {
        var parentPID = process.parentPID
        var depth = 0
        while parentPID > 1, depth < 16, let parent = byPID[parentPID] {
            if parent.hasTerminal { return true }
            parentPID = parent.parentPID
            depth += 1
        }
        return false
    }

    /// Sources without their own authoritative run state; launchd items keep what `launchctl` reports.
    private static let stateFollowsProcesses: Set<SourceType> = [
        .loginItem, .embeddedLoginItem, .backgroundTask, .privilegedHelper
    ]

    /// Exact: the program / script / helper bundle itself. Loose: the app bundle an item lives in.
    /// Shared system tools (/bin/bash, /usr/bin/ssh, /usr/bin/open) are never indexed.
    private static func pathIndexes(for items: [ServiceItem]) -> (exact: [String: Int], loose: [String: Int]) {
        var exact: [String: Int] = [:]
        var loose: [String: Int] = [:]
        func add(_ path: String?, to index: inout [String: Int], position: Int) {
            guard let path, !systemPrefixes.contains(where: path.hasPrefix) else { return }
            for candidate in [path, URL(fileURLWithPath: path).resolvingSymlinksInPath().path] where index[candidate] == nil {
                index[candidate] = position
            }
        }
        for (position, item) in items.enumerated() {
            add(item.programPath, to: &exact, position: position)
            add(AppleItemFilter.signingTargetPath(for: item), to: &exact, position: position)
            add(item.programPath.flatMap(outermostAppPath), to: &loose, position: position)
            add(item.ownerAppPath, to: &loose, position: position)
        }
        return (exact, loose)
    }

    static func innermostAppPath(_ path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func outermostAppPath(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else {
            return nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func scriptPath(of process: RunningProcess) -> String? {
        let name = URL(fileURLWithPath: process.executablePath).lastPathComponent.lowercased()
        let isInterpreter = interpreterNames.contains(name) || name.hasPrefix("python3.")
        guard isInterpreter else { return nil }
        return process.arguments.first { $0.hasPrefix("/") && !$0.hasPrefix("-") }
    }

    private static func groupKey(for process: RunningProcess) -> String {
        if let script = scriptPath(of: process) {
            return outermostAppPath(script) ?? script
        }
        return outermostAppPath(process.executablePath) ?? process.executablePath
    }

    private static func residentItem(key: String, processes: [RunningProcess]) -> ServiceItem {
        let primary = processes.min { $0.pid < $1.pid }!
        let isApp = key.hasSuffix(".app")
        let script = isApp ? nil : scriptPath(of: primary)
        let name = URL(fileURLWithPath: key).deletingPathExtension().lastPathComponent
        let detail = processes.count > 1
            ? "当前共 \(processes.count) 个进程在运行，未找到对应的启动项或定时任务。"
            : "进程正在运行，未找到对应的启动项或定时任务（可能是手动启动或由其他程序拉起）。"
        return ServiceItem(
            id: "process:\(key)",
            name: isApp ? name : (script.map { URL(fileURLWithPath: $0).lastPathComponent } ?? name),
            sourceType: .process,
            scope: primary.userID == 0 ? .global : .user,
            programPath: script ?? (isApp ? key : primary.executablePath),
            arguments: primary.arguments,
            state: .running,
            pid: primary.pid,
            validity: .healthy,
            bundleIdentifier: isApp ? Bundle(path: key)?.bundleIdentifier : nil,
            ownerAppPath: isApp ? key : nil,
            evidence: [Evidence(title: "常驻进程", detail: detail, severity: .info)]
        )
    }
}
