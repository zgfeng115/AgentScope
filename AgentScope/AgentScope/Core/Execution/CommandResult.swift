import Foundation

public struct CommandResult: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let duration: TimeInterval

    public init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        timedOut: Bool,
        duration: TimeInterval
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.duration = duration
    }
}

public enum CommandRunnerError: Error, Equatable, Sendable {
    case executableNotFound(path: String)
    case permissionDenied(path: String)
    case timedOut(CommandResult)
    case nonZeroExit(CommandResult)
}
