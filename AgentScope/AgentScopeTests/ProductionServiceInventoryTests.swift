import Foundation
import XCTest
@testable import AgentScopeCore

final class ProductionServiceInventoryTests: XCTestCase {
    func testProductionInventoryKeepsAuditSourcesWithoutLoadingUnmanagedProcesses() async {
        let launchAgent = ServiceItem(
            id: "launchagent:user:worker",
            name: "Worker",
            sourceType: .launchAgent,
            scope: .user,
            label: "worker",
            programPath: "/Users/test/worker.py"
        )
        let matchingProcess = ProcessRecord(
            pid: 10,
            parentPID: 1,
            userID: 501,
            name: "python3",
            executablePath: "/Users/test/worker.py",
            launchDate: Date(),
            isSystemProcess: false
        )
        let unmanagedProcess = ProcessRecord(
            pid: 11,
            parentPID: 1,
            userID: 501,
            name: "node",
            executablePath: "/Users/test/server.js",
            launchDate: Date(),
            isSystemProcess: false
        )
        let inventory = ProductionServiceInventory(
            launchAgentCollector: FixedCollectorForProduction(
                result: CollectorResult(items: [launchAgent], warnings: ["launch warning"])
            ),
            processProvider: FixedProcessProviderForProduction(records: [matchingProcess, unmanagedProcess]),
            currentUserID: 501,
            processIdentifier: 999
        )

        let result = await inventory.collect()

        XCTAssertEqual(result.items.map(\.id), ["launchagent:user:worker"])
        XCTAssertEqual(result.warnings, ["launch warning"])
    }

    func testProductionInventoryAggregatesMultipleAuditSourcesAndAddsAssessment() async {
        let launchAgent = ServiceItem(
            id: "launchagent:user:worker",
            name: "Worker",
            sourceType: .launchAgent,
            scope: .user,
            validity: .healthy
        )
        let scheduledTask = ServiceItem(
            id: "cron:user:daily",
            name: "daily",
            sourceType: .cron,
            scope: .user,
            state: .enabled
        )
        let inventory = ProductionServiceInventory(collectors: [
            FixedCollectorForProduction(result: CollectorResult(items: [launchAgent], warnings: [])),
            FixedCollectorForProduction(result: CollectorResult(items: [scheduledTask], warnings: ["cron warning"]))
        ])

        let result = await inventory.collect()

        XCTAssertEqual(result.items.map(\.id), ["cron:user:daily", "launchagent:user:worker"])
        XCTAssertEqual(result.warnings, ["cron warning"])
        XCTAssertEqual(result.items.first(where: { $0.id == "launchagent:user:worker" })?.assessment?.status, .retain)
        XCTAssertNotNil(result.items.first(where: { $0.id == "cron:user:daily" })?.assessment)
    }

    func testProductionInventoryKeepsLoginItemsDistinctFromLaunchAgentsWithoutWarning() async {
        let loginItem = LoginItemCollector(
            reader: FixedLoginItemReader(records: [
                LoginItemRecord(name: "Example", path: "/Applications/Example.app")
            ])
        )
        let launchAgent = ServiceItem(
            id: "launchagent:user:example",
            name: "Example",
            sourceType: .launchAgent,
            scope: .user,
            configurationPath: "/Users/test/Library/LaunchAgents/example.plist"
        )
        let inventory = ProductionServiceInventory(collectors: [
            loginItem,
            FixedCollectorForProduction(result: CollectorResult(items: [launchAgent], warnings: []))
        ])

        let result = await inventory.collect()

        XCTAssertFalse(result.warnings.contains { $0.hasPrefix("Login Items unavailable:") })
        XCTAssertEqual(result.items.map(\.id), [
            "launchagent:user:example",
            "loginitem:user:/Applications/Example.app"
        ])
        XCTAssertEqual(result.items.map(\.sourceType), [.launchAgent, .loginItem])
    }

    func testProductionInventoryIncludesEmbeddedLoginItemRecords() async {
        let embeddedLoginItem = ServiceItem(
            id: "embeddedLoginItem:/Applications/Host.app:/Applications/Host.app/Contents/Library/LoginItems/Helper.app",
            name: "Helper",
            sourceType: .embeddedLoginItem,
            scope: .user
        )
        let inventory = ProductionServiceInventory(collectors: [
            FixedCollectorForProduction(result: CollectorResult(items: [embeddedLoginItem], warnings: []))
        ])

        let result = await inventory.collect()

        XCTAssertEqual(result.items.map(\.id), [embeddedLoginItem.id])
        XCTAssertEqual(result.items.map(\.sourceType), [.embeddedLoginItem])
    }
}

private struct FixedCollectorForProduction: Collector {
    let result: CollectorResult

    func collect() async -> CollectorResult {
        result
    }
}

private struct FixedLoginItemReader: LoginItemReading {
    let records: [LoginItemRecord]

    func read() throws -> [LoginItemRecord] {
        records
    }
}

private struct FixedProcessProviderForProduction: ProcessRecordProviding {
    let records: [ProcessRecord]

    func records() async -> [ProcessRecord] {
        records
    }
}
