public struct LaunchctlSnapshot: Equatable, Sendable {
    public let state: String?
    public let pid: Int32?
    public let lastExitCode: Int32?
    public let program: String?
    public let path: String?
    public var runs: Int? = nil

    public var isRunning: Bool {
        state?.lowercased() == "running" && pid != nil
    }
}

public enum LaunchctlParser {
    public static func parse(_ output: String) -> LaunchctlSnapshot {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                guard ["state", "pid", "last exit code", "program", "path", "runs"].contains(key) else {
                    continue
                }
                if values[key] == nil {
                    values[key] = value
                }
        }

        func intValue(for key: String) -> Int32? {
            guard let value = values[key] else { return nil }
            return Int32(value)
        }

        return LaunchctlSnapshot(
            state: values["state"],
            pid: intValue(for: "pid"),
            lastExitCode: intValue(for: "last exit code"),
            program: values["program"],
            path: values["path"],
            runs: values["runs"].flatMap { Int($0) }
        )
    }
}
