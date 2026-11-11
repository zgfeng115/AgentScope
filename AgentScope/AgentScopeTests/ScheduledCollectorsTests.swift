import Foundation
import XCTest
@testable import AgentScopeCore

final class ScheduledCollectorsTests: XCTestCase {
    func testCronCollectorParsesEntriesAndKeepsCommandAsAuditEvidence() async throws {
        let collector = CronCollector(
            sourceText: "# comment\n22 17 * * * \"/Users/test/.acme.sh/acme.sh\" --cron\n@reboot /usr/bin/true\n"
        )

        let result = await collector.collect()

        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.items.count, 2)
        let cron = try XCTUnwrap(result.items.first(where: { $0.programPath?.contains("acme.sh") == true }))
        XCTAssertEqual(cron.sourceType, .cron)
        XCTAssertEqual(cron.scope, .user)
        XCTAssertEqual(cron.triggers?.first?.kind, .cron)
        XCTAssertEqual(cron.triggers?.first?.expression, "22 17 * * *")
        XCTAssertTrue(cron.executionEvidence?.source == "crontab")
    }

    func testPeriodicCollectorScansExecutableTasksWithoutTreatingMissingOptionalDirectoriesAsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "AgentScopePeriodic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let task = directory.appending(path: "cleanup")
        try "#!/bin/sh\nexit 0\n".write(to: task, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: task.path)

        let collector = PeriodicCollector(directories: [directory, directory.appending(path: "missing")])
        let result = await collector.collect()

        XCTAssertEqual(result.items.map(\.sourceType), [.periodic])
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.items.first?.triggers?.first?.kind, .periodic)
    }

    func testShellStartupCollectorOnlyKeepsStartupLikeCommands() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "AgentScopeShell-\(UUID().uuidString)")
        try "export PATH=\"$PATH:/opt/bin\"\nnohup /usr/bin/true >/tmp/true.log 2>&1 &\n".write(
            to: file,
            atomically: true,
            encoding: .utf8
        )

        let result = await ShellStartupCollector(files: [file]).collect()

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.sourceType, .shellStartup)
        XCTAssertEqual(result.items.first?.programPath, "/usr/bin/true")
        XCTAssertEqual(result.items.first?.triggers?.first?.kind, .shellStartup)
    }

    func testShellStartupCollectorSkipsShellTestExpressions() async throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "AgentScopeShellTest-\(UUID().uuidString)")
        try "[ -x /usr/bin/true ] && /usr/bin/true &\n".write(
            to: file,
            atomically: true,
            encoding: .utf8
        )

        let result = await ShellStartupCollector(files: [file]).collect()

        XCTAssertTrue(result.items.isEmpty)
    }
}
