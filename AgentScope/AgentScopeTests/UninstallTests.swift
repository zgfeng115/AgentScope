import Foundation
import XCTest
@testable import AgentScopeCore

final class UninstallPlannerTests: XCTestCase {
    private let home = "/Users/tester"

    private func agent(
        _ label: String,
        program: String?,
        arguments: [String] = [],
        plist: String? = nil,
        source: SourceType = .launchDaemon,
        purpose: PurposeCategory? = nil,
        owner: OwnerAppStatus? = .missing
    ) -> ServiceItem {
        var item = ServiceItem(
            id: "\(source.rawValue):\(label)", name: label, sourceType: source,
            scope: source == .launchDaemon ? .global : .user, label: label,
            configurationPath: plist ?? "/Library/LaunchDaemons/\(label).plist",
            programPath: program, arguments: arguments
        )
        item.purpose = purpose
        item.ownerAppStatus = owner
        return item
    }

    private func plan(_ items: [ServiceItem], all: [ServiceItem]? = nil, existing: Set<String>? = nil) -> UninstallPlan {
        UninstallPlanner.plan(
            title: "t", items: items, allItems: all ?? items, userID: 501,
            fileExists: { existing?.contains($0) ?? true },
            isUserDeletable: { [home] in $0.hasPrefix(home + "/") }
        )
    }

    func testLeftoverDaemonRemovesPlistAndHelperWithAdmin() {
        let item = agent("com.teamviewer.Helper", program: "/Library/PrivilegedHelperTools/com.teamviewer.Helper")
        let result = plan([item])

        XCTAssertEqual(result.bootouts.map(\.target), ["system/com.teamviewer.Helper"])
        XCTAssertEqual(result.files.map(\.path), [
            "/Library/LaunchDaemons/com.teamviewer.Helper.plist",
            "/Library/PrivilegedHelperTools/com.teamviewer.Helper"
        ])
        XCTAssertEqual(result.files.map(\.kind), [.plist, .helper])
        XCTAssertTrue(result.requiresAdmin(selectedOptional: []))
    }

    func testSystemProgramsAndSharedBinariesAreNeverRemoved() {
        let shell = agent("com.vendor.shell", program: "/bin/sh", arguments: ["-c", "echo"])
        let shared = agent("com.tencent.Lemon.uninstall", program: "/Library/Application Support/Lemon/LemonDaemon")
        let stillUsed = agent("com.tencent.LemonDaemon", program: "/Library/Application Support/Lemon/LemonDaemon", owner: .installed)

        let result = plan([shell, shared], all: [shell, shared, stillUsed])

        XCTAssertFalse(result.files.map(\.path).contains("/bin/sh"))
        XCTAssertEqual(result.skipped.first { $0.path == "/Library/Application Support/Lemon/LemonDaemon" }?.reason,
                       "仍被「com.tencent.LemonDaemon」使用")
    }

    func testProgramsInsideInstalledAppsAreKept() {
        let item = agent("com.vendor.agent", program: "/Applications/Vendor.app/Contents/MacOS/agent")
        let result = plan([item])
        XCTAssertEqual(result.files.map(\.kind), [.plist])
        XCTAssertEqual(result.skipped.first?.reason, "属于仍安装的应用 Vendor.app")
    }

    func testUserScriptKeepsScriptOptionalAndNeedsNoAdmin() {
        let script = "\(home)/bin/backup.sh"
        let item = agent(
            "com.example.backup", program: "/bin/bash", arguments: [script],
            plist: "\(home)/Library/LaunchAgents/com.example.backup.plist",
            source: .launchAgent, purpose: .userScript, owner: .notApplicable
        )
        let result = plan([item], existing: [script, "\(home)/Library/LaunchAgents/com.example.backup.plist"])

        XCTAssertEqual(result.bootouts.map(\.target), ["gui/501/com.example.backup"])
        XCTAssertEqual(result.files.map(\.path), ["\(home)/Library/LaunchAgents/com.example.backup.plist"])
        XCTAssertEqual(result.optionalFiles.map(\.path), [script])
        XCTAssertFalse(result.requiresAdmin(selectedOptional: [script]))
    }

