import Foundation
import XCTest
@testable import AgentScopeCore

final class ServiceInventoryTests: XCTestCase {
    func testCollectMergesItemsAndWarnings() async {
        let inventory = ServiceInventory(collectors: [
            FixedCollector(result: CollectorResult(items: [makeItem("b")], warnings: ["launch warning"])),
            FixedCollector(result: CollectorResult(items: [makeItem("a")], warnings: ["process warning"]))
        ])

        let result = await inventory.collect()

        XCTAssertEqual(result.items.map(\.id), ["a", "b"])
        XCTAssertEqual(result.warnings, ["launch warning", "process warning"])
    }

    func testCollectDeduplicatesByStableID() async {
        let inventory = ServiceInventory(collectors: [
            FixedCollector(result: CollectorResult(items: [makeItem("same", name: "first")], warnings: [])),
            FixedCollector(result: CollectorResult(items: [makeItem("same", name: "second")], warnings: []))
        ])

        let result = await inventory.collect()

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.name, "first")
    }

    private func makeItem(_ id: String, name: String? = nil) -> ServiceItem {
        ServiceItem(
            id: id,
            name: name ?? id,
            sourceType: .launchAgent,
            scope: .user
        )
    }
}

private struct FixedCollector: Collector {
    let result: CollectorResult

    func collect() async -> CollectorResult {
        result
    }
}
