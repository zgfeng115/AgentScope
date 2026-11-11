import Darwin
import Foundation

public struct LaunchAgentCollector: Collector {
    private let directoryURL: URL
    private let commandRunner: any CommandExecuting
    private let validityChecker: ValidityChecker
    private let signatureInspector: SignatureInspector
    private let inspectSignatures: Bool
    private let userID: UInt32

    public init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents"),
        commandRunner: any CommandExecuting = CommandRunner(),
        validityChecker: ValidityChecker = ValidityChecker(),
        inspectSignatures: Bool = true,
        userID: UInt32 = getuid()
    ) {
        self.directoryURL = directoryURL
        self.commandRunner = commandRunner
        self.validityChecker = validityChecker
        self.signatureInspector = SignatureInspector(commandRunner: commandRunner)
        self.inspectSignatures = inspectSignatures
        self.userID = userID
    }

    public func collect() async -> CollectorResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return CollectorResult(items: [], warnings: ["LaunchAgents directory not found: \(directoryURL.path)"])
        }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "plist" }
            .sorted { $0.path < $1.path }
        } catch {
            return CollectorResult(items: [], warnings: ["Unable to scan \(directoryURL.path): \(error.localizedDescription)"])
        }

        var items: [ServiceItem] = []
        var warnings: [String] = []

        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                var format = PropertyListSerialization.PropertyListFormat.xml
                guard let plist = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: &format
                ) as? [String: Any] else {
                    warnings.append("Invalid plist dictionary: \(url.lastPathComponent)")
                    continue
                }

                let fallbackLabel = url.deletingPathExtension().lastPathComponent
                let label: String
                if let rawLabel = plist["Label"] as? String {
                    let trimmedLabel = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    label = trimmedLabel.isEmpty ? fallbackLabel : trimmedLabel
                } else {
                    label = fallbackLabel
                }
                let programArguments = (plist["ProgramArguments"] as? [String]) ?? []
                let explicitProgram = plist["Program"] as? String
                let programPath = explicitProgram ?? programArguments.first
                let arguments = programArguments.first == programPath
                    ? Array(programArguments.dropFirst())
                    : programArguments
                let validity = validityChecker.check(
                    configurationURL: url,
                    programPath: programPath,
                    arguments: arguments
                )
                let snapshot = await launchctlSnapshot(for: label)
                let disabled = (plist["Disabled"] as? Bool) ?? false
                let signature = inspectSignatures && programPath != nil
                    ? await signatureInspector.inspect(path: programPath!)
                    : .unknown

                items.append(ServiceItem(
                    id: "launchagent:user:\(label)",
                    name: label,
                    sourceType: .launchAgent,
                    scope: .user,
                    label: label,
                    configurationPath: url.path,
                    programPath: programPath,
                    arguments: arguments,
                    state: state(disabled: disabled, snapshot: snapshot),
                    pid: snapshot?.pid,
                    lastRunPrecision: .unknown,
                    lastExitCode: snapshot?.lastExitCode,
                    disabled: disabled,
                    validity: validity,
                    signature: signature
                ))
            } catch {
                warnings.append("Unable to read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        return CollectorResult(items: items, warnings: warnings)
    }

    private func launchctlSnapshot(for label: String) async -> LaunchctlSnapshot? {
        do {
            let result = try await commandRunner.run(
                executable: URL(fileURLWithPath: "/bin/launchctl"),
                arguments: ["print", "gui/\(userID)/\(label)"],
                timeout: 2,
                environment: nil
            )
            return LaunchctlParser.parse(result.stdout)
        } catch {
            return nil
        }
    }

    private func state(disabled: Bool, snapshot: LaunchctlSnapshot?) -> ServiceState {
        if disabled { return .disabled }
        guard let snapshot else { return .stopped }
        if snapshot.isRunning { return .running }
        if snapshot.state?.lowercased() == "failed" { return .failed }
        return .stopped
    }
}
