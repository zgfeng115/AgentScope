import XCTest
@testable import AgentScopeCore

final class ServiceItemTests: XCTestCase {
    func testDomainEnumsKeepStableRawValues() {
        XCTAssertEqual(SourceType.launchAgent.rawValue, "launchAgent")
        XCTAssertEqual(SourceType.embeddedLoginItem.rawValue, "embeddedLoginItem")
        XCTAssertEqual(SourceType.embeddedLoginItem.displayName, "App 内置 LoginItem")
        XCTAssertEqual(ServiceState.systemReadonly.rawValue, "systemReadonly")
        XCTAssertEqual(RunTimePrecision.approximate.rawValue, "approximate")
        XCTAssertEqual(ValidityStatus.missingTarget.rawValue, "missingTarget")
        XCTAssertEqual(OperationAction.testRun.rawValue, "testRun")
    }

    func testStartupOverviewPresentationKeepsCompatibleFilterAndNamesSourcesPrecisely() {
        XCTAssertEqual(SourceFilter.loginItems.rawValue, "loginItems")
        XCTAssertEqual(SourceFilter.loginItems.displayName, "启动项总览")
        XCTAssertEqual(SourceFilter.loginItems.systemImage, "rectangle.3.group")
        XCTAssertEqual(
            SourceFilter.loginItems.coverageDescription,
            "当前读取传统 Login Item、LaunchAgent、App 内置 LoginItem；系统设置中的「允许在后台」列表需点击工具栏「深度扫描」读取。"
        )
        XCTAssertEqual(SourceType.loginItem.displayName, "传统 Login Item")
        XCTAssertEqual(SourceType.launchAgent.displayName, "LaunchAgent")
        XCTAssertEqual(SourceType.embeddedLoginItem.displayName, "App 内置 LoginItem")
    }

    func testStartupOverviewManagementSemanticsDistinguishEditableAndReadonlyItems() {
        let legacy = ServiceItem(
            id: "loginitem:user:legacy",
            name: "Legacy",
            sourceType: .loginItem,
            scope: .user
        )
        let launchAgent = ServiceItem(
            id: "launchagent:user:agent",
            name: "Agent",
            sourceType: .launchAgent,
            scope: .user
        )
        let embedded = ServiceItem(
            id: "embedded:system:helper",
            name: "Helper",
            sourceType: .embeddedLoginItem,
            scope: .system,
            state: .systemReadonly
        )

        XCTAssertTrue(legacy.isReadOnlyInStartupOverview)
        XCTAssertEqual(legacy.startupOverviewAccessDisplayName, "用户只读")
        XCTAssertFalse(launchAgent.isReadOnlyInStartupOverview)
        XCTAssertEqual(launchAgent.startupOverviewAccessDisplayName, "用户")
        XCTAssertTrue(embedded.isReadOnlyInStartupOverview)
        XCTAssertEqual(embedded.startupOverviewAccessDisplayName, "系统只读")
    }

    func testStartupOverviewGroupSummarizesSourcesAccessAndStatesDeterministically() {
        let group = LoginItemApplicationGroup(
            id: "bundle:com.example.host",
            applicationName: "Host",
            enabledState: .unknown,
            items: [
                ServiceItem(
                    id: "embedded:system:helper",
                    name: "Helper",
                    sourceType: .embeddedLoginItem,
                    scope: .system,
                    state: .discovered
                ),
                ServiceItem(
                    id: "loginitem:user:host",
                    name: "Host",
                    sourceType: .loginItem,
                    scope: .user,
                    state: .enabled
                ),
                ServiceItem(
                    id: "launchagent:user:host",
                    name: "Agent",
                    sourceType: .launchAgent,
                    scope: .user,
                    state: .running
                )
            ]
        )

        XCTAssertEqual(group.sourceSummary, "传统 Login Item、LaunchAgent、App 内置 LoginItem")
        XCTAssertEqual(group.accessSummary, "用户、用户只读、系统只读")
        XCTAssertEqual(group.stateSummary, "已发现、已启用、运行中")
    }

