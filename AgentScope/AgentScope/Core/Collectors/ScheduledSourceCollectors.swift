import Foundation

public struct CronCollector: Collector {
    private let sourceText: String?
    private let commandRunner: any CommandExecuting
    private let userName: String

    public init(
        sourceText: String? = nil,
        commandRunner: any CommandExecuting = CommandRunner(),
        userName: String = NSUserName()
    ) {
        self.sourceText = sourceText
        self.commandRunner = commandRunner
        self.userName = userName
    }

    public func collect() async -> CollectorResult {
        let text: String
        if let sourceText {
            text = sourceText
        } else {
            do {
                text = try await commandRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/crontab"),
                    arguments: ["-l"],
                    timeout: 3,
                    environment: nil
                ).stdout
            } catch {
                return CollectorResult(items: [], warnings: ["Unable to read user crontab: \(error.localizedDescription)"])
            }
        }

        var items: [ServiceItem] = []
        var warnings: [String] = []
        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let entry = CronEntry.parse(line) else {
                warnings.append("Unable to parse crontab line \(index + 1)")
                continue
            }

            let executable = ShellCommandParser.executable(from: entry.command)
            let arguments = ShellCommandParser.arguments(from: entry.command)
            let displayName = executable ?? entry.command
            let id = "cron:\(userName):\(entry.expression):\(entry.command)"
            items.append(ServiceItem(
                id: id,
                name: displayName,
                sourceType: .cron,
                scope: .user,
                label: entry.expression,
                configurationPath: "crontab:\(userName)",
                programPath: executable,
                arguments: arguments,
                state: .enabled,
                lastRunPrecision: .unknown,
                disabled: false,
                validity: .unknown,
                signature: .unknown,
                triggers: [TriggerInfo(
                    kind: .cron,
                    summary: ScheduleCalculator.describe(cron: entry.expression),
                    expression: entry.expression
                )],
                executionEvidence: ExecutionEvidence(
                    lastExecutionAt: nil,
                    precision: .unknown,
                    lastExitCode: nil,
                    consecutiveFailures: 0,
                    source: "crontab",
                    detail: entry.command
                )
            ))
        }

        return CollectorResult(items: items, warnings: warnings)
    }
}

public struct PeriodicCollector: Collector {
    private let directories: [URL]

    public init(directories: [URL] = PeriodicCollector.defaultDirectories()) {
        self.directories = directories
    }

    /// Third-party periodic scripts; the stock `/etc/periodic` scripts belong to macOS.
    public static func thirdPartyDirectories() -> [URL] {
        ["daily", "weekly", "monthly"].map {
            URL(fileURLWithPath: "/usr/local/etc/periodic").appending(path: $0)
        }
    }

    public static func defaultDirectories() -> [URL] {
        ["daily", "weekly", "monthly"].map {
            URL(fileURLWithPath: "/etc/periodic").appending(path: $0)
        }
    }

    public func collect() async -> CollectorResult {
        let fileManager = FileManager.default
        var items: [ServiceItem] = []
        var warnings: [String] = []

        for directory in directories {
            guard fileManager.fileExists(atPath: directory.path) else { continue }
            let urls: [URL]
            do {
                urls = try fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
                    options: [.skipsHiddenFiles]
                )
                .filter { url in
                    ((try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]))?.isRegularFile == true) &&
                    ((try? url.resourceValues(forKeys: [.isRegularFileKey, .isExecutableKey]))?.isExecutable == true)
                }
                .sorted { $0.path < $1.path }
            } catch {
                warnings.append("Unable to scan periodic directory \(directory.path): \(error.localizedDescription)")
                continue
            }

            for url in urls {
                let validity = ValidityChecker().check(
                    configurationURL: url,
                    programPath: url.path,
                    arguments: []
                )
                items.append(ServiceItem(
                    id: "periodic:system:\(url.path)",
                    name: url.lastPathComponent,
                    sourceType: .periodic,
                    scope: .system,
                    label: url.lastPathComponent,
                    configurationPath: url.path,
                    programPath: url.path,
                    state: .systemReadonly,
                    lastRunPrecision: .unknown,
                    disabled: false,
                    validity: validity,
                    signature: .unknown,
                    triggers: [TriggerInfo(
                        kind: .periodic,
                        summary: "系统 periodic/\(directory.lastPathComponent)"
                    )],
                    executionEvidence: ExecutionEvidence(
                        lastExecutionAt: nil,
                        precision: .unknown,
                        lastExitCode: nil,
                        consecutiveFailures: 0,
                        source: "periodic",
                        detail: "系统周期任务；当前版本仅记录配置，不执行任务"
                    )
                ))
            }
        }

        return CollectorResult(items: items, warnings: warnings)
    }
}

