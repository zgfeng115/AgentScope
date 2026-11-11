import Foundation
import XCTest
@testable import AgentScopeCore

final class LaunchAgentControllerTests: XCTestCase {
    func testControllerRejectsSystemItemBeforeRunningCommand() async throws {
        let runner = RecordingCommandRunner()
        let controller = try makeController(runner: runner, collector: SequenceCollector(results: []))
        let item = makeItem(scope: .system)

        do {
            try await controller.start(item)
            XCTFail("Expected a system-scope rejection")
        } catch let error as LaunchAgentControllerError {
            XCTAssertEqual(error, .unsupportedItem)
        }

        let calls = await runner.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func testControllerStartsUserLaunchAgentAndRecordsOperation() async throws {
        let runner = RecordingCommandRunner()
        let runningItem = makeItem(state: .running)
        let storeURL = try makeTemporaryDirectory()
        let controller = try makeController(
            runner: runner,
            collector: SequenceCollector(results: [CollectorResult(items: [runningItem], warnings: [])]),
            storeURL: storeURL
        )

        try await controller.start(makeItem())

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.arguments, ["kickstart", "gui/501/com.example.agent"])
        let records = try controller.store.fetchOperationRecords(serviceID: runningItem.id)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.action, .start)
        XCTAssertTrue(records.first?.succeeded == true)
    }

    func testControllerCreatesBackupBeforeDisableCommand() async throws {
        let configurationURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "com.example.agent-\(UUID().uuidString).plist")
        try Data("fixture".utf8).write(to: configurationURL)
        defer { try? FileManager.default.removeItem(at: configurationURL) }

        let backupRoot = try makeTemporaryDirectory()
        let expectedBackup = backupRoot
            .appending(path: "launchagent_user_com.example.agent")
            .appending(path: configurationURL.lastPathComponent)
        let runner = BackupCheckingCommandRunner(expectedBackup: expectedBackup)
        let item = makeItem(configurationPath: configurationURL.path)
        let controller = try makeController(
            runner: runner,
            collector: SequenceCollector(results: [CollectorResult(items: [makeItem(state: .disabled, disabled: true)], warnings: [])]),
            backupRoot: backupRoot
        )

        try await controller.setEnabled(false, for: item)

        let sawBackup = await runner.sawBackup()
        XCTAssertTrue(sawBackup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedBackup.path))
    }

    func testControllerReportsPostconditionFailure() async throws {
        let runner = RecordingCommandRunner()
        let controller = try makeController(
            runner: runner,
            collector: SequenceCollector(results: [CollectorResult(items: [makeItem(state: .stopped)], warnings: [])])
        )

        do {
            try await controller.start(makeItem())
            XCTFail("Expected a postcondition failure")
        } catch let error as LaunchAgentControllerError {
            guard case .postconditionFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeController(
        runner: any CommandExecuting,
        collector: any Collector,
        storeURL: URL? = nil,
        backupRoot: URL? = nil
    ) throws -> LaunchAgentController {
        try LaunchAgentController(
            commandRunner: runner,
            collector: collector,
            store: LocalStore(directoryURL: storeURL ?? makeTemporaryDirectory()),
            backupRoot: backupRoot ?? makeTemporaryDirectory(),
            userID: 501
        )
    }

    private func makeItem(
        scope: Scope = .user,
        state: ServiceState = .stopped,
        disabled: Bool = false,
        configurationPath: String? = "/tmp/com.example.agent.plist"
    ) -> ServiceItem {
        ServiceItem(
            id: "launchagent:user:com.example.agent",
            name: "com.example.agent",
            sourceType: .launchAgent,
            scope: scope,
            label: "com.example.agent",
            configurationPath: configurationPath,
            programPath: "/usr/bin/true",
            state: state,
            disabled: disabled,
            validity: .healthy
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "AgentScopeController-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor RecordingCommandRunner: CommandExecuting {
    private var calls: [(executable: URL, arguments: [String])] = []

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async throws -> CommandResult {
        calls.append((executable, arguments))
        return CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false, duration: 0)
    }

    func recordedCalls() -> [(executable: URL, arguments: [String])] {
        calls
    }
}

private actor BackupCheckingCommandRunner: CommandExecuting {
    private let expectedBackup: URL
    private var sawBackupBeforeCommand = false

    init(expectedBackup: URL) {
        self.expectedBackup = expectedBackup
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async throws -> CommandResult {
        sawBackupBeforeCommand = FileManager.default.fileExists(atPath: expectedBackup.path)
        return CommandResult(stdout: "", stderr: "", exitCode: 0, timedOut: false, duration: 0)
    }

    func sawBackup() -> Bool {
        sawBackupBeforeCommand
    }
}

private actor SequenceCollector: Collector {
    private var results: [CollectorResult]

    init(results: [CollectorResult]) {
        self.results = results
    }

    func collect() async -> CollectorResult {
        results.isEmpty
            ? CollectorResult(items: [], warnings: [])
            : results.removeFirst()
    }
}
