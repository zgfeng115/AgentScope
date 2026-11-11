import Foundation
import XCTest
@testable import AgentScopeCore

final class LaunchAgentCollectorTests: XCTestCase {
    func testDefaultLaunchdSourcesStartWithUserLaunchAgents() {
        let sources = LaunchdSource.defaultSources()

        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources.first?.scope, .user)
        XCTAssertEqual(sources.first?.domain, .gui)
        XCTAssertEqual(
            sources.first?.directoryURL.path,
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents").path
        )
    }

    func testCollectorNormalizesValidPlistAndMergesLaunchctlState() async throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/launchagents")
        let runner = FakeCommandRunner(stdout: "state = running\npid = 88\nlast exit code = 0\n")
        let collector = LaunchAgentCollector(directoryURL: directory, commandRunner: runner, inspectSignatures: false)

        let result = await collector.collect()
        let item = try XCTUnwrap(result.items.first(where: { $0.name == "com.example.valid" }))

        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(item.id, "launchagent:user:com.example.valid")
        XCTAssertEqual(item.sourceType, .launchAgent)
        XCTAssertEqual(item.scope, .user)
        XCTAssertEqual(item.programPath, "/usr/bin/true")
        XCTAssertEqual(item.arguments, ["--fixture"])
        XCTAssertEqual(item.state, .running)
        XCTAssertEqual(item.pid, 88)
        XCTAssertEqual(item.lastExitCode, 0)
        XCTAssertEqual(item.validity, .healthy)
    }

    func testCollectorMarksMissingTargetAndReportsMalformedPlistWarning() async throws {
        let directory = try makeTemporaryLaunchAgentsDirectory()
        try "not a plist".write(
            to: directory.appending(path: "broken.plist"),
            atomically: true,
            encoding: .utf8
        )
        try writePlist(
            [
                "Label": "com.example.missing",
                "Program": "/tmp/agentscope-missing-target",
                "ProgramArguments": ["/tmp/agentscope-missing-target"]
            ],
            to: directory.appending(path: "com.example.missing.plist")
        )

        let collector = LaunchAgentCollector(
            directoryURL: directory,
            commandRunner: FakeCommandRunner(stdout: "state = stopped\n"),
            inspectSignatures: false
        )

        let result = await collector.collect()
        let item = try XCTUnwrap(result.items.first(where: { $0.name == "com.example.missing" }))

        XCTAssertEqual(item.validity, .missingTarget)
        XCTAssertEqual(item.state, .stopped)
        XCTAssertTrue(result.warnings.contains { $0.contains("broken.plist") })
    }

    func testCollectorSkipsNonPlistFiles() async throws {
        let directory = try makeTemporaryLaunchAgentsDirectory()
        try "ignored".write(
            to: directory.appending(path: "README.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = await LaunchAgentCollector(
            directoryURL: directory,
            commandRunner: FakeCommandRunner(stdout: ""),
            inspectSignatures: false
        ).collect()

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testLaunchdCollectorScansMultipleScopesAndDomains() async throws {
        let userDirectory = try makeTemporaryLaunchAgentsDirectory()
        let daemonDirectory = try makeTemporaryLaunchAgentsDirectory()
        try writePlist(
            ["Label": "com.example.user", "ProgramArguments": ["/usr/bin/true"]],
            to: userDirectory.appending(path: "user.plist")
        )
        try writePlist(
            ["Label": "com.example.daemon", "ProgramArguments": ["/usr/bin/true"]],
            to: daemonDirectory.appending(path: "daemon.plist")
        )

        let collector = LaunchdCollector(
            sources: [
                LaunchdSource(directoryURL: userDirectory, scope: .user, domain: .gui),
                LaunchdSource(directoryURL: daemonDirectory, scope: .system, domain: .system)
            ],
            commandRunner: FakeCommandRunner(stdout: "state = running\npid = 42\n"),
            inspectSignatures: false,
            userID: 501
        )

        let result = await collector.collect()

        XCTAssertEqual(result.items.map(\.id), [
            "launchagent:user:com.example.user",
            "launchdaemon:system:com.example.daemon"
        ])
        XCTAssertEqual(result.items.map(\.scope), [.user, .system])
        XCTAssertTrue(result.items.allSatisfy { $0.state == .running })
    }

    private func makeTemporaryLaunchAgentsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AgentScopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writePlist(_ object: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try data.write(to: url)
    }
}

private struct FakeCommandRunner: CommandExecuting {
    let stdout: String

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async throws -> CommandResult {
        CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false, duration: 0)
    }
}
