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

    func testStopBootsOutKeepAliveJobInsteadOfKilling() async throws {
        let plist = try writePlist(["Label": "com.example.agent", "KeepAlive": true])
        defer { try? FileManager.default.removeItem(at: plist) }
        let runner = RecordingCommandRunner()
        let controller = try makeController(
            runner: runner,
            collector: SequenceCollector(results: [CollectorResult(items: [makeItem(state: .stopped)], warnings: [])])
        )

        let outcome = try await controller.stop(makeItem(state: .running, configurationPath: plist.path))

        XCTAssertEqual(outcome, .unloaded)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.map(\.arguments), [["bootout", "gui/501/com.example.agent"]])
    }

    func testStopKillsJobWithoutKeepAlive() async throws {
        let plist = try writePlist(["Label": "com.example.agent", "StartInterval": 60])
        defer { try? FileManager.default.removeItem(at: plist) }
        let runner = RecordingCommandRunner()
        let controller = try makeController(
            runner: runner,
            collector: SequenceCollector(results: [CollectorResult(items: [makeItem(state: .stopped)], warnings: [])])
        )

        let outcome = try await controller.stop(makeItem(state: .running, configurationPath: plist.path))

        XCTAssertEqual(outcome, .terminated)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.map(\.arguments), [["kill", "SIGTERM", "gui/501/com.example.agent"]])
    }

    func testStopFallsBackToBootoutWhenJobRespawnsUnderNewPID() async throws {
        var running = makeItem(state: .running)
        running.pid = 200
        var respawned = makeItem(state: .running)
        respawned.pid = 201
        let runner = RecordingCommandRunner()
        let controller = try makeController(
            runner: runner,
            collector: SequenceCollector(results: [
                CollectorResult(items: [respawned], warnings: []),
                CollectorResult(items: [makeItem(state: .stopped)], warnings: [])
            ])
        )

        let outcome = try await controller.stop(running)

        XCTAssertEqual(outcome, .unloaded)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.map(\.arguments).last, ["bootout", "gui/501/com.example.agent"])
    }

    func testStartBootstrapsJobThatIsNotLoaded() async throws {
        let runner = RecordingCommandRunner(failFirst: "kickstart")
        let controller = try makeController(
            runner: runner,
            collector: SequenceCollector(results: [CollectorResult(items: [makeItem(state: .running)], warnings: [])])
        )

        try await controller.start(makeItem())

        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.map(\.arguments), [
            ["kickstart", "gui/501/com.example.agent"],
            ["bootstrap", "gui/501", "/tmp/com.example.agent.plist"],
            ["kickstart", "gui/501/com.example.agent"]
        ])
    }

    func testKeepAliveDetectionAcceptsDictionaryAndRejectsFalse() throws {
        let dictionary = try writePlist(["KeepAlive": ["SuccessfulExit": false]])
        let off = try writePlist(["KeepAlive": false])
        defer {
            try? FileManager.default.removeItem(at: dictionary)
            try? FileManager.default.removeItem(at: off)
        }
        XCTAssertTrue(LaunchAgentController.hasKeepAlive(configurationPath: dictionary.path))
        XCTAssertFalse(LaunchAgentController.hasKeepAlive(configurationPath: off.path))
        XCTAssertFalse(LaunchAgentController.hasKeepAlive(configurationPath: "/tmp/agentscope-missing.plist"))
    }

    private func writePlist(_ plist: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "agent-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
        return url
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
    private var failFirst: String?

    init(failFirst: String? = nil) {
        self.failFirst = failFirst
    }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async throws -> CommandResult {
        calls.append((executable, arguments))
        if let failFirst, arguments.first == failFirst {
            self.failFirst = nil
            throw CommandRunnerError.nonZeroExit(
                CommandResult(stdout: "", stderr: "", exitCode: 113, timedOut: false, duration: 0)
            )
        }
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
