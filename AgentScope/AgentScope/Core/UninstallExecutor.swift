import Foundation

public struct UninstallReport: Hashable, Sendable {
    public var moved: [(from: String, to: String)] = []
    public var removedCronLines = 0
    public var crontabBackup: String?
    public var failures: [String] = []

    public var summary: String {
        var lines = moved.map { "\($0.from) → \($0.to)" }
        if removedCronLines > 0 {
            lines.append("已从 crontab 移除 \(removedCronLines) 行，原 crontab 备份在 \(crontabBackup ?? "-")")
        }
        lines.append(contentsOf: failures.map { "失败：\($0)" })
        return lines.joined(separator: "\n")
    }

    public static func == (lhs: UninstallReport, rhs: UninstallReport) -> Bool {
        lhs.summary == rhs.summary
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(summary)
    }
}

public enum UninstallError: LocalizedError, Equatable {
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "已取消管理员授权，未做任何改动。"
        case .failed(let message): return "卸载失败：\(message)"
        }
    }
}

public protocol Uninstalling: Sendable {
    func uninstall(_ plan: UninstallPlan, selectedOptional: Set<String>) async throws -> UninstallReport
}

/// Stops launchd jobs, then moves files to the user's Trash (recoverable). Root-owned files go through a
/// single `osascript … with administrator privileges` call (one password prompt): root moves them into a
/// staging folder in Application Support and hands them to the user, then the app trashes them itself —
/// root writing into `~/.Trash` directly can be refused by macOS privacy protection.
public struct UninstallExecutor: Uninstalling {
    private let commandRunner: any CommandExecuting
    private let stagingRoot: URL
    private let backupRoot: URL
    private let userID: UInt32
    private let groupID: UInt32
    private let now: @Sendable () -> Date

    public init(
        commandRunner: any CommandExecuting = CommandRunner(),
        stagingRoot: URL,
        backupRoot: URL,
        userID: UInt32 = getuid(),
        groupID: UInt32 = getgid(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.commandRunner = commandRunner
        self.stagingRoot = stagingRoot
        self.backupRoot = backupRoot
        self.userID = userID
        self.groupID = groupID
        self.now = now
    }

    public func uninstall(_ plan: UninstallPlan, selectedOptional: Set<String>) async throws -> UninstallReport {
        var report = UninstallReport()
        let chosen = plan.files + plan.optionalFiles.filter { selectedOptional.contains($0.path) }
        let adminFiles = chosen.filter(\.requiresAdmin)
        let adminBootouts = plan.bootouts.filter(\.requiresAdmin)

        // Admin part first: if the user cancels the password prompt nothing has changed yet.
        if !adminFiles.isEmpty || !adminBootouts.isEmpty {
            let batch = stagingRoot.appending(path: Self.stampFormatter.string(from: now()))
            let moves = adminFiles.enumerated().map { index, file in
                (file, batch.appending(path: "\(index + 1)-\(URL(fileURLWithPath: file.path).lastPathComponent)").path)
            }
            let script = Self.adminScript(
                bootouts: adminBootouts, moves: moves, stagingDirectory: batch.path, owner: "\(userID):\(groupID)"
            )
            let staged: [(from: String, to: String)]
            do {
                let result = try await commandRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/osascript"),
                    arguments: ["-e", Self.appleScript(running: script)],
                    timeout: 300,
                    environment: nil
                )
                staged = Self.parseMoved(result.stdout)
            } catch CommandRunnerError.nonZeroExit(let failed) {
                if failed.stderr.contains("-128") { throw UninstallError.cancelled }
                throw UninstallError.failed(failed.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            for move in staged {
                if let trashed = Self.trash(move.to) {
                    report.moved.append((move.from, trashed))
                } else {
                    report.moved.append((move.from, move.to))
                }
            }
            try? FileManager.default.removeItem(at: batch)   // only succeeds once empty
            let movedSources = Set(staged.map(\.from))
            for file in adminFiles where !movedSources.contains(file.path) {
                report.failures.append(file.path)
            }
        }

        for bootout in plan.bootouts where !bootout.requiresAdmin {
            _ = try? await commandRunner.run(
                executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["bootout", bootout.target],
                timeout: 10,
                environment: nil
            )
        }

        for file in chosen where !file.requiresAdmin {
            if let trashed = Self.trash(file.path) {
                report.moved.append((file.path, trashed))
            } else {
                report.failures.append(file.path)
            }
        }

        if !plan.cronEntries.isEmpty {
            do {
                try await removeCronEntries(plan.cronEntries, report: &report)
            } catch {
                report.failures.append("crontab（\(error.localizedDescription)）")
            }
        }
        return report
    }

    private static func trash(_ path: String) -> String? {
        var resulting: NSURL?
        guard (try? FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)) != nil else {
            return nil
        }
        return resulting?.path ?? "废纸篓"
    }

    // MARK: - cron

    private func removeCronEntries(_ entries: [CronLine], report: inout UninstallReport) async throws {
        let crontab = URL(fileURLWithPath: "/usr/bin/crontab")
        let current = try await commandRunner.run(executable: crontab, arguments: ["-l"], timeout: 5, environment: nil).stdout
        let (kept, removed) = Self.filterCrontab(current, removing: entries)
        guard removed > 0 else { return }

        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let stamp = Self.stampFormatter.string(from: now())
        let backup = backupRoot.appending(path: "crontab-\(stamp).txt")
        try current.write(to: backup, atomically: true, encoding: .utf8)
        // crontab(1) truncates long file paths (~100 chars), so the replacement goes to a short private /tmp path.
        let replacement = URL(fileURLWithPath: "/tmp/agentscope-cron-\(UUID().uuidString.prefix(8))")
        try kept.write(to: replacement, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacement.path)
        defer { try? FileManager.default.removeItem(at: replacement) }
        // macOS asks the user to allow "administering this computer" the first time crontab is changed.
        _ = try await commandRunner.run(executable: crontab, arguments: [replacement.path], timeout: 120, environment: nil)
        report.removedCronLines = removed
        report.crontabBackup = backup.path
    }

    static func filterCrontab(_ text: String, removing entries: [CronLine]) -> (String, Int) {
        var removed = 0
        let lines = text.components(separatedBy: "\n").filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let entry = CronEntry.parse(trimmed),
                  entries.contains(CronLine(expression: entry.expression, command: entry.command))
            else { return true }
            removed += 1
            return false
        }
        var result = lines.joined(separator: "\n")
        if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
        return (result, removed)
    }

