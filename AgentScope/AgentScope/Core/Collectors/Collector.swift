import Foundation

public protocol CommandExecuting: Sendable {
    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        environment: [String: String]?
    ) async throws -> CommandResult
}

extension CommandRunner: CommandExecuting {}

public protocol Collector: Sendable {
    func collect() async -> CollectorResult
}

public struct CollectorResult: Sendable {
    public let items: [ServiceItem]
    public let warnings: [String]

    public init(items: [ServiceItem], warnings: [String]) {
        self.items = items
        self.warnings = warnings
    }
}
