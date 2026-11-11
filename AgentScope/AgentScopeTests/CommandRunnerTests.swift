import XCTest
@testable import AgentScopeCore

final class CommandRunnerTests: XCTestCase {
    func testParserReadsKnownLaunchctlAnchorsAndIgnoresUnknownLines() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/launchctl/print-running.txt")
        let output = try String(contentsOf: fixtureURL, encoding: .utf8)

        let snapshot = LaunchctlParser.parse(output)

        XCTAssertEqual(snapshot.state, "running")
        XCTAssertEqual(snapshot.pid, 4242)
        XCTAssertEqual(snapshot.lastExitCode, 0)
        XCTAssertEqual(snapshot.program, "/usr/bin/python3")
        XCTAssertEqual(snapshot.path, "/Users/test/Library/LaunchAgents/com.example.agent.plist")
        XCTAssertTrue(snapshot.isRunning)
    }

    func testParserAllowsMissingOptionalAnchorsAndDoesNotInferRunningWithoutPID() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/launchctl/print-no-pid.txt")
        let output = try String(contentsOf: fixtureURL, encoding: .utf8)

        let snapshot = LaunchctlParser.parse(output)

        XCTAssertEqual(snapshot.state, "running")
        XCTAssertNil(snapshot.pid)
        XCTAssertNil(snapshot.lastExitCode)
        XCTAssertFalse(snapshot.isRunning)
    }

    func testParserReadsStoppedJobWithoutInventingPID() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/launchctl/print-stopped.txt")
        let output = try String(contentsOf: fixtureURL, encoding: .utf8)

        let snapshot = LaunchctlParser.parse(output)

        XCTAssertEqual(snapshot.state, "stopped")
        XCTAssertNil(snapshot.pid)
        XCTAssertEqual(snapshot.lastExitCode, 1)
        XCTAssertFalse(snapshot.isRunning)
    }

    func testParserKeepsTopLevelStateWhenLaunchctlOutputContainsNestedStates() {
        let output = """
        state = running
        pid = 4242
        resource coalition = {
            state = active
        }
        jetsam coalition = {
            state = active
        }
        """

        let snapshot = LaunchctlParser.parse(output)

        XCTAssertEqual(snapshot.state, "running")
        XCTAssertTrue(snapshot.isRunning)
    }

    func testCommandRunnerReturnsStdoutAndArgumentsWithoutUsingShell() async throws {
        let result = try await CommandRunner().run(
            executable: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", "hello AgentScope"],
            timeout: 1
        )

        XCTAssertEqual(result.stdout, "hello AgentScope")
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
    }

    func testCommandRunnerDrainsLargeStdoutBeforeWaitingForExit() async throws {
        let result = try await CommandRunner().run(
            executable: URL(fileURLWithPath: "/bin/dd"),
            arguments: ["if=/dev/zero", "bs=1m", "count=1"],
            timeout: 2
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.timedOut)
        XCTAssertGreaterThanOrEqual(result.stdout.utf8.count, 1_000_000)
    }

    func testCommandRunnerThrowsTypedNonZeroExit() async {
        do {
            _ = try await CommandRunner().run(
                executable: URL(fileURLWithPath: "/usr/bin/false"),
                timeout: 1
            )
            XCTFail("Expected a non-zero exit error")
        } catch let error as CommandRunnerError {
            guard case .nonZeroExit(let result) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertFalse(result.timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommandRunnerThrowsTypedExecutableNotFound() async {
        do {
            _ = try await CommandRunner().run(
                executable: URL(fileURLWithPath: "/tmp/agentscope-does-not-exist"),
                timeout: 1
            )
            XCTFail("Expected an executable-not-found error")
        } catch let error as CommandRunnerError {
            XCTAssertEqual(error, .executableNotFound(path: "/tmp/agentscope-does-not-exist"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCommandRunnerThrowsTypedTimeoutAndTerminatesChild() async {
        do {
            _ = try await CommandRunner().run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["2"],
                timeout: 0.05
            )
            XCTFail("Expected a timeout error")
        } catch let error as CommandRunnerError {
            guard case .timedOut(let result) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(result.timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
