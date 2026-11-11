import Foundation
import XCTest
@testable import AgentScopeCore

final class ValidityCheckerTests: XCTestCase {
    func testCheckerAcceptsExistingExecutableAndReadableConfiguration() throws {
        let configuration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/launchagents/com.example.valid.plist")

        let status = ValidityChecker().check(
            configurationURL: configuration,
            programPath: "/usr/bin/true",
            arguments: []
        )

        XCTAssertEqual(status, .healthy)
    }

    func testCheckerReportsMissingTarget() throws {
        let configuration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/launchagents/com.example.missing-target.plist")

        let status = ValidityChecker().check(
            configurationURL: configuration,
            programPath: "/tmp/agentscope-missing-target",
            arguments: []
        )

        XCTAssertEqual(status, .missingTarget)
    }

    func testCheckerReportsMissingInterpreterForEnvLaunch() throws {
        let configuration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/launchagents/com.example.valid.plist")

        let status = ValidityChecker().check(
            configurationURL: configuration,
            programPath: "/usr/bin/env",
            arguments: ["agentscope-interpreter-does-not-exist"]
        )

        XCTAssertEqual(status, .missingInterpreter)
    }
}
