import Foundation

public enum UninstallFileKind: String, Codable, Hashable, Sendable {
    case plist
    case program
    case helper
    case script
    case kext

    public var displayName: String {
        switch self {
        case .plist: return "启动配置"
        case .program: return "程序文件"
        case .helper: return "特权助手"
        case .script: return "脚本文件"
        case .kext: return "内核扩展"
        }
    }
}

public struct UninstallFile: Hashable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let kind: UninstallFileKind
    public let requiresAdmin: Bool
    /// Only set for kexts: unloaded before the move.
    public let bundleIdentifier: String?
    public let note: String?
}

public struct LaunchdBootout: Hashable, Sendable {
    public let target: String          // "gui/501/label" or "system/label"
    public var requiresAdmin: Bool { target.hasPrefix("system/") }
}

public struct UninstallSkip: Hashable, Sendable {
    public let path: String
    public let reason: String
}

public struct UninstallPlan: Hashable, Sendable {
    public let title: String
    public let serviceIDs: [String]
    public let labels: [String]
    public let bootouts: [LaunchdBootout]
    /// Always removed.
    public let files: [UninstallFile]
    /// Off unless the user ticks them (self-made scripts, kexts).
    public let optionalFiles: [UninstallFile]
    /// Exact crontab lines (expression + command) to remove.
    public let cronEntries: [CronLine]
    public let skipped: [UninstallSkip]
    public let notes: [String]

    public var isEmpty: Bool { files.isEmpty && optionalFiles.isEmpty && cronEntries.isEmpty && bootouts.isEmpty }

    public func requiresAdmin(selectedOptional: Set<String>) -> Bool {
        bootouts.contains(where: \.requiresAdmin)
            || files.contains(where: \.requiresAdmin)
            || optionalFiles.contains { selectedOptional.contains($0.path) && $0.requiresAdmin }
    }
}

public struct CronLine: Hashable, Sendable {
    public let expression: String
    public let command: String
}

public enum UninstallPlanner {
    /// Paths that belong to macOS or a package manager; never moved.
    static let protectedPrefixes = [
        "/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/lib/",
        "/opt/homebrew/bin/", "/opt/homebrew/opt/", "/opt/homebrew/Cellar/", "/usr/local/bin/",
        "/usr/local/opt/", "/usr/local/Cellar/", "/Library/Apple/"
    ]

    /// Uninstall is offered only where removing is the expected outcome: leftovers, the user's own scripts,
    /// orphaned privileged helpers and kexts. Healthy third-party items stay read-only.
    public static func isEligible(_ item: ServiceItem) -> Bool {
        switch item.sourceType {
        case .launchAgent, .launchDaemon, .cron:
            return isLeftover(item) || item.purpose == .userScript
        case .privilegedHelper:
            return true   // only orphans are listed as separate helper items
        case .kernelExtension, .systemExtension:
            return isLeftover(item)
        default:
            return false
        }
    }

    /// Leftover signals only. A failing item whose app is still installed is a problem to fix, not to delete.
    public static func isLeftover(_ item: ServiceItem) -> Bool {
        item.ownerAppStatus == .missing || item.state == .stale || item.validity == .missingTarget
    }

