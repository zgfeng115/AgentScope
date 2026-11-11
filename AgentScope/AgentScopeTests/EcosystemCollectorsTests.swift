import Foundation
import XCTest
@testable import AgentScopeCore

final class EcosystemCollectorsTests: XCTestCase {
    func testEmbeddedLoginItemCollectorFindsHelperWithStableDeduplicatedIdentity() async throws {
        let fixture = try EmbeddedLoginItemFixture.make(helperBundleIdentifier: "  com.example.host.helper  ")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let collector = EmbeddedLoginItemCollector(
            applicationRoots: [fixture.applicationRoot, fixture.applicationRoot],
            fileManager: .default
        )

        let firstResult = await collector.collect()
        let secondResult = await collector.collect()

        let item = try XCTUnwrap(firstResult.items.first)
        XCTAssertTrue(firstResult.warnings.isEmpty)
        XCTAssertEqual(firstResult.items.count, 1)
        XCTAssertEqual(item.id, secondResult.items.first?.id)
        XCTAssertEqual(item.sourceType, .embeddedLoginItem)
        XCTAssertEqual(item.scope, .user)
        XCTAssertEqual(item.state, .discovered)
        XCTAssertEqual(item.label, "com.example.host.helper")
        XCTAssertEqual(item.configurationPath, fixture.helper.path)
        XCTAssertEqual(item.programPath, fixture.helper.path)
        XCTAssertEqual(item.project?.rootPath, fixture.host.path)
        XCTAssertEqual(item.evidence.first?.detail, fixture.host.path)
        XCTAssertEqual(item.triggers?.first?.summary, "用户登录时启动 / 应用后台启动")
        XCTAssertEqual(item.executionEvidence?.source, "App Bundle LoginItems")
    }

