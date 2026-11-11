import Foundation
import XCTest
@testable import AgentScopeCore

final class AuditAnalysisTests: XCTestCase {
    func testAttributorFindsGitProjectForExecutable() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AgentScopeRepo-\(UUID().uuidString)")
        let bin = root.appending(path: "scripts/worker")
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin, atomically: true, encoding: .utf8)

        let item = ServiceItem(
            id: "cron:user:worker",
            name: "worker",
            sourceType: .cron,
            scope: .user,
            programPath: bin.path
        )
        let project = try XCTUnwrap(ProjectAttributor().project(for: item))

        XCTAssertEqual(project.kind, .gitRepository)
        XCTAssertEqual(project.rootPath, root.path)
        XCTAssertEqual(project.displayName, root.lastPathComponent)
    }

    func testReviewEngineClassifiesInvalidTargetAsInvalid() {
        let item = ServiceItem(
            id: "launchagent:user:missing",
            name: "missing",
            sourceType: .launchAgent,
            scope: .user,
            validity: .missingTarget
        )

        let assessment = ServiceReviewEngine().assess(item)
        XCTAssertEqual(assessment.status, .invalid)
    }

    func testReviewEngineUsesExecutionFailuresAsAbnormal() {
        let item = ServiceItem(
            id: "cron:user:failed",
            name: "failed",
            sourceType: .cron,
            scope: .user,
            validity: .healthy,
            executionEvidence: ExecutionEvidence(
                lastExecutionAt: nil,
                precision: .unknown,
                lastExitCode: 1,
                consecutiveFailures: 3,
                source: "crontab"
            )
        )

        let assessment = ServiceReviewEngine().assess(item)
        XCTAssertEqual(assessment.status, .abnormal)
        XCTAssertTrue(assessment.evidence.contains { $0.contains("连续失败") })
    }

    func testReviewEngineDoesNotTreatStoppedAsInvalidByItself() {
        let item = ServiceItem(
            id: "launchagent:user:stopped",
            name: "stopped",
            sourceType: .launchAgent,
            scope: .user,
            state: .stopped,
            validity: .healthy
        )

        XCTAssertEqual(ServiceReviewEngine().assess(item).status, .retain)
    }
}
