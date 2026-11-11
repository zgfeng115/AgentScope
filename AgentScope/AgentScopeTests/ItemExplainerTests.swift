import Foundation
import XCTest
@testable import AgentScopeCore

final class ItemExplainerTests: XCTestCase {
    private let explainer = ItemExplainer(
        locator: FixedApplicationLocator(installed: ["com.youqu.todesk.mac"]),
        homeDirectory: "/Users/test"
    )

    func testMostSpecificKnowledgeEntryWins() {
        let service = explainer.explain(daemon(label: "com.youqu.todesk.service"))
        let uninstaller = explainer.explain(daemon(label: "com.youqu.todesk.UninstallerHelper"))

        XCTAssertEqual(service.vendorName, "ToDesk")
        XCTAssertEqual(service.purpose, .remoteControl)
        XCTAssertEqual(service.summarySource, .knowledgeBase)
        XCTAssertTrue(service.summary?.contains("远程") == true)
        XCTAssertTrue(uninstaller.summary?.contains("卸载辅助") == true)
    }

    func testTeamIDMatchesWhenLabelIsUnknown() {
        var kext = ServiceItem(
            id: "kext:Unknown.kext", name: "Unknown", sourceType: .kernelExtension, scope: .global,
            programPath: "/Library/Extensions/Unknown.kext"
        )
        kext.signing = SigningInfo(signature: .developerID, teamID: "CPQQ3AW49Y", signedPath: "/x")

        XCTAssertEqual(explainer.explain(kext).vendorName, "Splashtop")
    }

    func testOwnerAppStatusUsesKnownBundleIDs() {
        let todesk = explainer.explain(daemon(label: "com.youqu.todesk.service"))
        let teamViewer = explainer.explain(daemon(label: "com.teamviewer.Helper"))

        XCTAssertEqual(todesk.ownerAppStatus, .installed)
        XCTAssertEqual(teamViewer.ownerAppStatus, .missing)
    }

    func testOwnerAppStatusUsesProgramBundlePath() {
        let item = ServiceItem(
            id: "launchagent:global:com.gone.agent", name: "agent", sourceType: .launchAgent, scope: .global,
            label: "com.gone.agent", programPath: "/Applications/Gone-\(UUID().uuidString).app/Contents/MacOS/agent"
        )
        let explained = explainer.explain(item)

        XCTAssertEqual(explained.ownerAppStatus, .missing)
        XCTAssertEqual(explained.summarySource, .rule)
    }

    func testUserScriptRuleDescribesCommand() {
        var tunnel = ServiceItem(
            id: "launchagent:user:com.me.tunnel", name: "com.me.tunnel", sourceType: .launchAgent, scope: .user,
            label: "com.me.tunnel", programPath: "/usr/bin/ssh", arguments: ["-N", "-L", "8080:localhost:80", "host"],
            state: .running, triggers: [TriggerInfo(kind: .keepAlive, summary: "保持服务存活")]
        )
        tunnel.signing = SigningInfo(signature: .apple, signedPath: "/usr/bin/ssh")

        let explained = explainer.explain(tunnel)

        XCTAssertEqual(explained.purpose, .userScript)
        XCTAssertEqual(explained.summary, "自建登录后在后台运行的代理程序（LaunchAgent），执行 /usr/bin/ssh -N -L 8080:localhost:80 host，常驻运行，退出后会被自动拉起，当前正在运行。")
    }

    func testDeveloperSignedUnknownAgentGetsVendorSummary() {
        var agent = ServiceItem(
            id: "launchagent:user:com.vendor.sync", name: "com.vendor.sync", sourceType: .launchAgent, scope: .user,
            label: "com.vendor.sync", programPath: "/opt/vendor/syncd", state: .stopped
        )
        agent.signing = SigningInfo(signature: .developerID, teamID: "ZZZ", organization: "Vendor Ltd", signedPath: "/opt/vendor/syncd")

        let explained = explainer.explain(agent)

        XCTAssertEqual(explained.purpose, .syncBackup)
        XCTAssertEqual(explained.vendorName, "Vendor Ltd")
        XCTAssertEqual(explained.summary, "Vendor Ltd的登录后在后台运行的代理程序（LaunchAgent），当前未运行。")
    }

    func testCronIsUserScript() {
        let cron = ServiceItem(
            id: "cron:me:1", name: "/Users/test/run.sh", sourceType: .cron, scope: .user,
            triggers: [TriggerInfo(kind: .cron, summary: "每天")]
        )
        let explained = explainer.explain(cron)

        XCTAssertEqual(explained.purpose, .userScript)
        XCTAssertEqual(explained.summary, "自建cron 定时任务，执行 ~/run.sh，按计划定时执行，状态未知。")
    }

    private func daemon(label: String) -> ServiceItem {
        ServiceItem(
            id: "launchdaemon:global:\(label)", name: label, sourceType: .launchDaemon, scope: .global,
            label: label, configurationPath: "/Library/LaunchDaemons/\(label).plist"
        )
    }
}

struct FixedApplicationLocator: ApplicationLocating {
    let installed: Set<String>

    func isInstalled(bundleIdentifier: String) -> Bool {
        installed.contains(bundleIdentifier)
    }
}