    // MARK: - admin script

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func adminScript(
        bootouts: [LaunchdBootout],
        moves: [(UninstallFile, String)],
        stagingDirectory: String,
        owner: String
    ) -> String {
        var lines: [String] = []
        for bootout in bootouts {
            lines.append("/bin/launchctl bootout \(shellQuote(bootout.target)) >/dev/null 2>&1 || true")
        }
        if !moves.isEmpty {
            lines.append("/bin/mkdir -p \(shellQuote(stagingDirectory))")
            lines.append("/usr/sbin/chown \(owner) \(shellQuote(stagingDirectory))")
        }
        for (file, destination) in moves {
            if let bundleID = file.bundleIdentifier, file.kind == .kext {
                lines.append("/usr/bin/kmutil unload -b \(shellQuote(bundleID)) >/dev/null 2>&1 || true")
            }
            let source = shellQuote(file.path)
            let target = shellQuote(destination)
            lines.append(
                "/bin/mv -n \(source) \(target); "
                    + "if [ ! -e \(source) ] && [ ! -L \(source) ]; then "
                    + "/usr/sbin/chown -hR \(owner) \(target); echo MOVED:\(source):\(target); fi"
            )
        }
        lines.append("true")
        return lines.joined(separator: "; ")
    }

    /// Wraps a shell script in an AppleScript string literal.
    static func appleScript(running script: String, admin: Bool = true) -> String {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\"" + (admin ? " with administrator privileges" : "")
    }

    /// `echo MOVED:'a':'b'` prints `MOVED:a:b`; paths can contain ':' so split on the known destination prefix.
    static func parseMoved(_ output: String) -> [(from: String, to: String)] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("MOVED:") else { return nil }
            let body = line.dropFirst("MOVED:".count)
            guard let range = body.range(of: ":/", options: .backwards) else { return nil }
            return (String(body[..<range.lowerBound]), String(body[body.index(after: range.lowerBound)...]))
        }
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