    func testKextIsOptionalAndHealthyItemsAreNotEligible() {
        var kext = ServiceItem(
            id: "kext:Foo.kext", name: "Foo", sourceType: .kernelExtension, scope: .global,
            label: "com.foo.kext", programPath: "/Library/Extensions/Foo.kext"
        )
        kext.ownerAppStatus = .missing
        let healthy = agent("com.vendor.ok", program: "/Library/PrivilegedHelperTools/ok", owner: .installed)

        let result = plan([kext, healthy])

        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.optionalFiles.first?.kind, .kext)
        XCTAssertEqual(result.optionalFiles.first?.bundleIdentifier, "com.foo.kext")
        XCTAssertEqual(result.serviceIDs, ["kext:Foo.kext"])
        XCTAssertFalse(result.notes.isEmpty)
    }

    func testFailingItemWithInstalledAppIsNotOfferedForUninstall() {
        var failing = agent("com.vendor.monitor", program: "/Library/Application Support/Vendor/monitor", owner: .installed)
        failing.state = .failed
        failing.validity = .healthy
        XCTAssertFalse(UninstallPlanner.isEligible(failing))

        // A stale plist whose owner is unknown: plist goes, the program stays.
        var stale = agent("com.vendor.old", program: "/Library/Application Support/Vendor/old", owner: .notApplicable)
        stale.state = .stale
        let result = plan([stale])
        XCTAssertEqual(result.files.map(\.kind), [.plist])
        XCTAssertEqual(result.skipped.first?.reason, "无法确认是残留，保留")
    }

    func testCronEntryAndMissingFilesAreSkippedQuietly() {
        var cron = ServiceItem(id: "cron:x", name: "acme.sh", sourceType: .cron, scope: .user, label: "0 3 * * *")
        cron.purpose = .userScript
        cron.executionEvidence = ExecutionEvidence(
            lastExecutionAt: nil, precision: .unknown, lastExitCode: nil, consecutiveFailures: 0,
            source: "crontab", detail: "/usr/local/bin/acme.sh --cron"
        )
        let gone = agent("org.virtualbox.startup", program: "/Library/Application Support/VirtualBox/x")

        let result = plan([cron, gone], existing: ["/Library/LaunchDaemons/org.virtualbox.startup.plist"])

        XCTAssertEqual(result.cronEntries, [CronLine(expression: "0 3 * * *", command: "/usr/local/bin/acme.sh --cron")])
        XCTAssertEqual(result.files.map(\.path), ["/Library/LaunchDaemons/org.virtualbox.startup.plist"])
    }
}

final class UninstallExecutorTests: XCTestCase {
    func testAdminScriptQuotesSpacesChineseAndQuotes() {
        let file = UninstallFile(
            path: "/Library/Application Support/飞牛 It's/agent", kind: .program,
            requiresAdmin: true, bundleIdentifier: nil, note: nil
        )
        let script = UninstallExecutor.adminScript(
            bootouts: [LaunchdBootout(target: "system/com.x")],
            moves: [(file, "/Users/t/Staging/1-agent")],
            stagingDirectory: "/Users/t/Staging",
            owner: "501:20"
        )
        XCTAssertTrue(script.contains("/bin/launchctl bootout 'system/com.x'"))
        XCTAssertTrue(script.contains("/bin/mv -n '/Library/Application Support/飞牛 It'\\''s/agent' '/Users/t/Staging/1-agent'"))
        XCTAssertTrue(script.contains("/usr/sbin/chown -hR 501:20 '/Users/t/Staging/1-agent'"))

        let apple = UninstallExecutor.appleScript(running: "echo \"a\\b\"")
        XCTAssertEqual(apple, "do shell script \"echo \\\"a\\\\b\\\"\" with administrator privileges")
    }

    /// Runs the generated script through osascript (without the admin clause) so both the shell quoting
    /// and the AppleScript string escaping are exercised on a path with spaces, Chinese and a quote.
    func testScriptSurvivesAppleScriptAndShellQuoting() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "uninstall-\(UUID().uuidString)")
        let source = dir.appending(path: "a b's \"文件\".plist")
        let staging = dir.appending(path: "Staging \\ dir")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: source, atomically: true, encoding: .utf8)
        let destination = staging.appending(path: "1-a b's.plist").path
        let file = UninstallFile(path: source.path, kind: .plist, requiresAdmin: true, bundleIdentifier: nil, note: nil)
        let script = UninstallExecutor.adminScript(
            bootouts: [], moves: [(file, destination)], stagingDirectory: staging.path, owner: "\(getuid()):\(getgid())"
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", UninstallExecutor.appleScript(running: script, admin: false)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let moved = UninstallExecutor.parseMoved(output.replacingOccurrences(of: "\r", with: "\n"))
        XCTAssertEqual(moved.first?.from, source.path)
        XCTAssertEqual(moved.first?.to, destination)
    }

    func testCancelledPasswordPromptChangesNothing() async {
        let plan = UninstallPlan(
            title: "t", serviceIDs: ["a"], labels: ["a"], bootouts: [LaunchdBootout(target: "system/a")],
            files: [], optionalFiles: [], cronEntries: [], skipped: [], notes: []
        )
        let executor = UninstallExecutor(
            commandRunner: FailingRunner(stderr: "execution error: User canceled. (-128)"),
            stagingRoot: FileManager.default.temporaryDirectory,
            backupRoot: FileManager.default.temporaryDirectory
        )
        do {
            _ = try await executor.uninstall(plan, selectedOptional: [])
            XCTFail("expected cancel")
        } catch {
            XCTAssertEqual(error as? UninstallError, .cancelled)
        }
    }

    func testCrontabFilterRemovesOnlyMatchingLines() {
        let text = "# keep\nMAILTO=x\n0 3 * * * /usr/local/bin/acme.sh --cron\n*/5 * * * * /bin/other\n"
        let (kept, removed) = UninstallExecutor.filterCrontab(
            text, removing: [CronLine(expression: "0 3 * * *", command: "/usr/local/bin/acme.sh --cron")]
        )
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(kept, "# keep\nMAILTO=x\n*/5 * * * * /bin/other\n")
    }
}

private struct FailingRunner: CommandExecuting {
    let stderr: String

    func run(executable: URL, arguments: [String], timeout: TimeInterval, environment: [String: String]?) async throws -> CommandResult {
        throw CommandRunnerError.nonZeroExit(CommandResult(stdout: "", stderr: stderr, exitCode: 1, timedOut: false, duration: 0))
    }
}
