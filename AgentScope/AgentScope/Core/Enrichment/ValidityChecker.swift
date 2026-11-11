import Foundation

public struct ValidityChecker: Sendable {
    public init() {}

    public func check(
        configurationURL: URL,
        programPath: String?,
        arguments: [String]
    ) -> ValidityStatus {
        let fileManager = FileManager.default
        guard fileManager.isReadableFile(atPath: configurationURL.path) else {
            return .invalidConfiguration
        }
        guard let programPath, !programPath.isEmpty else {
            return .invalidConfiguration
        }

        let programURL = URL(fileURLWithPath: programPath)
        guard fileManager.fileExists(atPath: programURL.path) else {
            return .missingTarget
        }
        // Root daemons' helpers are often executable only by root; any execute bit means launchd can run it.
        let permissions = (try? fileManager.attributesOfItem(atPath: programURL.path)[.posixPermissions] as? NSNumber)?.intValue
        if let permissions, permissions & 0o111 == 0 {
            return .invalidConfiguration
        }

        if programURL.path == "/usr/bin/env", let interpreter = arguments.first {
            guard executableInPath(interpreter) else { return .missingInterpreter }
        }

        return .healthy
    }

    private func executableInPath(_ name: String) -> Bool {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name)
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(
                atPath: URL(fileURLWithPath: String(directory)).appending(path: name).path
            )
        }
    }
}
