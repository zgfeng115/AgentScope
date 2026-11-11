import Foundation
import XCTest
@testable import AgentScopeCore

final class BackgroundTaskScanTests: XCTestCase {
    private let sample = """
    ========================
     Records for UID 501 : 7D1E7E4B-0000-0000-0000-000000000000
    ========================

     ServiceManagement migrated: true
     SharedFileList migrated: true

     Items:

     #1:
                     UUID: AAAA
                     Name: Docker Inc
                     Type: developer (0x20)
          Disposition: [enabled, allowed, visible, notified] (0xb)
           Identifier: Docker Inc

     #2:
                     UUID: BBBB
                     Name: com.docker.helper
       Developer Name: Docker Inc
      Team Identifier: 9BNSXJN65R
                     Type: agent (0x8)
                    Flags: [  ] (0)
          Disposition: [enabled, allowed, visible, notified] (0xb)
           Identifier: 8.com.docker.helper
                  URL: file:///Library/LaunchAgents/com.docker.helper.plist
      Executable Path: /Applications/Docker.app/Contents/MacOS/com.docker.helper

     #3:
                     UUID: CCCC
                     Name: Raycast
       Developer Name: Raycast Technologies Inc
      Team Identifier: SY64MV22J9
                     Type: login item (0x4)
          Disposition: [disabled, allowed, visible, notified] (0xa)
           Identifier: 4.com.raycast.macos
                  URL: file:///Applications/Raycast.app/
    Bundle Identifier: com.raycast.macos

     #4:
                     Name: Spotlight helper
                     Type: agent (0x8)
          Disposition: [enabled, allowed] (0x3)
           Identifier: 8.com.apple.spotlight.helper
      Executable Path: /System/Library/CoreServices/helper
    """

    func testParserKeepsStartupRecordsAndReadsDisposition() {
        let records = BackgroundTaskParser.parse(sample)

        XCTAssertEqual(records.map(\.type), ["agent", "login item", "agent"])
        XCTAssertEqual(records[0].plainIdentifier, "com.docker.helper")
        XCTAssertEqual(records[0].teamID, "9BNSXJN65R")
        XCTAssertTrue(records[0].enabled && records[0].allowed)
        XCTAssertEqual(records[1].path, "/Applications/Raycast.app")
        XCTAssertFalse(records[1].enabled)
        XCTAssertEqual(records[1].bundleIdentifier, "com.raycast.macos")
    }

    func testMergeAnnotatesKnownItemsAddsNewOnesAndSkipsApple() {
        let existing = ServiceItem(
            id: "launchagent:global:com.docker.helper", name: "com.docker.helper", sourceType: .launchAgent,
            scope: .global, label: "com.docker.helper"
        )

        let merged = BackgroundTaskMerger.merge(BackgroundTaskParser.parse(sample), into: [existing])

        XCTAssertEqual(merged.map(\.id), ["launchagent:global:com.docker.helper", "btm:com.raycast.macos"])
        XCTAssertEqual(merged[0].evidence.first?.detail, "已允许在后台运行")
        XCTAssertEqual(merged[1].sourceType, .backgroundTask)
        XCTAssertEqual(merged[1].state, .disabled)
        XCTAssertEqual(merged[1].signing?.organization, "Raycast Technologies Inc")
    }

    func testMergePrefersIdentifierOverSharedInterpreterPath() {
        let first = ServiceItem(
            id: "launchagent:user:a.tunnel", name: "a.tunnel", sourceType: .launchAgent,
            scope: .user, label: "a.tunnel", programPath: "/usr/bin/ssh"
        )
        let second = ServiceItem(
            id: "launchagent:user:b.tunnel", name: "b.tunnel", sourceType: .launchAgent,
            scope: .user, label: "b.tunnel", programPath: "/usr/bin/ssh"
        )
        let records = [
            BackgroundTaskRecord(type: "legacy agent", identifier: "8.b.tunnel", executablePath: "/usr/bin/ssh", enabled: true, allowed: true),
            BackgroundTaskRecord(type: "legacy agent", identifier: "8.c.tunnel", executablePath: "/usr/bin/ssh", enabled: true, allowed: true)
        ]

        let merged = BackgroundTaskMerger.merge(records, into: [first, second])

        XCTAssertTrue(merged[0].evidence.isEmpty)
        XCTAssertEqual(merged[1].evidence.count, 1)
        XCTAssertEqual(merged.map(\.id).last, "btm:c.tunnel")
    }

    func testMergeMarksItemsSwitchedOffInSystemSettingsAsDisabled() {
        func item(_ label: String, _ state: ServiceState) -> ServiceItem {
            ServiceItem(id: label, name: label, sourceType: .launchDaemon, scope: .global, label: label, state: state)
        }
        func record(_ label: String, allowed: Bool) -> BackgroundTaskRecord {
            BackgroundTaskRecord(type: "legacy daemon", identifier: "16.\(label)", enabled: true, allowed: allowed)
        }
        let records = [
            record("off", allowed: false),
            record("live", allowed: false),
            record("mixed", allowed: false),
            record("mixed", allowed: true)
        ]

        let merged = BackgroundTaskMerger.merge(
            records,
            into: [item("off", .stopped), item("live", .running), item("mixed", .stopped)]
        )

        XCTAssertEqual(merged.map(\.state), [.disabled, .running, .stopped])
        XCTAssertTrue(merged[0].disabled)
    }

    func testDeepScannerPersistsSnapshotAndInventoryMergesIt() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString)/btm.json")
        let store = BackgroundTaskStore(fileURL: file)
        let scanner = BackgroundTaskDeepScanner(
            store: store,
            commandRunner: ScriptedCommandRunner(outputs: ["sfltool dumpbtm": sample])
        )

        try await scanner.deepScan()

        XCTAssertNotNil(scanner.lastScanDate)
        XCTAssertEqual(BackgroundTaskStore(fileURL: file).current?.records.count, 3)
        let inventory = ProductionServiceInventory(
            collectors: [],
            signatureReader: nil,
            explainer: nil,
            backgroundTaskStore: store
        )
        let ids = await inventory.collect().items.map(\.id)
        XCTAssertEqual(ids, ["btm:com.docker.helper", "btm:com.raycast.macos"])
    }

    func testDeepScannerReportsDeniedAuthorization() async {
        let scanner = BackgroundTaskDeepScanner(
            store: BackgroundTaskStore(fileURL: nil),
            commandRunner: ScriptedCommandRunner(outputs: ["sfltool dumpbtm": "nothing useful"])
        )
        do {
            try await scanner.deepScan()
            XCTFail("expected empty error")
        } catch {
            XCTAssertEqual(error as? DeepScanError, .empty)
        }
    }
}