    func testStartupOverviewDetailMetadataUsesSourceSpecificEvidenceAndReadonlyCopy() {
        let legacy = ServiceItem(
            id: "loginitem:user:legacy",
            name: "Legacy",
            sourceType: .loginItem,
            scope: .user
        )
        let embedded = ServiceItem(
            id: "embedded:user:helper",
            name: "Helper",
            sourceType: .embeddedLoginItem,
            scope: .user,
            project: ProjectIdentity(
                id: "appBundle:/Applications/Host.app",
                displayName: "Host",
                rootPath: "/Applications/Host.app",
                kind: .appBundle,
                confidence: 1,
                evidence: []
            )
        )

        XCTAssertEqual(legacy.startupOverviewDetailTitle, "传统 Login Item 信息")
        XCTAssertEqual(legacy.startupOverviewEvidenceLabel, "LSSharedFileList 证据")
        XCTAssertEqual(legacy.startupOverviewEvidenceFallback, "LSSharedFileList（传统用户登录项）")
        XCTAssertEqual(legacy.startupOverviewReadOnlyDescription, "该条目是用户级传统 Login Item 的只读记录，普通操作不会修改它。")

        XCTAssertEqual(embedded.startupOverviewDetailTitle, "App 内置 LoginItem 信息")
        XCTAssertEqual(embedded.startupOverviewEvidenceLabel, "App Bundle 证据")
        XCTAssertEqual(embedded.startupOverviewEvidenceFallback, "App Bundle LoginItems（只读发现）")
        XCTAssertEqual(embedded.startupOverviewHostApplicationPath, "/Applications/Host.app")
        XCTAssertEqual(embedded.startupOverviewReadOnlyDescription, "该条目来自 App 包内置 LoginItems，仅作只读发现，普通操作不会修改它。")
    }

    func testServiceItemRoundTripPreservesIdentity() throws {
        let item = ServiceItem(
            id: "launchagent:user:com.example.valid",
            name: "com.example.valid",
            sourceType: .launchAgent,
            scope: .user,
            configurationPath: "/tmp/com.example.valid.plist",
            programPath: "/usr/bin/true",
            arguments: ["--fixture"],
            state: .enabled,
            pid: 42,
            startedAt: Date(timeIntervalSince1970: 100),
            lastRunAt: Date(timeIntervalSince1970: 200),
            lastRunPrecision: .exact,
            lastExitCode: 0,
            disabled: false,
            validity: .healthy,
            attribution: Attribution(kind: "userProject", confidence: 0.9, evidence: ["Git repository"]),
            evidence: [Evidence(title: "Target exists", detail: "/usr/bin/true", severity: .info)]
        )

        let restored = try JSONDecoder().decode(
            ServiceItem.self,
            from: JSONEncoder().encode(item)
        )

        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.arguments, item.arguments)
        XCTAssertEqual(restored.state, .enabled)
        XCTAssertEqual(restored.attribution?.confidence, 0.9)
        XCTAssertEqual(restored.evidence.first?.severity, .info)
    }

    func testServiceItemRoundTripPreservesAuditContext() throws {
        let item = ServiceItem(
            id: "launchagent:user:com.example.worker",
            name: "com.example.worker",
            sourceType: .launchAgent,
            scope: .user,
            project: ProjectIdentity(
                id: "project:/Users/test/worker",
                displayName: "worker",
                rootPath: "/Users/test/worker",
                kind: .gitRepository,
                confidence: 0.9,
                evidence: ["Git repository"]
            ),
            triggers: [TriggerInfo(kind: .runAtLoad, summary: "登录后启动")],
            executionEvidence: ExecutionEvidence(
                lastExecutionAt: Date(timeIntervalSince1970: 300),
                precision: .exact,
                lastExitCode: 0,
                consecutiveFailures: 0,
                source: "launchctl"
            ),
            assessment: ReviewAssessment(
                status: .retain,
                confidence: 0.8,
                evidence: ["目标文件存在"]
            )
        )

        let restored = try JSONDecoder().decode(
            ServiceItem.self,
            from: JSONEncoder().encode(item)
        )

        XCTAssertEqual(restored.project?.displayName, "worker")
        XCTAssertEqual(restored.triggers?.first?.kind, .runAtLoad)
        XCTAssertEqual(restored.executionEvidence?.lastExitCode, 0)
        XCTAssertEqual(restored.assessment?.status, .retain)
    }

    func testOperationRecordRoundTripPreservesActionAndBackup() throws {
        let record = OperationRecord(
            serviceID: "launchagent:user:com.example.valid",
            action: .disable,
            succeeded: true,
            message: "Disabled",
            backupPath: "/tmp/backup.plist"
        )

        let restored = try JSONDecoder().decode(
            OperationRecord.self,
            from: JSONEncoder().encode(record)
        )

        XCTAssertEqual(restored.action, .disable)
        XCTAssertEqual(restored.backupPath, "/tmp/backup.plist")
    }
}
