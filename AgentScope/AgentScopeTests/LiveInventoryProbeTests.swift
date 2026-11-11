import Foundation
import XCTest
@testable import AgentScopeCore

/// Live reconciliation against the real machine. Skipped unless run with
/// `TEST_RUNNER_AGENTSCOPE_LIVE=1 xcodebuild test ...`.
final class LiveInventoryProbeTests: XCTestCase {
    func testLiveInventoryCountsBySource() async throws {
        guard ProcessInfo.processInfo.environment["AGENTSCOPE_LIVE"] == "1" else {
            throw XCTSkip("live probe disabled")
        }
        let btmFile = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/AgentScope/background-tasks.json")
        let inventory = ProductionCollectors.makeInventory(
            userID: getuid(),
            backgroundTaskStore: BackgroundTaskStore(fileURL: btmFile)
        )
        let result = await inventory.collect()

        let provider = SystemRunningProcessProvider()
        let processes = await provider.processes()
        let foreground = await provider.foregroundApplicationPaths()
        var lines: [String] = [
            "LIVE total=\(result.items.count) warnings=\(result.warnings.count)",
            "LIVEPROC processes=\(processes.count) foreground=\(foreground.count)"
        ]
        let grouped = Dictionary(grouping: result.items) { "\($0.sourceType.rawValue)/\($0.scope.rawValue)" }
        for key in grouped.keys.sorted() {
            lines.append("LIVE \(key)=\(grouped[key]!.count)")
        }
        for item in result.items.sorted(by: { $0.id < $1.id }) {
            let vendor = item.signing.map { "\($0.signature.rawValue) \($0.teamID ?? "-") \($0.organization ?? "-")" } ?? "nosig"
            let btm = item.evidence.contains { $0.title == "系统设置「允许在后台」" } ? " BTM" : ""
            let purpose = "\(item.purpose?.rawValue ?? "-") owner=\(item.ownerAppStatus?.rawValue ?? "-") vendor=\(item.vendorName ?? "-") src=\(item.summarySource?.rawValue ?? "-")"
            lines.append("LIVEITEM \(item.id) | \(item.state.rawValue) [\(item.assessment?.status.rawValue ?? "-"): \(item.assessment?.evidence.first ?? "")] | \(vendor) | \(purpose) | \(item.summary ?? "")\(btm)")
        }
        for item in result.items.sorted(by: { $0.id < $1.id }) where UninstallPlanner.isEligible(item) {
            lines.append("LIVEELIGIBLE \(item.id) owner=\(item.ownerAppStatus?.rawValue ?? "-") purpose=\(item.purpose?.rawValue ?? "-") state=\(item.state.rawValue)")
        }
        for warning in result.warnings {
            lines.append("LIVEWARN \(warning)")
        }
        let output = lines.joined(separator: "\n")
        let target = ProcessInfo.processInfo.environment["AGENTSCOPE_LIVE_OUT"] ?? NSTemporaryDirectory() + "agentscope-live.txt"
        try output.write(toFile: target, atomically: true, encoding: .utf8)
        XCTAssertFalse(result.items.contains { ($0.configurationPath ?? "").hasPrefix("/System/") })
    }
}

/// Creates a throwaway LaunchAgent, checks schedule info, then uninstalls both for real.
/// Skipped unless `TEST_RUNNER_AGENTSCOPE_LIVE_UNINSTALL=1`.
final class LiveUninstallSelfTest: XCTestCase {
    func testSelfTestAgentAndCronRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["AGENTSCOPE_LIVE_UNINSTALL"] == "1" else {
            throw XCTSkip("live uninstall disabled")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let label = "com.agentscope.selftest"
        let plist = home.appending(path: "Library/LaunchAgents/\(label).plist")
        let log = home.appending(path: "Library/Logs/agentscope-selftest.log")
        let config: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/bin/echo", "selftest"],
            "StartInterval": 60,
            "RunAtLoad": true,
            "StandardOutPath": log.path
        ]
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(to: plist)
        let runner = CommandRunner()
        let uid = getuid()
        _ = try? await runner.run(executable: URL(fileURLWithPath: "/bin/launchctl"),
                                  arguments: ["bootstrap", "gui/\(uid)", plist.path], timeout: 10, environment: nil)
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let inventory = ProductionCollectors.makeInventory(userID: uid)
        var items = await inventory.collect().items
        let agent = try XCTUnwrap(items.first { $0.label == label })
        var lines = [
            "SELFTEST agent purpose=\(agent.purpose?.rawValue ?? "-") state=\(agent.state.rawValue) lastRun=\(agent.lastRunAt.map { "\($0)" } ?? "-") runs=\(agent.executionEvidence?.runCount.map(String.init) ?? "-") next=\(agent.triggers?.compactMap(\.nextRunAt).first.map { "\($0)" } ?? "-")"
        ]
        XCTAssertEqual(agent.purpose, .userScript)
        XCTAssertNotNil(agent.triggers?.compactMap(\.nextRunAt).first)
        XCTAssertTrue(UninstallPlanner.isEligible(agent))

        let plan = UninstallPlanner.plan(title: "selftest", items: [agent], allItems: items)
        lines.append("SELFTEST plan files=\(plan.files.map(\.path)) optional=\(plan.optionalFiles.map(\.path)) cron=\(plan.cronEntries.count) skipped=\(plan.skipped.map(\.reason)) admin=\(plan.requiresAdmin(selectedOptional: []))")
        XCTAssertFalse(plan.requiresAdmin(selectedOptional: []))
        let backups = FileManager.default.temporaryDirectory.appending(path: "agentscope-selftest-backups")
        let report = try await UninstallExecutor(stagingRoot: backups, backupRoot: backups).uninstall(plan, selectedOptional: [])
        lines.append("SELFTEST report \(report.summary.replacingOccurrences(of: "\n", with: " | "))")

        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        items = await inventory.collect().items
        XCTAssertNil(items.first { $0.label == label })
        try? FileManager.default.removeItem(at: log)

        let target = ProcessInfo.processInfo.environment["AGENTSCOPE_LIVE_OUT"] ?? NSTemporaryDirectory() + "agentscope-selftest.txt"
        try lines.joined(separator: "\n").write(toFile: target, atomically: true, encoding: .utf8)
    }
}

/// Sends a deliberately invalid key to a real endpoint and checks the error path. Network; skipped by default.
final class LiveAIConnectionTest: XCTestCase {
    func testBogusKeyReportsHTTPErrorWithoutLeakingKey() async throws {
        guard ProcessInfo.processInfo.environment["AGENTSCOPE_LIVE_AI"] == "1" else {
            throw XCTSkip("live AI test disabled")
        }
        let bogus = "sk-agentscope-invalid-\(UUID().uuidString.prefix(8))"
        for preset in [AIProviderPreset.deepSeek, .claude] {
            let configuration = AIModelConfiguration(
                providerID: preset.rawValue, enabled: true, baseURL: preset.defaultBaseURL, model: preset.defaultModel, timeout: 20
            )
            do {
                _ = try await AIProviderFactory.make(configuration: configuration, apiKey: bogus).testConnection()
                XCTFail("\(preset) accepted a bogus key")
            } catch {
                let message = error.localizedDescription
                print("LIVEAI \(preset.rawValue): \(message.prefix(160))")
                XCTAssertTrue(message.contains("HTTP 401") || message.contains("HTTP 403"), message)
                XCTAssertFalse(message.contains(bogus))
            }
        }
    }
}