    func testEmbeddedLoginItemCollectorRejectsEscapingSymlinksAndDeduplicatesAliases() async throws {
        let fixture = try EmbeddedLoginItemFixture.make(includeSymlinkAliases: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await EmbeddedLoginItemCollector(applicationRoots: [fixture.applicationRoot]).collect()

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(item.programPath, fixture.helper.path)
        XCTAssertFalse(item.id.contains("Host Alias.app"))
        XCTAssertFalse(item.id.contains("Escaped.app"))
    }

    func testEmbeddedLoginItemCollectorTreatsWhitespaceBundleIdentifierAsNil() async throws {
        let fixture = try EmbeddedLoginItemFixture.make(helperBundleIdentifier: "   ")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = await EmbeddedLoginItemCollector(applicationRoots: [fixture.applicationRoot]).collect()

        XCTAssertNil(result.items.first?.label)
    }

    func testEmbeddedLoginItemCollectorReturnsEmptyWithoutWarningWhenNoHelpersExist() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddedLoginItemCollectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = await EmbeddedLoginItemCollector(applicationRoots: [root]).collect()

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testEmbeddedLoginItemCollectorClassifiesMachineAndUserApplicationRoots() {
        XCTAssertEqual(
            EmbeddedLoginItemCollector.scope(forApplicationRoot: URL(fileURLWithPath: "/Applications")),
            .global
        )
        XCTAssertEqual(
            EmbeddedLoginItemCollector.scope(forApplicationRoot: URL(fileURLWithPath: "/System/Applications")),
            .system
        )
        XCTAssertEqual(
            EmbeddedLoginItemCollector.scope(
                forApplicationRoot: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications", isDirectory: true)
            ),
            .user
        )
    }

    func testHomebrewCollectorParsesServiceStatus() async throws {
        let json = """
        [{"name":"ollama","status":"started","loaded":true,"running":true,"file":"/Users/test/Library/LaunchAgents/homebrew.mxcl.ollama.plist","exit_code":0}]
        """
        let result = await HomebrewCollector(sourceText: json).collect()

        let item = try XCTUnwrap(result.items.first)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(item.id, "homebrew:user:ollama")
        XCTAssertEqual(item.state, .running)
        XCTAssertEqual(item.lastExitCode, 0)
        XCTAssertEqual(item.triggers?.first?.kind, .homebrew)
    }

    func testDockerCollectorPreservesComposeProjectMetadata() async throws {
        let json = #"{"ID":"abc123","Names":"api","Image":"example/api:latest","Status":"Up 2 hours","Labels":"com.docker.compose.project=demo,com.docker.compose.project.working_dir=/Users/test/demo,com.docker.compose.service=api"}"#
        let result = await DockerCollector(sourceText: json).collect()

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(item.id, "docker:container:abc123")
        XCTAssertEqual(item.state, .running)
        XCTAssertEqual(item.project?.displayName, "demo")
        XCTAssertEqual(item.project?.rootPath, "/Users/test/demo")
        XCTAssertEqual(item.triggers?.first?.kind, .docker)
    }

    func testTmuxCollectorTreatsNoServerAsEmptyInventory() async {
        let result = await TmuxCollector(sourceText: "no server running on /private/tmp/tmux-501/default").collect()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testTmuxCollectorTreatsMissingSocketAsEmptyInventory() async {
        let runner = ThrowingCommandRunner(
            error: .nonZeroExit(CommandResult(
                stdout: "",
                stderr: "error connecting to /private/tmp/tmux-501/default (No such file or directory)",
                exitCode: 1,
                timedOut: false,
                duration: 0
            ))
        )

        let result = await TmuxCollector(
            commandRunner: runner,
            executableURL: URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
        ).collect()

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testLoginItemCollectorUsesInjectedReader() async throws {
        let reader = FixedLoginItemReader(records: [
            LoginItemRecord(name: "Example.app", path: "/Applications/Example.app", bundleIdentifier: "com.example.app")
        ])
        let result = await LoginItemCollector(reader: reader).collect()

        let item = try XCTUnwrap(result.items.first)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(item.sourceType, .loginItem)
        XCTAssertEqual(item.scope, .user)
        XCTAssertEqual(item.state, .enabled)
        XCTAssertEqual(item.programPath, "/Applications/Example.app")
        XCTAssertEqual(item.configurationPath, "/Applications/Example.app")
        XCTAssertEqual(item.label, "com.example.app")
        XCTAssertEqual(item.executionEvidence?.source, "LSSharedFileList")
        XCTAssertEqual(item.executionEvidence?.detail, "传统用户登录项只读记录")
    }

    func testLoginItemCollectorDeduplicatesRepeatedRecordsByPath() async throws {
        let reader = FixedLoginItemReader(records: [
            LoginItemRecord(name: "Adobe Acrobat Reader DC", path: " /Applications/Adobe Acrobat Reader.app/// "),
            LoginItemRecord(name: "Adobe Acrobat Reader DC", path: "/Applications/./Adobe Acrobat Reader.app/../Adobe Acrobat Reader.app")
        ])
        let result = await LoginItemCollector(reader: reader).collect()

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.id, "loginitem:user:/Applications/Adobe Acrobat Reader.app")
        XCTAssertEqual(result.items.first?.programPath, "/Applications/Adobe Acrobat Reader.app")
    }

    func testLoginItemCollectorSkipsInvalidAndEmptyPaths() async throws {
        let reader = FixedLoginItemReader(records: [
            LoginItemRecord(name: "Empty", path: ""),
            LoginItemRecord(name: "Whitespace", path: "   "),
            LoginItemRecord(name: "Relative", path: "Applications/Relative.app"),
            LoginItemRecord(name: "Valid", path: " /Applications/Valid.app/// ")
        ])

        let result = await LoginItemCollector(reader: reader).collect()

        let item = try XCTUnwrap(result.items.first)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(item.name, "Valid")
        XCTAssertEqual(item.programPath, "/Applications/Valid.app")
    }

    func testLoginItemCollectorPreservesReaderFailureAsScopedWarning() async {
        let result = await LoginItemCollector(reader: FailingLoginItemReader()).collect()

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.warnings, ["Login Items unavailable: test failure"])
    }

    func testSharedFileListReaderNormalizesResolvedRecord() throws {
        let record = try XCTUnwrap(
            SharedFileListLoginItemReader.record(
                resolvedURL: URL(fileURLWithPath: "/Applications/Example.app/../Example.app/"),
                displayName: "Example Display",
                bundleIdentifier: "com.example.example"
            )
        )

        XCTAssertEqual(record.name, "Example Display")
        XCTAssertEqual(record.path, "/Applications/Example.app")
        XCTAssertEqual(record.bundleIdentifier, "com.example.example")
    }

    func testSharedFileListReaderRejectsNonFileAndEmptyPaths() throws {
        let nonFileURL = try XCTUnwrap(URL(string: "https://example.com/Example.app"))
        XCTAssertNil(
            SharedFileListLoginItemReader.record(
                resolvedURL: nonFileURL,
                displayName: nil,
                bundleIdentifier: nil
            )
        )
        XCTAssertNil(
            SharedFileListLoginItemReader.record(
                resolvedURL: URL(fileURLWithPath: "/"),
                displayName: " ",
                bundleIdentifier: nil
            )
        )
    }

    func testSharedFileListReaderUsesBundleNameWhenDisplayNameIsWhitespace() throws {
        let record = try XCTUnwrap(
            SharedFileListLoginItemReader.record(
                resolvedURL: URL(fileURLWithPath: "/Applications/Example.app"),
                displayName: "  ",
                bundleName: " Example Bundle ",
                bundleIdentifier: "com.example.example"
            )
        )

        XCTAssertEqual(record.name, "Example Bundle")
    }

    func testSharedFileListReaderUsesLastPathComponentWhenBundleNamesAreAbsent() throws {
        let record = try XCTUnwrap(
            SharedFileListLoginItemReader.record(
                resolvedURL: URL(fileURLWithPath: "/Applications/Fallback.app"),
                displayName: nil,
                bundleName: nil,
                bundleIdentifier: nil
            )
        )

        XCTAssertEqual(record.name, "Fallback.app")
    }

    func testSharedFileListReaderRetainsValidRecordsAlongsideInvalidURLs() throws {
        let invalidURL = try XCTUnwrap(URL(string: "https://example.com/Invalid.app"))

        let records = try SharedFileListLoginItemReader.records(from: [
            invalidURL,
            URL(fileURLWithPath: "/Applications/Valid.app")
        ])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.path, "/Applications/Valid.app")
    }