public struct ShellStartupCollector: Collector {
    private let files: [URL]

    public init(files: [URL] = ShellStartupCollector.defaultFiles()) {
        self.files = files
    }

    public static func defaultFiles() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"].map {
            home.appending(path: $0)
        }
    }

    public func collect() async -> CollectorResult {
        let fileManager = FileManager.default
        var items: [ServiceItem] = []
        var warnings: [String] = []

        for file in files {
            guard fileManager.fileExists(atPath: file.path) else { continue }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                warnings.append("Unable to read shell startup file: \(file.path)")
                continue
            }

            for (lineNumber, rawLine) in text.components(separatedBy: .newlines).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard ShellCommandParser.isStartupLike(line) else { continue }
                let executable = ShellCommandParser.executable(from: line)
                let arguments = ShellCommandParser.arguments(from: line)
                items.append(ServiceItem(
                    id: "shellstartup:user:\(file.path):\(lineNumber + 1)",
                    name: executable ?? "shell command",
                    sourceType: .shellStartup,
                    scope: .user,
                    label: "\(file.lastPathComponent):\(lineNumber + 1)",
                    configurationPath: file.path,
                    programPath: executable,
                    arguments: arguments,
                    state: .enabled,
                    lastRunPrecision: .unknown,
                    disabled: false,
                    validity: .unknown,
                    signature: .unknown,
                    triggers: [TriggerInfo(
                        kind: .shellStartup,
                        summary: "Shell 启动文件：\(file.lastPathComponent):\(lineNumber + 1)",
                        expression: line
                    )],
                    executionEvidence: ExecutionEvidence(
                        lastExecutionAt: nil,
                        precision: .unknown,
                        lastExitCode: nil,
                        consecutiveFailures: 0,
                        source: "shell startup",
                        detail: line
                    )
                ))
            }
        }

        return CollectorResult(items: items, warnings: warnings)
    }
}

struct CronEntry {
    let expression: String
    let command: String

    static func parse(_ line: String) -> CronEntry? {
        let tokens = line.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
        guard !tokens.isEmpty else { return nil }
        if tokens[0].hasPrefix("@") {
            guard tokens.count >= 2 else { return nil }
            return CronEntry(expression: String(tokens[0]), command: tokens.dropFirst().joined(separator: " "))
        }
        guard tokens.count >= 6 else { return nil }
        return CronEntry(
            expression: tokens.prefix(5).joined(separator: " "),
            command: tokens.dropFirst(5).joined(separator: " ")
        )
    }
}

enum ShellCommandParser {
    static func isStartupLike(_ line: String) -> Bool {
        guard !line.isEmpty, !line.hasPrefix("#") else { return false }
        let lowercased = line.lowercased()
        let controlPrefixes = [
            "[", "[[", "if ", "then", "else", "elif ", "fi", "case ",
            "esac", "for ", "while ", "until ", "function ", "{", "}"
        ]
        if controlPrefixes.contains(where: { lowercased.hasPrefix($0) }) {
            return false
        }
        let executable = executable(from: line)?.lowercased()
        if ["[", "/bin/[", "test", "/bin/test", "/usr/bin/test"].contains(executable) {
            return false
        }
        if lowercased.contains("brew services") || lowercased.contains("docker compose") {
            return true
        }
        if lowercased.contains("tmux new") || lowercased.contains("nohup") {
            return true
        }
        return line.contains("&") && !lowercased.hasPrefix("export ") && !lowercased.hasPrefix("alias ")
    }

    static func executable(from command: String) -> String? {
        var tokens = command
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { String($0).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "") }
        while let first = tokens.first,
              ["nohup", "env", "command", "exec", "sudo"].contains(first) {
            tokens.removeFirst()
        }
        while let first = tokens.first, first.contains("=") && !first.hasPrefix("/") {
            tokens.removeFirst()
        }
        guard let token = tokens.first, !token.isEmpty else { return nil }
        if token.contains("/") { return token }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appending(path: token).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return token
    }

    static func arguments(from command: String) -> [String] {
        let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let executable = executable(from: command), let index = tokens.firstIndex(where: {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) == executable ||
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).hasSuffix("/\(executable)")
        }) else { return [] }
        return Array(tokens.dropFirst(tokens.distance(from: tokens.startIndex, to: index) + 1))
    }
}
