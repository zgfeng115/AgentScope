import Foundation
import XCTest
@testable import AgentScopeCore

final class SystemLevelCollectorsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPrivilegedHelperCollectorReportsOnlyOrphansAndLabelMismatches() async throws {
        let helpers = root.appending(path: "helpers")
        let daemons = root.appending(path: "daemons")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: daemons, withIntermediateDirectories: true)
        for name in ["com.docker.vmnetd", "com.west2online.ClashX.ProxyConfigHelper", "com.example.renamed"] {
            FileManager.default.createFile(atPath: helpers.appending(path: name).path, contents: Data())
        }
        try writePlist(["Label": "com.docker.vmnetd", "Program": helpers.appending(path: "com.docker.vmnetd").path],
                       to: daemons.appending(path: "com.docker.vmnetd.plist"))
        try writePlist(["Label": "com.example.renamed", "ProgramArguments": ["/opt/other/bin"]],
                       to: daemons.appending(path: "com.example.renamed.plist"))

        let result = await PrivilegedHelperCollector(helperDirectory: helpers, daemonDirectory: daemons).collect()

        XCTAssertEqual(result.items.map(\.id), [
            "privilegedhelper:com.example.renamed",
            "privilegedhelper:com.west2online.ClashX.ProxyConfigHelper"
        ])
        let orphan = result.items.first { $0.id.hasSuffix("ClashX.ProxyConfigHelper") }
        XCTAssertEqual(orphan?.state, .stale)
        XCTAssertEqual(orphan?.evidence.first?.title, "孤儿特权助手")
        XCTAssertEqual(result.items.first?.state, .discovered)
    }

    func testSystemExtensionParsingMergesVersionsAndNotesPendingRemoval() {
        let output = [
            "4 extension(s)",
            "--- com.apple.system_extension.network_extension (Go to 'System Settings')",
            "enabled\tactive\tteamID\tbundleID (version)\tname\t[state]",
            "\t\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.104.1/101.104.1)\tTailscale Network Extension\t[terminated waiting to uninstall on reboot]",
            "*\t*\t287TTNZF8L\tio.nekohasekai.sfavt.system (1.13.4/1)\tSFMExtension\t[activated enabled]",
            "*\t*\tW5364U7YZB\tio.tailscale.ipn.macsys.network-extension (1.104.5/101.104.5)\tTailscale Network Extension\t[activated enabled]"
        ].joined(separator: "\n")

        let records = SystemExtensionCollector.parse(output)
        let items = SystemExtensionCollector.items(from: records)

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.first?.version, "1.104.1/101.104.1")
        XCTAssertEqual(items.map(\.bundleIdentifier), ["io.nekohasekai.sfavt.system", "io.tailscale.ipn.macsys.network-extension"])
        let tailscale = items.last
        XCTAssertEqual(tailscale?.state, .running)
        XCTAssertEqual(tailscale?.signing?.teamID, "W5364U7YZB")
        XCTAssertTrue(tailscale?.evidence.contains { $0.detail.contains("1 个版本等待重启后卸载") } == true)
    }

    func testKernelExtensionCollectorReadsBundleAndLoadedState() async throws {
        let directory = root.appending(path: "Extensions")
        try makeKext(in: directory, name: "HoRNDIS", identifier: "com.joshuawise.kexts.HoRNDIS")
        try makeKext(in: directory, name: "SoftRAID", identifier: "com.softraid.driver.SoftRAID")
        let runner = ScriptedCommandRunner(outputs: [
            "kmutil showloaded --list-only":
                "  210    0 0  0  0  com.softraid.driver.SoftRAID (8.5) 1234-ABCD <8 6 5 3 1>\n"
        ])

        let result = await KernelExtensionCollector(directory: directory, commandRunner: runner).collect()

        XCTAssertEqual(result.items.map(\.bundleIdentifier), ["com.joshuawise.kexts.HoRNDIS", "com.softraid.driver.SoftRAID"])
        XCTAssertEqual(result.items.map(\.state), [.stopped, .running])
        XCTAssertEqual(result.items.first?.sourceType, .kernelExtension)
    }

    func testKernelExtensionLoadedParsing() {
        let output = "    3  228 0  0  0  com.apple.kpi.bsd (27.2.0) BA25 <>\n  150 0 0 0 0 com.vendor.driver (1.0) X <>"
        XCTAssertEqual(KernelExtensionCollector.parseLoaded(output), ["com.apple.kpi.bsd", "com.vendor.driver"])
    }

    func testProcessParsingKeepsPathsWithSpaces() {
        let comm = "  553     1     0 ??       /Library/Application Support/CCB_HDZB_UKEY/moniter_CCB_HDZB\n  600   1   501 ttys001  zsh"
        let args = "  553 /Library/Application Support/CCB_HDZB_UKEY/moniter_CCB_HDZB --daemon"
        let processes = SystemRunningProcessProvider.parse(comm: comm, args: args)
        XCTAssertEqual(processes.count, 1)
        XCTAssertEqual(processes.first?.hasTerminal, false)
        XCTAssertTrue(processes.first?.executablePath.hasSuffix("moniter_CCB_HDZB") == true)
    }

    func testResidentScannerLinksKnownItemsAndKeepsOnlyBackgroundLeftovers() async {
        let daemon = ServiceItem(
            id: "launchdaemon:global:ddns-go", name: "ddns-go", sourceType: .launchDaemon, scope: .global,
            programPath: "/opt/tools/ddns-go", state: .stopped
        )
        let loginItem = ServiceItem(
            id: "loginitem:user:/Applications/Mos.app", name: "Mos", sourceType: .loginItem, scope: .user,
            programPath: "/Applications/Mos.app", state: .enabled
        )
        let processes = [
            RunningProcess(pid: 10, parentPID: 1, userID: 0, hasTerminal: false, executablePath: "/opt/tools/ddns-go", arguments: []),
            RunningProcess(pid: 11, parentPID: 1, userID: 501, hasTerminal: false, executablePath: "/Applications/Mos.app/Contents/MacOS/Mos", arguments: []),
            RunningProcess(pid: 12, parentPID: 1, userID: 501, hasTerminal: false, executablePath: "/Applications/Chrome.app/Contents/MacOS/Chrome", arguments: []),
            RunningProcess(pid: 13, parentPID: 12, userID: 501, hasTerminal: false, executablePath: "/Applications/Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", arguments: []),
            RunningProcess(pid: 14, parentPID: 1, userID: 501, hasTerminal: false, executablePath: "/Applications/Nutstore.app/Contents/MacOS/Nutstore", arguments: []),
            RunningProcess(pid: 15, parentPID: 1, userID: 501, hasTerminal: false, executablePath: "/Applications/Nutstore.app/Contents/MacOS/NutstoreHelper", arguments: []),
            RunningProcess(pid: 16, parentPID: 1, userID: 501, hasTerminal: false, executablePath: "/usr/libexec/trustd", arguments: []),
            RunningProcess(pid: 17, parentPID: 1, userID: 501, hasTerminal: false, executablePath: "/usr/bin/python3", arguments: ["/Users/test/bot/server.py"]),
            RunningProcess(pid: 18, parentPID: 1, userID: 501, hasTerminal: true, executablePath: "/bin/zsh", arguments: []),
            RunningProcess(pid: 19, parentPID: 18, userID: 501, hasTerminal: true, executablePath: "/opt/homebrew/bin/node", arguments: ["/Users/test/app/dev.js"]),
            RunningProcess(pid: 20, parentPID: 19, userID: 501, hasTerminal: false, executablePath: "/opt/homebrew/bin/node", arguments: ["/Users/test/app/worker.js"]),
            RunningProcess(pid: 21, parentPID: 1, userID: 88, hasTerminal: false, executablePath: "/opt/other-user/agent", arguments: [])
        ]
        let scanner = ResidentProcessScanner(
            provider: FixedRunningProcessProvider(processes: processes, foreground: ["/Applications/Chrome.app"]),
            currentUserID: 501,
            ownProcessID: 999
        )

        let items = await scanner.link([daemon, loginItem])

        XCTAssertEqual(items.first { $0.id == daemon.id }?.state, .stopped, "launchctl state is authoritative")
        XCTAssertFalse(items.contains { $0.programPath == "/opt/tools/ddns-go" && $0.sourceType == .process })
        XCTAssertEqual(items.first { $0.id == loginItem.id }?.state, .running)
        let residents = items.filter { $0.sourceType == .process }
        XCTAssertEqual(residents.map(\.id), ["process:/Applications/Nutstore.app", "process:/Users/test/bot/server.py"])
        XCTAssertTrue(residents.first?.evidence.first?.detail.contains("2 个进程") == true)
        XCTAssertEqual(residents.last?.programPath, "/Users/test/bot/server.py")
        XCTAssertEqual(residents.last?.name, "server.py")
    }

    func testSharedToolProcessesDoNotMarkLaunchdItemsRunning() async {
        let backup = ServiceItem(
            id: "launchagent:user:com.me.backup", name: "backup", sourceType: .launchAgent, scope: .user,
            programPath: "/bin/bash", arguments: ["/Users/test/backup.sh"], state: .stopped
        )
        let lemonUninstall = ServiceItem(
            id: "launchdaemon:global:com.tencent.Lemon.uninstall", name: "uninstall", sourceType: .launchDaemon, scope: .global,
            programPath: "/Applications/Lemon.app/Contents/MacOS/uninstall", state: .stopped
        )
        let lemonHelper = ServiceItem(
            id: "embeddedLoginItem:lemon", name: "LemonMonitor", sourceType: .embeddedLoginItem, scope: .global,
            programPath: "/Applications/Lemon.app/Contents/Library/LoginItems/LemonMonitor.app", state: .discovered
        )
        let processes = [
            RunningProcess(pid: 30, parentPID: 1, userID: 501, hasTerminal: false, executablePath: "/bin/bash", arguments: ["/Users/test/other.sh"]),
            RunningProcess(pid: 31, parentPID: 1, userID: 501, hasTerminal: false, executablePath: "/Applications/Lemon.app/Contents/Library/LoginItems/LemonMonitor.app/Contents/MacOS/LemonMonitor", arguments: []),
            RunningProcess(pid: 32, parentPID: 1, userID: 501, hasTerminal: false, executablePath: "/Applications/Lemon.app/Contents/MacOS/Lemon", arguments: [])
        ]
        let scanner = ResidentProcessScanner(
            provider: FixedRunningProcessProvider(processes: processes),
            currentUserID: 501,
            ownProcessID: 999
        )

        let items = await scanner.link([backup, lemonUninstall, lemonHelper])

        XCTAssertEqual(items.first { $0.id == backup.id }?.state, .stopped)
        XCTAssertEqual(items.first { $0.id == lemonUninstall.id }?.state, .stopped)
        XCTAssertEqual(items.first { $0.id == lemonHelper.id }?.state, .running)
        XCTAssertFalse(items.contains { $0.id == "process:/Applications/Lemon.app" }, "Lemon's main process belongs to the listed app")
    }

    private func writePlist(_ dictionary: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        try data.write(to: url)
    }

    private func makeKext(in directory: URL, name: String, identifier: String) throws {
        let contents = directory.appending(path: "\(name).kext/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try writePlist(["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundlePackageType": "KEXT"],
                       to: contents.appending(path: "Info.plist"))
    }
}

struct FixedRunningProcessProvider: RunningProcessProviding {
    let processes: [RunningProcess]
    var foreground: Set<String> = []

    func processes() async -> [RunningProcess] {
        processes
    }

    func foregroundApplicationPaths() async -> Set<String> {
        foreground
    }
}
