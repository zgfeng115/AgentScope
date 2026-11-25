import Foundation

public enum LaunchAgentControllerError: Error, Equatable, Sendable {
    case unsupportedItem
    case missingConfiguration
    case backupFailed
    case commandFailed
    case postconditionFailed(expected: ServiceState, actual: ServiceState?)
    case serviceDisabled
}

extension LaunchAgentControllerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedItem: return "只能操作当前用户的 LaunchAgent。"
        case .missingConfiguration: return "找不到这个任务的配置文件。"
        case .backupFailed: return "备份配置文件失败，未执行操作。"
        case .commandFailed: return "launchctl 执行失败。"
        case .serviceDisabled: return "这个任务已停用，请先启用再启动。"
        case .postconditionFailed(let expected, _):
            return expected == .stopped
                ? "已发出停止指令，但任务仍在运行。"
                : "已执行操作，但任务状态没有变成预期的样子。"
        }
    }
}

public enum StopOutcome: Equatable, Sendable {
    /// The running process was signalled; the job stays loaded and keeps its schedule.
    case terminated
    /// The job was booted out of launchd (KeepAlive would respawn it); it returns at next login.
    case unloaded
}

public struct LaunchAgentController: Sendable {
    public let store: LocalStore

    private let commandRunner: any CommandExecuting
    private let collector: any Collector
    private let backupRoot: URL
    private let userID: UInt32
    private let bootoutSettleTime: TimeInterval = 5
    /// launchctl's "Could not find service" exit status.
    private static let serviceNotFound: Int32 = 113

    public init(
        commandRunner: any CommandExecuting,
        collector: any Collector,
        store: LocalStore,
        backupRoot: URL,
        userID: UInt32
    ) throws {
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        self.commandRunner = commandRunner
        self.collector = collector
        self.store = store
        self.backupRoot = backupRoot
        self.userID = userID
    }

    public func start(_ item: ServiceItem) async throws {
        try await perform(.start, item: item, arguments: ["kickstart", domain(for: item)], expected: .running)
    }

    /// `kill` alone cannot stop a KeepAlive job: launchd respawns it at once, so such jobs are booted out instead.
    @discardableResult
    public func stop(_ item: ServiceItem) async throws -> StopOutcome {
        try validate(item)
        if Self.hasKeepAlive(configurationPath: item.configurationPath) {
            try await bootOut(item)
            return .unloaded
        }

        do {
            _ = try await runLaunchctl(arguments: ["kill", "SIGTERM", domain(for: item)])
        } catch {
            recordBestEffort(OperationRecord(serviceID: item.id, action: .stop, succeeded: false, message: "launchctl command failed"))
            throw LaunchAgentControllerError.commandFailed
        }
        let actual = await refreshedItem(id: item.id)
        if postcondition(expected: .stopped, actual: actual) {
            try store.record(OperationRecord(serviceID: item.id, action: .stop, succeeded: true, message: "Completed"))
            return .terminated
        }
        // Running again under a new PID: something (Sockets, MachServices, KeepAlive dict) respawned it.
        if let actual, actual.state == .running, let before = item.pid, let after = actual.pid, before != after {
            try await bootOut(item)
            return .unloaded
        }
        recordBestEffort(OperationRecord(serviceID: item.id, action: .stop, succeeded: false, message: "Postcondition failed"))
        throw LaunchAgentControllerError.postconditionFailed(expected: .stopped, actual: actual?.state)
    }

    public func restart(_ item: ServiceItem) async throws {
        try await perform(.restart, item: item, arguments: ["kickstart", "-k", domain(for: item)], expected: .running)
    }

    static func hasKeepAlive(configurationPath: String?) -> Bool {
        guard let configurationPath,
              let data = FileManager.default.contents(atPath: configurationPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let keepAlive = plist["KeepAlive"] else {
            return false
        }
        if let flag = keepAlive as? Bool { return flag }
        return true
    }

    /// bootout may report "operation in progress" (36) or time out while the job winds down; judge by the result.
    private func bootOut(_ item: ServiceItem) async throws {
        _ = try? await runLaunchctl(arguments: ["bootout", domain(for: item)])
        var actual = await refreshedItem(id: item.id)
        let deadline = Date().addingTimeInterval(bootoutSettleTime)
        while !postcondition(expected: .stopped, actual: actual), Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            actual = await refreshedItem(id: item.id)
        }
        guard postcondition(expected: .stopped, actual: actual) else {
            recordBestEffort(OperationRecord(serviceID: item.id, action: .stop, succeeded: false, message: "Postcondition failed after bootout"))
            throw LaunchAgentControllerError.postconditionFailed(expected: .stopped, actual: actual?.state)
        }
        try store.record(OperationRecord(serviceID: item.id, action: .stop, succeeded: true, message: "Booted out"))
    }

