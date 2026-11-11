import Foundation

/// Decides which items belong to macOS itself and must never reach the inventory.
/// Third-party items under `/Library` are kept; Apple's own (`/System`, `com.apple.*`, Apple-signed binaries) are dropped.
public struct AppleItemFilter: Sendable {
    private static let interpreterNames: Set<String> = [
        "sh", "bash", "zsh", "dash", "fish", "env", "osascript", "perl", "ruby",
        "node", "bun", "deno", "python", "python2", "python3", "uv", "uvx", "open", "nohup"
    ]
    private static let signatureJudgedSources: Set<SourceType> = [
        .embeddedLoginItem, .process, .privilegedHelper, .systemExtension, .kernelExtension, .backgroundTask
    ]

    public init() {}

    public func isAppleItem(_ item: ServiceItem) -> Bool {
        if let config = item.configurationPath, config.hasPrefix("/System/") { return true }
        if item.configurationPath == nil, let program = item.programPath, program.hasPrefix("/System/") { return true }
        if Self.isAppleIdentifier(item.label) || Self.isAppleIdentifier(item.bundleIdentifier) { return true }
        if Self.signatureJudgedSources.contains(item.sourceType), item.signing?.signature == .apple { return true }
        return false
    }

    /// The file whose signature identifies the vendor: the program itself, or the script an interpreter runs.
    public static func signingTargetPath(for item: ServiceItem) -> String? {
        guard let program = item.programPath, program.hasPrefix("/") else { return nil }
        let name = URL(fileURLWithPath: program).lastPathComponent
        guard isInterpreter(name) else { return program }
        return item.arguments.first { $0.hasPrefix("/") && FileManager.default.fileExists(atPath: $0) }
    }

    static func isInterpreter(_ name: String) -> Bool {
        interpreterNames.contains(name) || name.hasPrefix("python3.") || name.hasPrefix("ruby")
    }

    private static func isAppleIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.lowercased().hasPrefix("com.apple.")
    }
}