    func testSharedFileListReaderAllowsAnEmptyResolvedSnapshot() throws {
        XCTAssertEqual(try SharedFileListLoginItemReader.records(from: [URL]()), [])
    }

    func testSharedFileListReaderReportsWhenAllResolvedRecordsAreInvalid() throws {
        let nonFileURL = try XCTUnwrap(URL(string: "https://example.com/Example.app"))
        XCTAssertThrowsError(
            try SharedFileListLoginItemReader.records(from: [
                nonFileURL
            ])
        ) { error in
            XCTAssertEqual(
                error as? LoginItemReaderError,
                .unavailable("all resolved user login-item records had invalid paths")
            )
        }
    }
}

private struct EmbeddedLoginItemFixture {
    let root: URL
    let applicationRoot: URL
    let host: URL
    let helper: URL

    static func make(
        helperBundleIdentifier: String = "com.example.host.helper",
        includeSymlinkAliases: Bool = false
    ) throws -> EmbeddedLoginItemFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EmbeddedLoginItemCollectorTests-\(UUID().uuidString)", isDirectory: true)
        let applicationRoot = root.appendingPathComponent("Applications", isDirectory: true)
        let host = applicationRoot.appendingPathComponent("Host.app", isDirectory: true)
        let helper = host
            .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
            .appendingPathComponent("Helper.app", isDirectory: true)

        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let infoPlist = helper.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: infoPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": helperBundleIdentifier,
                "CFBundleName": "Helper"
            ],
            format: .xml,
            options: 0
        )
        try plistData.write(to: infoPlist)

        if includeSymlinkAliases {
            try FileManager.default.createSymbolicLink(
                at: applicationRoot.appendingPathComponent("Host Alias.app"),
                withDestinationURL: host
            )

            let escapedHost = root.appendingPathComponent("Escaped.app", isDirectory: true)
            let escapedHelper = escapedHost
                .appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
                .appendingPathComponent("EscapedHelper.app", isDirectory: true)
            try FileManager.default.createDirectory(at: escapedHelper, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: applicationRoot.appendingPathComponent("Escaped.app"),
                withDestinationURL: escapedHost
            )
        }

        return EmbeddedLoginItemFixture(
            root: root,
            applicationRoot: applicationRoot,
            host: host,
            helper: helper
        )
    }
}

private struct FixedLoginItemReader: LoginItemReading {
    let records: [LoginItemRecord]

    func read() throws -> [LoginItemRecord] { records }
}

private struct FailingLoginItemReader: LoginItemReading {
    func read() throws -> [LoginItemRecord] {
        throw LoginItemReaderError.unavailable("test failure")
    }
}

private struct ThrowingCommandRunner: CommandExecuting {
    let error: CommandRunnerError

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async throws -> CommandResult {
        throw error
    }
}
