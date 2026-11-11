import Foundation
import XCTest
@testable import AgentScopeCore

final class ProcessCollectorTests: XCTestCase {
    func testCollectorHidesSelfAndSystemProcessesByDefault() async throws {
        let launchDate = Date(timeIntervalSince1970: 500)
        let records = [
            ProcessRecord(
                pid: 100,
                parentPID: 1,
                userID: 501,
                name: "AgentScope",
                executablePath: "/Applications/AgentScope.app/Contents/MacOS/AgentScope",
                launchDate: launchDate,
                isSystemProcess: false
            ),
            ProcessRecord(
                pid: 1,
                parentPID: 0,
                userID: 0,
                name: "launchd",
                executablePath: "/sbin/launchd",
                launchDate: launchDate,
                isSystemProcess: true
            ),
            ProcessRecord(
                pid: 101,
                parentPID: 100,
                userID: 501,
                name: "python3",
                executablePath: "/Users/test/project/agent.py",
                launchDate: launchDate,
                isSystemProcess: false
            )
        ]

        let result = await ProcessCollector(
            provider: FixedProcessProvider(records: records),
            persistentItems: [],
            currentUserID: 501,
            processIdentifier: 100
        ).collect()

        XCTAssertEqual(result.items.map(\.pid), [101])
        XCTAssertEqual(result.items.first?.state, .running)
        XCTAssertEqual(result.items.first?.lastRunPrecision, .exact)
    }

    func testCollectorCanExposeSystemProcessesAsReadOnly() async throws {
        let records = [
            ProcessRecord(
                pid: 1,
                parentPID: 0,
                userID: 0,
                name: "launchd",
                executablePath: "/sbin/launchd",
                launchDate: nil,
                isSystemProcess: true
            )
        ]

        let result = await ProcessCollector(
            provider: FixedProcessProvider(records: records),
            persistentItems: [],
            currentUserID: 501,
            processIdentifier: 100,
            includeSystemProcesses: true
        ).collect()

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.scope, .system)
        XCTAssertEqual(item.state, .systemReadonly)
        XCTAssertEqual(item.pid, 1)
    }

    func testCollectorDoesNotDuplicateProcessMatchedToPersistentService() async {
        let persistentItem = ServiceItem(
            id: "launchagent:user:com.example.agent",
            name: "com.example.agent",
            sourceType: .launchAgent,
            scope: .user,
            label: "com.example.agent",
            programPath: "/Users/test/project/agent.py"
        )
        let record = ProcessRecord(
            pid: 101,
            parentPID: 1,
            userID: 501,
            name: "python3",
            executablePath: "/Users/test/project/agent.py",
            launchDate: Date(),
            isSystemProcess: false
        )

        let result = await ProcessCollector(
            provider: FixedProcessProvider(records: [record]),
            persistentItems: [persistentItem],
            currentUserID: 501,
            processIdentifier: 100
        ).collect()

        XCTAssertTrue(result.items.isEmpty)
    }

    func testCollectorMarksUnmanagedProcessWithEvidence() async throws {
        let record = ProcessRecord(
            pid: 101,
            parentPID: 1,
            userID: 501,
            name: "python3",
            executablePath: "/Users/test/project/agent.py",
            launchDate: Date(timeIntervalSince1970: 1000),
            isSystemProcess: false
        )

        let result = await ProcessCollector(
            provider: FixedProcessProvider(records: [record]),
            persistentItems: [],
            currentUserID: 501,
            processIdentifier: 100
        ).collect()

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.sourceType, .process)
        XCTAssertEqual(item.id, "process:101")
        XCTAssertTrue(item.evidence.contains { $0.title == "No persistent launch source found" })
    }
}

private struct FixedProcessProvider: ProcessRecordProviding {
    let records: [ProcessRecord]

    func records() async -> [ProcessRecord] {
        records
    }
}