    public func setEnabled(_ enabled: Bool, for item: ServiceItem) async throws {
        try validate(item)
        let backupPath = try makeBackup(for: item)
        let action: OperationAction = enabled ? .enable : .disable
        do {
            _ = try await runLaunchctl(arguments: [enabled ? "enable" : "disable", domain(for: item)])
        } catch {
            recordBestEffort(OperationRecord(
                serviceID: item.id,
                action: action,
                succeeded: false,
                message: "launchctl command failed",
                backupPath: backupPath.path
            ))
            throw LaunchAgentControllerError.commandFailed
        }

        let actual = await refreshedItem(id: item.id)
        let satisfied = enabled
            ? (actual?.disabled == false && actual?.state != .disabled)
            : (actual?.disabled == true || actual?.state == .disabled)
        guard satisfied else {
            recordBestEffort(OperationRecord(
                serviceID: item.id,
                action: action,
                succeeded: false,
                message: "Postcondition failed",
                backupPath: backupPath.path
            ))
            throw LaunchAgentControllerError.postconditionFailed(expected: enabled ? .enabled : .disabled, actual: actual?.state)
        }

        try store.record(OperationRecord(
            serviceID: item.id,
            action: action,
            succeeded: true,
            message: enabled ? "Enabled" : "Disabled",
            backupPath: backupPath.path
        ))
    }

    public func testRun(_ item: ServiceItem) async throws {
        try await perform(.testRun, item: item, arguments: ["kickstart", "-p", domain(for: item)], expected: .running)
    }

    private func perform(
        _ action: OperationAction,
        item: ServiceItem,
        arguments: [String],
        expected: ServiceState
    ) async throws {
        try validate(item)
        do {
            _ = try await runLaunchctl(arguments: arguments)
        } catch CommandRunnerError.nonZeroExit(let result) where result.exitCode == Self.serviceNotFound {
            // Not loaded (e.g. booted out by a previous stop): load it, then try once more.
            do {
                try await bootstrap(item)
                _ = try await runLaunchctl(arguments: arguments)
            } catch let error as LaunchAgentControllerError {
                recordBestEffort(OperationRecord(serviceID: item.id, action: action, succeeded: false, message: "\(error)"))
                throw error
            } catch {
                recordBestEffort(OperationRecord(serviceID: item.id, action: action, succeeded: false, message: "launchctl command failed"))
                throw LaunchAgentControllerError.commandFailed
            }
        } catch {
            recordBestEffort(OperationRecord(serviceID: item.id, action: action, succeeded: false, message: "launchctl command failed"))
            throw LaunchAgentControllerError.commandFailed
        }

        let actual = await refreshedItem(id: item.id)
        guard postcondition(expected: expected, actual: actual) else {
            recordBestEffort(OperationRecord(serviceID: item.id, action: action, succeeded: false, message: "Postcondition failed"))
            throw LaunchAgentControllerError.postconditionFailed(expected: expected, actual: actual?.state)
        }

        try store.record(OperationRecord(serviceID: item.id, action: action, succeeded: true, message: "Completed"))
    }

    private func bootstrap(_ item: ServiceItem) async throws {
        guard let configurationPath = item.configurationPath else {
            throw LaunchAgentControllerError.missingConfiguration
        }
        do {
            _ = try await runLaunchctl(arguments: ["bootstrap", "gui/\(userID)", configurationPath])
        } catch {
            if item.disabled || item.state == .disabled {
                throw LaunchAgentControllerError.serviceDisabled
            }
            throw error
        }
    }

    private func validate(_ item: ServiceItem) throws {
        guard item.scope == .user, item.sourceType == .launchAgent else {
            throw LaunchAgentControllerError.unsupportedItem
        }
        guard item.configurationPath != nil, item.label != nil || !item.name.isEmpty else {
            throw LaunchAgentControllerError.missingConfiguration
        }
    }

    private func runLaunchctl(arguments: [String]) async throws -> CommandResult {
        try await commandRunner.run(
            executable: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: arguments,
            timeout: 10,
            environment: nil
        )
    }

    private func refreshedItem(id: String) async -> ServiceItem? {
        let result = await collector.collect()
        return result.items.first { $0.id == id }
    }

    private func postcondition(expected: ServiceState, actual: ServiceItem?) -> Bool {
        guard let actual else { return false }
        switch expected {
        case .stopped:
            return actual.state != .running
        case .running:
            return actual.state == .running
        default:
            return actual.state == expected
        }
    }

    private func domain(for item: ServiceItem) -> String {
        "gui/\(userID)/\(item.label ?? item.name)"
    }

    private func makeBackup(for item: ServiceItem) throws -> URL {
        guard let configurationPath = item.configurationPath else {
            throw LaunchAgentControllerError.missingConfiguration
        }
        do {
            let directory = backupRoot.appending(path: item.id.replacingOccurrences(of: ":", with: "_"))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: URL(fileURLWithPath: configurationPath).lastPathComponent)
            let temporary = directory.appending(path: ".tmp-\(UUID().uuidString)")
            let data = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        } catch {
            throw LaunchAgentControllerError.backupFailed
        }
    }

    private func recordBestEffort(_ record: OperationRecord) {
        try? store.record(record)
    }
}