    public static func plan(
        title: String,
        items: [ServiceItem],
        allItems: [ServiceItem],
        userID: UInt32 = getuid(),
        fileExists: (String) -> Bool = UninstallPlanner.pathExists,
        isUserDeletable: (String) -> Bool = UninstallPlanner.isUserDeletable
    ) -> UninstallPlan {
        let targets = items.filter(isEligible)
        let targetIDs = Set(targets.map(\.id))
        let others = allItems.filter { !targetIDs.contains($0.id) }

        var bootouts: [LaunchdBootout] = []
        var files: [UninstallFile] = []
        var optional: [UninstallFile] = []
        var cron: [CronLine] = []
        var skipped: [UninstallSkip] = []
        var notes: [String] = []
        var seen: Set<String> = []

        func needsAdmin(_ path: String) -> Bool { !isUserDeletable(path) }

        func add(_ path: String, _ kind: UninstallFileKind, optionalFile: Bool = false, bundleID: String? = nil, note: String? = nil) {
            guard seen.insert(path).inserted else { return }
            let file = UninstallFile(path: path, kind: kind, requiresAdmin: needsAdmin(path), bundleIdentifier: bundleID, note: note)
            if optionalFile { optional.append(file) } else { files.append(file) }
        }

        /// Why a program file must stay, or nil when it may go.
        func keepReason(_ path: String, owner: ServiceItem) -> String? {
            if protectedPrefixes.contains(where: path.hasPrefix) { return "系统或包管理器自带的程序" }
            if let appRange = path.range(of: ".app/") {
                let appPath = String(path[..<appRange.lowerBound]) + ".app"
                if fileExists(appPath) { return "属于仍安装的应用 \(URL(fileURLWithPath: appPath).lastPathComponent)" }
            }
            if let user = others.first(where: { $0.programPath == path || $0.arguments.contains(path) }) {
                return "仍被「\(user.name)」使用"
            }
            return nil
        }

        for item in targets {
            switch item.sourceType {
            case .launchAgent, .launchDaemon:
                if let label = item.label {
                    let target = item.sourceType == .launchDaemon ? "system/\(label)" : "gui/\(userID)/\(label)"
                    bootouts.append(LaunchdBootout(target: target))
                }
                if let plist = item.configurationPath, fileExists(plist) {
                    add(plist, .plist)
                }
                guard let program = targetProgram(of: item, fileExists: fileExists),
                      fileExists(program) else { continue }
                if let reason = keepReason(program, owner: item) {
                    skipped.append(UninstallSkip(path: program, reason: reason))
                } else if item.purpose == .userScript {
                    add(program, .script, optionalFile: true, note: "你自己的脚本，默认保留")
                } else if item.ownerAppStatus == .missing {
                    add(program, program.hasPrefix("/Library/PrivilegedHelperTools/") ? .helper : .program)
                } else {
                    skipped.append(UninstallSkip(path: program, reason: "无法确认是残留，保留"))
                }
            case .privilegedHelper:
                if let path = item.programPath, fileExists(path) {
                    if let reason = keepReason(path, owner: item) {
                        skipped.append(UninstallSkip(path: path, reason: reason))
                    } else {
                        add(path, .helper)
                    }
                }
            case .kernelExtension:
                if let path = item.programPath, fileExists(path) {
                    add(path, .kext, optionalFile: true, bundleID: item.label, note: "重启后生效")
                }
            case .systemExtension:
                notes.append(item.ownerAppStatus == .installed
                    ? "系统扩展「\(item.name)」需把所属应用移到废纸篓，由 macOS 自动卸载（开启 SIP 时无法直接删除）。"
                    : "系统扩展「\(item.name)」的应用已不在，macOS 会在下次重启时清除它。")
            case .cron:
                if let expression = item.label, let command = item.executionEvidence?.detail {
                    cron.append(CronLine(expression: expression, command: command))
                }
            default:
                continue
            }
        }

        if optional.contains(where: { $0.kind == .kext }) {
            notes.append("内核扩展默认不删；勾选后会先尝试卸载，再移到废纸篓，重启后完全生效。")
        }

        return UninstallPlan(
            title: title,
            serviceIDs: targets.map(\.id),
            labels: targets.compactMap(\.label),
            bootouts: bootouts,
            files: files,
            optionalFiles: optional,
            cronEntries: cron,
            skipped: skipped,
            notes: notes
        )
    }

    /// The file that actually does the work: the script for `bash x.sh` / `python x.py`, else the program.
    static func targetProgram(of item: ServiceItem, fileExists: (String) -> Bool) -> String? {
        guard let program = item.programPath, program.hasPrefix("/") else { return nil }
        let name = URL(fileURLWithPath: program).lastPathComponent
        guard AppleItemFilter.isInterpreter(name) else { return program }
        return item.arguments.first { $0.hasPrefix("/") && fileExists($0) } ?? program
    }

    /// Moving needs write access to the parent directory (and, with the sticky bit, ownership).
    public static func isUserDeletable(_ path: String) -> Bool {
        FileManager.default.isDeletableFile(atPath: path)
    }

    /// True for regular files, directories and dangling symlinks (left behind by uninstallers).
    public static func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }
}
