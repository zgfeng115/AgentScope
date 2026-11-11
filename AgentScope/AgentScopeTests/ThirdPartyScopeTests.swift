import Foundation
import XCTest
@testable import AgentScopeCore

final class ThirdPartyScopeTests: XCTestCase {
    private let filter = AppleItemFilter()

    func testSystemPathAndAppleLabelsAreExcluded() {
        let systemDaemon = ServiceItem(
            id: "launchdaemon:system:x", name: "x", sourceType: .launchDaemon, scope: .system,
            label: "com.example.x", configurationPath: "/System/Library/LaunchDaemons/x.plist"
        )
        let appleLabel = ServiceItem(
            id: "launchagent:global:com.apple.foo", name: "foo", sourceType: .launchAgent, scope: .global,
            label: "com.apple.foo", configurationPath: "/Library/LaunchAgents/com.apple.foo.plist"
        )
        XCTAssertTrue(filter.isAppleItem(systemDaemon))
        XCTAssertTrue(filter.isAppleItem(appleLabel))
    }

    func testThirdPartyLibraryItemsAreKept() {
        let todesk = ServiceItem(
            id: "launchdaemon:global:com.youqu.todesk.service", name: "todesk", sourceType: .launchDaemon, scope: .global,
            label: "com.youqu.todesk.service", configurationPath: "/Library/LaunchDaemons/com.youqu.todesk.service.plist",
            programPath: "/Applications/ToDesk.app/Contents/MacOS/ToDesk_Service"
        )
        XCTAssertFalse(filter.isAppleItem(todesk))
    }

    func testAppleSignedInterpreterDoesNotHideUserScript() {
        var script = ServiceItem(
            id: "launchagent:user:com.example.backup", name: "backup", sourceType: .launchAgent, scope: .user,
            label: "com.example.backup", configurationPath: "/Users/test/Library/LaunchAgents/com.example.backup.plist",
            programPath: "/bin/zsh", arguments: ["-c", "echo hi"]
        )
        script.signing = SigningInfo(signature: .apple, signedPath: "/bin/zsh")
        XCTAssertFalse(filter.isAppleItem(script))
    }

    func testAppleSignedProcessIsExcluded() {
        var process = ServiceItem(
            id: "process:1", name: "Finder", sourceType: .process, scope: .user,
            programPath: "/Applications/Safari.app/Contents/MacOS/Safari"
        )
        process.signing = SigningInfo(signature: .apple, signedPath: process.programPath!)
        XCTAssertTrue(filter.isAppleItem(process))
    }

