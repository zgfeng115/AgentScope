import Foundation

public enum SignatureClass: String, Codable, Hashable, Sendable {
    case apple
    case developerID
    case adhoc
    case unsigned
    case invalid
    case unknown
}

public struct SignatureInspector: Sendable {
    private let commandRunner: any CommandExecuting

    public init(commandRunner: any CommandExecuting = CommandRunner()) {
        self.commandRunner = commandRunner
    }

    public func inspect(path: String) async -> SignatureClass {
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }

        do {
            let result = try await commandRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/codesign"),
                arguments: ["--verify", "--verbose=2", path],
                timeout: 5,
                environment: nil
            )
            let output = "\(result.stdout)\n\(result.stderr)"
            if output.localizedCaseInsensitiveContains("Authority=Apple") {
                return .apple
            }
            if output.localizedCaseInsensitiveContains("Authority=Developer ID") {
                return .developerID
            }
            if output.localizedCaseInsensitiveContains("adhoc") {
                return .adhoc
            }
            return .unknown
        } catch let error as CommandRunnerError {
            if case .nonZeroExit = error { return .unsigned }
            if case .timedOut = error { return .unknown }
            return .invalid
        } catch {
            return .unknown
        }
    }
}
