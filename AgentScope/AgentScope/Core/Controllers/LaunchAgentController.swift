import Foundation

public enum LaunchAgentControllerError: Error, Equatable, Sendable {
    case unsupportedItem
    case missingConfiguration
    case backupFailed
    case commandFailed
    case postconditionFailed(expected: ServiceState, actual: ServiceState?)
}

public struct LaunchAgentController: Sendable {
    public let store: LocalStore

    private let commandRunner: any CommandExecuting
    private let collector: any Collector
    private let backupRoot: URL
    private let userID: UInt32

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

    public func stop(_ item: ServiceItem) async throws {
        try await perform(.stop, item: item, arguments: ["kill", "SIGTERM", domain(for: item)], expected: .stopped)
    }

    public func restart(_ item: ServiceItem) async throws {
        try await perform(.restart, item: item, arguments: ["kickstart", "-k", domain(for: item)], expected: .running)
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