    func testSigningTargetSkipsInterpreterToScriptArgument() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appending(path: "job.py")
        try "print(1)".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: directory) }

        let item = ServiceItem(
            id: "a", name: "a", sourceType: .launchAgent, scope: .user,
            programPath: "/usr/bin/python3", arguments: [script.path]
        )
        XCTAssertEqual(AppleItemFilter.signingTargetPath(for: item), script.path)

        let binary = ServiceItem(id: "b", name: "b", sourceType: .launchAgent, scope: .user, programPath: "/opt/app/bin/agent")
        XCTAssertEqual(AppleItemFilter.signingTargetPath(for: binary), "/opt/app/bin/agent")
    }

    func testCertificateSummaryParsing() {
        XCTAssertEqual(
            SecurityCodeSignatureReader.organization(fromCertificateSummary: "Developer ID Application: Docker Inc (9BNSXJN65R)"),
            "Docker Inc"
        )
        XCTAssertNil(SecurityCodeSignatureReader.organization(fromCertificateSummary: "Software Signing"))
        XCTAssertEqual(
            SecurityCodeSignatureReader.classify(teamID: nil, leafSummary: "Software Signing", isAdhoc: false, isPlatform: false),
            .apple
        )
        XCTAssertEqual(
            SecurityCodeSignatureReader.classify(teamID: "9BNSXJN65R", leafSummary: "Developer ID Application: Docker Inc (9BNSXJN65R)", isAdhoc: false, isPlatform: false),
            .developerID
        )
        XCTAssertEqual(
            SecurityCodeSignatureReader.classify(teamID: nil, leafSummary: nil, isAdhoc: true, isPlatform: false),
            .adhoc
        )
    }

    func testRealSystemBinaryIsAppleSigned() {
        let info = SecurityCodeSignatureReader().read(path: "/bin/ls")
        XCTAssertEqual(info?.signature, .apple)
    }

    func testProductionInventoryAttachesSigningAndDropsAppleItems() async {
        let thirdParty = ServiceItem(
            id: "launchdaemon:global:com.docker.vmnetd", name: "vmnetd", sourceType: .launchDaemon, scope: .global,
            label: "com.docker.vmnetd", configurationPath: "/Library/LaunchDaemons/com.docker.vmnetd.plist",
            programPath: "/Library/PrivilegedHelperTools/com.docker.vmnetd"
        )
        let systemItem = ServiceItem(
            id: "launchdaemon:system:com.apple.x", name: "x", sourceType: .launchDaemon, scope: .system,
            label: "com.apple.x", configurationPath: "/System/Library/LaunchDaemons/com.apple.x.plist"
        )
        let reader = FixedSignatureReader(info: [
            "/Library/PrivilegedHelperTools/com.docker.vmnetd": SigningInfo(
                signature: .developerID, teamID: "9BNSXJN65R", organization: "Docker Inc",
                signedPath: "/Library/PrivilegedHelperTools/com.docker.vmnetd"
            )
        ])
        let inventory = ProductionServiceInventory(
            collectors: [StaticCollector(items: [thirdParty, systemItem])],
            signatureReader: reader
        )

        let result = await inventory.collect()

        XCTAssertEqual(result.items.map(\.id), [thirdParty.id])
        XCTAssertEqual(result.items.first?.signing?.teamID, "9BNSXJN65R")
        XCTAssertEqual(result.items.first?.signature, .developerID)
        XCTAssertFalse(result.items.contains { ($0.configurationPath ?? $0.programPath ?? "").hasPrefix("/System/") })
    }

    func testDefaultLaunchdSourcesIncludeThirdPartyLibraryDirectories() {
        let paths = LaunchdSource.defaultSources(userID: 501).map(\.directoryURL.path)
        XCTAssertTrue(paths.contains("/Library/LaunchAgents"))
        XCTAssertTrue(paths.contains("/Library/LaunchDaemons"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("/System") })
        XCTAssertEqual(LaunchdSource.defaultSources(userID: 501).first { $0.directoryURL.path == "/Library/LaunchDaemons" }?.domain, .system)
    }

    func testDanglingPlistSymlinkBecomesStaleItemInsteadOfWarning() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createSymbolicLink(
            atPath: directory.appending(path: "org.virtualbox.startup.plist").path,
            withDestinationPath: "../Gone/org.virtualbox.startup.plist"
        )
        let collector = LaunchdCollector(
            sources: [LaunchdSource(directoryURL: directory, scope: .global, domain: .system)],
            commandRunner: ScriptedCommandRunner(),
            userID: 501
        )

        let result = await collector.collect()

        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.items.map(\.id), ["launchdaemon:global:org.virtualbox.startup"])
        XCTAssertEqual(result.items.first?.state, .stale)
        XCTAssertEqual(result.items.first?.validity, .missingTarget)
        XCTAssertTrue(result.items.first?.evidence.first?.detail.contains("../Gone") == true)
    }

    func testRootOnlyExecutableHelperIsHealthy() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appending(path: "d.plist")
        let helper = directory.appending(path: "helper")
        FileManager.default.createFile(atPath: config.path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: helper.path, contents: Data())
        try FileManager.default.setAttributes([.posixPermissions: 0o100], ofItemAtPath: helper.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path) }

        XCTAssertEqual(ValidityChecker().check(configurationURL: config, programPath: helper.path, arguments: []), .healthy)
    }

    func testRunningKeepAliveServiceWithOldFailureIsNotAbnormal() {
        let item = ServiceItem(
            id: "a", name: "tunnel", sourceType: .launchAgent, scope: .user, state: .running,
            lastExitCode: 255, validity: .healthy,
            executionEvidence: ExecutionEvidence(lastExecutionAt: nil, precision: .unknown, lastExitCode: 255, consecutiveFailures: 1, source: "launchctl", detail: nil)
        )
        XCTAssertEqual(ServiceReviewEngine().assess(item).status, .retain)
    }

    func testUnclearItemsDoNotNeedAttention() {
        var item = ServiceItem(id: "docker:1", name: "web", sourceType: .docker, scope: .user)
        item.assessment = ReviewAssessment(status: .unclear, confidence: 0.4, evidence: [])
        XCTAssertFalse(item.needsAttention)
        item.assessment = ReviewAssessment(status: .invalid, confidence: 0.9, evidence: [])
        XCTAssertTrue(item.needsAttention)
    }

    func testCronExecutableHandlesQuotedPathSegments() {
        XCTAssertEqual(
            ShellCommandParser.executable(from: "\"/Users/me/.acme.sh\"/acme.sh --cron --home \"/Users/me/.acme.sh\""),
            "/Users/me/.acme.sh/acme.sh"
        )
    }

    func testPrintDisabledParsing() {
        let output = """
        \tdisabled services = {
        \t\t"com.docker.helper" => enabled
        \t\t"com.example.off" => disabled
        \t\t"com.example.legacy" => true
        \t}
        """
        let overrides = LaunchdCollector.parseDisabledOverrides(output)
        XCTAssertEqual(overrides["com.docker.helper"], false)
        XCTAssertEqual(overrides["com.example.off"], true)
        XCTAssertEqual(overrides["com.example.legacy"], true)
    }
}

struct FixedSignatureReader: CodeSignatureReading {
    let info: [String: SigningInfo]

    func read(path: String) -> SigningInfo? {
        info[path]
    }
}

struct StaticCollector: Collector {
    let items: [ServiceItem]
    var warnings: [String] = []

    func collect() async -> CollectorResult {
        CollectorResult(items: items, warnings: warnings)
    }
}

/// Returns canned stdout keyed by "executable args..."; unknown commands throw.
struct ScriptedCommandRunner: CommandExecuting {
    var outputs: [String: String] = [:]

    func run(executable: URL, arguments: [String], timeout: TimeInterval, environment: [String: String]?) async throws -> CommandResult {
        let key = ([executable.lastPathComponent] + arguments).joined(separator: " ")
        guard let stdout = outputs[key] else { throw ScriptedCommandError.unexpected(key) }
        return CommandResult(stdout: stdout, stderr: "", exitCode: 0, timedOut: false, duration: 0)
    }
}

enum ScriptedCommandError: Error {
    case unexpected(String)
}
